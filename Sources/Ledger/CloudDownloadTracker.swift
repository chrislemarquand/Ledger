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
    private var onUpdate: (([URL: CloudFileState]) -> Void)?
    /// Matching on `NSMetadataItemURLKey` via an `IN` predicate is unreliable — Spotlight's
    /// reported URL for an item doesn't always compare equal to a `FileManager`-enumerated URL
    /// for the same file (trailing slash / standardisation differences). Match on path string
    /// instead and map back through this table, which sidesteps the comparison entirely.
    private var urlsByPath: [String: URL] = [:]
    private var pendingDownloads: Set<URL> = []

    /// Begin watching `urls` for download-state changes. Replaces any existing watch.
    /// `onUpdate` is called with the full state for every URL the query currently knows about,
    /// each time results change.
    func start(for urls: [URL], onUpdate: @escaping ([URL: CloudFileState]) -> Void) {
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
        onUpdate?([url: .downloading])
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        pollForCompletion(of: url)
    }

    /// `NSMetadataQuery` is not a reliable signal for "did the download I just triggered finish" —
    /// in practice it can go indefinitely without pushing a further update for an item that stays
    /// in its result set. Poll the same on-disk resource check the rest of the app trusts
    /// (`CloudFileStateResolver`, which mirrors Finder) until it reports local, so completion is
    /// always detected regardless of whether the query cooperates.
    private func pollForCompletion(of url: URL) {
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.pendingDownloads.contains(url) else { return }
                guard CloudFileStateResolver.resolve(for: url) == .local else { continue }
                self.pendingDownloads.remove(url)
                self.onUpdate?([url: .local])
                return
            }
        }
    }

    private func handleUpdate() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        var states: [URL: CloudFileState] = [:]
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let url = urlsByPath[path]
            else { continue }

            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if status == NSMetadataUbiquitousItemDownloadingStatusCurrent
                || status == NSMetadataUbiquitousItemDownloadingStatusDownloaded {
                states[url] = .local
                pendingDownloads.remove(url)
            } else {
                states[url] = pendingDownloads.contains(url) ? .downloading : .notDownloaded
            }
        }
        onUpdate?(states)
    }
}
