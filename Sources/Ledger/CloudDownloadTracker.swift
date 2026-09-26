import Foundation

/// Live iCloud download-state tracking for the currently-loaded folder, backed by
/// `NSMetadataQuery` — the same mechanism Finder uses to keep its own iCloud status
/// column and progress spinners in sync as downloads happen.
///
/// `.downloading` is only ever reported for a URL the user explicitly requested via
/// `requestDownload(for:)` — the OS's own "is downloading" flag can be transiently true for
/// unrelated background activity (Spotlight/thumbnail prefetch), which previously showed a
/// spinner on random undownloaded files with no real download underway.
@MainActor
final class CloudDownloadTracker {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var onUpdate: (([URL: CloudFileState], [URL: Double?]) -> Void)?
    /// Matching on `NSMetadataItemURLKey` via an `IN` predicate is unreliable — Spotlight's
    /// reported URL for an item doesn't always compare equal to a `FileManager`-enumerated URL
    /// for the same file (trailing slash / standardisation differences). Match on path string
    /// instead and map back through this table, which sidesteps the comparison entirely.
    private var urlsByPath: [String: URL] = [:]
    private var pendingDownloads: Set<URL> = []
    private var pollTasks: [URL: Task<Void, Never>] = [:]
    private var requestIDs: [URL: UUID] = [:]
    /// Overridable for tests — see `pollForCompletion`'s doc comment.
    private let pollTimeout: TimeInterval
    private let startDownload: (URL) throws -> Void
    private let resolveState: (URL) -> CloudFileState
    private let now: () -> Date
    private let sleep: () async throws -> Void

    init(
        pollTimeout: TimeInterval = 120,
        startDownload: @escaping (URL) throws -> Void = { try FileManager.default.startDownloadingUbiquitousItem(at: $0) },
        resolveState: @escaping (URL) -> CloudFileState = CloudFileStateResolver.resolve,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    ) {
        self.pollTimeout = pollTimeout
        self.startDownload = startDownload
        self.resolveState = resolveState
        self.now = now
        self.sleep = sleep
    }

    /// Begin watching `urls` for download-state changes. Replaces any existing watch.
    /// `onUpdate` is called with the full state for every URL the query currently knows about,
    /// each time results change.
    func start(for urls: [URL], onUpdate: @escaping ([URL: CloudFileState], [URL: Double?]) -> Void) {
        stop()
        guard !urls.isEmpty else { return }
        self.onUpdate = onUpdate
        urlsByPath = Dictionary(uniqueKeysWithValues: urls.map { ($0.standardizedFileURL.path, $0) })

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope, NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K IN %@", NSMetadataItemPathKey, Array(urlsByPath.keys))

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleUpdate() }
            },
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleUpdate() }
            }
        ]
        self.query = query
        query.start()
    }

    func stop() {
        pollTasks.values.forEach { $0.cancel() }
        pollTasks.removeAll()
        requestIDs.removeAll()
        query?.stop()
        query = nil
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        onUpdate = nil
        urlsByPath = [:]
        pendingDownloads.removeAll()
    }

    /// Ask the file provider to materialise `url`. Matches Finder's "Download Now". Reports
    /// `.downloading` immediately for instant feedback, rather than waiting on a query round-trip.
    func requestDownload(for url: URL) {
        guard !pendingDownloads.contains(url) else { return }
        pendingDownloads.insert(url)
        onUpdate?([url: .downloading], [url: nil])
        // v1.4 follow-up: `try?` used to silently swallow a start failure while the optimistic
        // `.downloading` state (just published above) stayed in place forever — permanent
        // spinner, and the pending-set guard above suppressed any retry. Undo the optimistic
        // state immediately on a real start failure instead of leaving it to polling (which
        // never would have detected this — the file never started downloading, so it never
        // becomes `.local`).
        do {
            try startDownload(url)
        } catch {
            pendingDownloads.remove(url)
            onUpdate?([url: .notDownloaded], [url: nil])
            return
        }
        pollForCompletion(of: url)
    }

    /// `NSMetadataQuery` is not a reliable signal for "did the download I just triggered finish" —
    /// in practice it can go indefinitely without pushing a further update for an item that stays
    /// in its result set. Poll the same on-disk resource check the rest of the app trusts
    /// (`CloudFileStateResolver`, which mirrors Finder) until it reports local, so completion is
    /// always detected regardless of whether the query cooperates.
    ///
    /// v1.4 follow-up: this used to loop with no deadline at all — a download the provider
    /// accepted but never actually completes (revoked network access, provider-side failure with
    /// no error surfaced back to us) polled silently forever. Gives up after `pollTimeout` and
    /// reports `.notDownloaded` — the same fallback as a start failure above — so the spinner
    /// clears and the pending-set guard releases, letting the user retry.
    private func pollForCompletion(of url: URL) {
        let deadline = now().addingTimeInterval(pollTimeout)
        let requestID = UUID()
        requestIDs[url] = requestID
        let sleep = self.sleep
        pollTasks[url] = Task { @MainActor [weak self] in
            while true {
                do { try await sleep() } catch { return }
                guard !Task.isCancelled, let self,
                      self.requestIDs[url] == requestID,
                      self.pendingDownloads.contains(url) else { return }
                if self.resolveState(url) == .local {
                    self.finishDownload(for: url, state: .local)
                    return
                }
                if self.now() >= deadline {
                    self.finishDownload(for: url, state: .notDownloaded)
                    return
                }
            }
        }
    }

    private func finishDownload(for url: URL, state: CloudFileState) {
        pendingDownloads.remove(url)
        requestIDs[url] = nil
        pollTasks.removeValue(forKey: url)?.cancel()
        onUpdate?([url: state], [url: nil])
    }

    private func handleUpdate() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        var states: [URL: CloudFileState] = [:]
        var progress: [URL: Double?] = [:]
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let url = urlsByPath[path]
            else { continue }

            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if status == NSMetadataUbiquitousItemDownloadingStatusCurrent
                || status == NSMetadataUbiquitousItemDownloadingStatusDownloaded {
                states[url] = .local
                pendingDownloads.remove(url)
                requestIDs[url] = nil
                pollTasks.removeValue(forKey: url)?.cancel()
            } else {
                states[url] = pendingDownloads.contains(url) ? .downloading : .notDownloaded
                if pendingDownloads.contains(url) {
                    // Deprecated, but still the only live percent-complete signal iCloud Drive
                    // exposes for a plain file download outside a File Provider extension. Report
                    // it when the OS bothers to populate it; callers treat a nil as indeterminate.
                    let percent = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double
                    progress[url] = percent.map { $0 / 100 }
                }
            }
        }
        onUpdate?(states, progress)
    }
}
