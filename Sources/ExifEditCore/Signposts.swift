import Foundation
import OSLog

/// Stable OSSignposter instance for ExifTool subprocess lifetime, part of the
/// v1.4 performance audit's Phase 0.1 instrumentation. `ExifEditCore` is a
/// separate module from `Ledger`, so this doesn't share the app target's
/// `Signposts` enum.
enum ExifToolSignposts {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Ledger"

    static let process = OSSignposter(subsystem: subsystem, category: "ExifToolProcess")
}
