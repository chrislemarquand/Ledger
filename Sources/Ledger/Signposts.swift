import Foundation
import OSLog

/// Stable OSSignposter instances for Phase 0.1 of the v1.4 performance audit.
/// See docs/v1.4-performance-audit-plan.md and docs/v1.4-progress.md.
enum Signposts {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Ledger"

    static let launch = OSSignposter(subsystem: subsystem, category: "Launch")
    static let folderLoad = OSSignposter(subsystem: subsystem, category: "FolderLoad")
    static let thumbnail = OSSignposter(subsystem: subsystem, category: "Thumbnail")
    static let attributeHydration = OSSignposter(subsystem: subsystem, category: "AttributeHydration")
    static let metadata = OSSignposter(subsystem: subsystem, category: "Metadata")
    static let browserTransition = OSSignposter(subsystem: subsystem, category: "BrowserTransition")
    /// Phase 2.3: unified "fully idle" signal — see AppModel+Quiescence.swift.
    static let quiescence = OSSignposter(subsystem: subsystem, category: "Quiescence")
}
