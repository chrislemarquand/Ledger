import SharedUI

// MARK: - Protocol conformances for AppKitSidebarController

enum LedgerSidebarSection: String, CaseIterable, AppKitSidebarSectionType {
    case sources = "Sources"
    case pinned  = "Pinned"
    case recents = "Recents"

    var title: String { rawValue }
}

struct LedgerSidebarItem: AppKitSidebarItemType {
    let id: String
    let section: LedgerSidebarSection
    let title: String
    let symbolName: String
    let badgeText: String?
    // Retained for menu predicate queries in NativeThreePaneSplitViewController.
    let kind: AppModel.SidebarKind
    var sidebarReorderID: String? { id }
    var isSidebarReorderable: Bool {
        if case .favorite = kind { return true }
        return false
    }
    var sidebarPromotionTargets: Set<LedgerSidebarSection> {
        switch kind {
        case .folder:   return [.pinned]
        case .favorite: return [.recents]
        default:        return []
        }
    }

    // Identity is the stable folder/location id — badgeText and title are display state
    // and must not participate in equality. Without this, a count loading asynchronously
    // would change the item's hash, causing reloadData() to fail to restore the selection.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

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
