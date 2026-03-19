import SharedUI

// MARK: - Protocol conformances for AppKitSidebarController

enum LedgerSidebarSection: String, CaseIterable, AppKitSidebarSectionType {
    case sources = "Sources"
    case pinned  = "Pinned"
    case recents = "Recents"

    var title: String { rawValue }
}

struct LedgerSidebarItem: Hashable, AppKitSidebarItemType {
    let id: String
    let section: LedgerSidebarSection
    let title: String
    let symbolName: String
    let badgeText: String?
    // Retained for menu predicate queries in NativeThreePaneSplitViewController.
    let kind: AppModel.SidebarKind

    init(from item: AppModel.SidebarItem, section: LedgerSidebarSection, countText: String?) {
        self.id = item.id
        self.section = section
        self.title = item.title
        self.symbolName = Self.symbol(for: item.kind)
        self.badgeText = countText
        self.kind = item.kind
    }

    private static func symbol(for kind: AppModel.SidebarKind) -> String {
        switch kind {
        case .pictures:      return "photo"
        case .desktop:       return "menubar.dock.rectangle"
        case .downloads:     return "arrow.down.circle"
        case .mountedVolume: return "externaldrive"
        case .favorite:      return "pin"
        case .folder:        return "folder"
        }
    }
}
