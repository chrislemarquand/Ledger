import Foundation
import OSLog

/// v1.4 Phase 2.3: a unified "fully idle" signal for the five journeys the exit
/// gate cares about (initial display, folder switch, mode switch, selection
/// sweep, window closure). Phase 0.1 deliberately deferred building this — no
/// existing signal unified the individual loading flags and task properties
/// scattered across AppModel's extensions, and adding the coordinating state
/// wasn't justified for a "just add signposts" pass. This is that coordinating
/// state, built now that 2.3 actually needs it.
///
/// Deliberately event-driven, not polled: `checkQuiescenceIfNeeded()` is called
/// only from the specific completion/cancellation sites of the work being
/// tracked, so observing quiescence costs nothing beyond the work that was
/// already happening — no timer, no extra wakeups.
@MainActor
extension AppModel {
    /// True while any tracked folder-journey work is still in flight. Every task
    /// property here is nilled by its own owner on cancellation *and* on natural
    /// completion (see each site) — a stale non-nil reference to an already-finished
    /// task would make this permanently, incorrectly report "busy".
    var isFolderWorkActive: Bool {
        isFolderContentLoading
            || isFolderMetadataLoading
            || isPreviewPreloading
            || folderMetadataLoadTask != nil
            || browserItemHydrationTask != nil
            || selectionMetadataLoadTask != nil
            || previewPreloadTask != nil
            || deferredFolderMetadataPrefetchTask != nil
            || deferredPreviewPreloadTask != nil
            || initialThumbnailWarmupTask != nil
            || !inspectorPreviewTasksByURL.isEmpty
            || !backgroundWarmTasksBySelectionID.isEmpty
            || !sidebarImageCountTasks.isEmpty
    }

    /// Starts (or restarts) quiescence measurement. Call at the moment one of the
    /// five tracked journeys begins. A journey that starts while another is still
    /// being measured supersedes it — the prior measurement is discarded rather
    /// than left to report a misleadingly long duration for a journey that was
    /// actually interrupted by this new one.
    func beginQuiescenceTracking(reason: String) {
        if let state = quiescenceSignpostState {
            Signposts.quiescence.endInterval("Quiescence", state, "superseded by \(reason)")
        }
        let signpostID = Signposts.quiescence.makeSignpostID()
        quiescenceSignpostState = Signposts.quiescence.beginInterval("Quiescence", id: signpostID, "\(reason)")
        quiescenceReason = reason
        // Deliberately no immediate self-check here. `loadFiles(for:)` — the caller
        // for the FolderLoad/initial-display journey — has a real `await` between
        // this call and where it actually assigns `browserItemHydrationTask`/
        // `initialThumbnailWarmupTask`/etc. A Task queued here to check right away
        // would win that race and run during that gap, while every tracked
        // property is still nil, and wrongly end the interval a few milliseconds
        // in — confirmed directly: an early version of this measured ~32ms for a
        // 1,012-file corpus open, which is only the time to the first `await`, not
        // real quiescence. Every real completion/cancellation site below already
        // calls `checkQuiescenceIfNeeded()` itself, including the "nothing to do"
        // early-return paths, so a journey that starts genuinely idle still
        // resolves promptly without this.
    }

    /// Ends the in-flight quiescence measurement if `isFolderWorkActive` has become
    /// false. Safe to call speculatively from any completion/cancellation site —
    /// it's a no-op when work is still active or nothing is being measured.
    func checkQuiescenceIfNeeded() {
        guard let state = quiescenceSignpostState, !isFolderWorkActive else { return }
        let reason = quiescenceReason ?? "unknown"
        Signposts.quiescence.endInterval("Quiescence", state, "\(reason)")
        quiescenceSignpostState = nil
        quiescenceReason = nil
    }
}
