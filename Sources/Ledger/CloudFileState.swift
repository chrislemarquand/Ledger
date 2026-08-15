import Foundation

/// Local-vs-iCloud materialisation state for a browsable file.
///
/// `.notDownloaded` / `.downloading` files are dataless placeholders — reading them via
/// ExifTool would either time out or silently trigger a fileproviderd materialise, which is
/// exactly the stall this type exists to avoid.
enum CloudFileState: Hashable, Sendable {
    case local
    case downloading
    case notDownloaded

    var isPlaceholder: Bool {
        self != .local
    }
}

enum CloudFileStateResolver {
    /// One-shot check, used only to seed initial state at folder-load time. Deliberately never
    /// returns `.downloading` — the OS's "is downloading" flag can be transiently true for
    /// unrelated background activity (Spotlight/thumbnail prefetch) with no user-visible download
    /// underway, which reads as a spinner stuck on a random file for no reason. `.downloading` is
    /// reserved for `CloudDownloadTracker`, which only reports it for a download the user actually
    /// requested.
    static func resolve(for url: URL) -> CloudFileState {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]), values.isUbiquitousItem == true else {
            return .local
        }

        guard values.ubiquitousItemDownloadingStatus != .current,
              values.ubiquitousItemDownloadingStatus != .downloaded
        else {
            return .local
        }

        return .notDownloaded
    }
}
