import Foundation

/// Persists list column visibility to UserDefaults. Reads the same
/// `SharedListPersistenceConfig.visibilityDefaultsKey` that `SharedBrowserListViewController`
/// writes to (via `SharedListColumnStore`), for use in demand-gate checks that need visibility
/// without pulling in the full shared list controller.
struct ListColumnStore {
    private let defaults = UserDefaults.standard
    private let visibleKey: String

    init(identifierPrefix: String) {
        visibleKey = "\(identifierPrefix).listColumns.visible"
    }

    /// Returns whether a column should be visible, falling back to the
    /// definition's defaultIsVisible when no user preference has been stored.
    func isVisible(_ definition: ListColumnDefinition) -> Bool {
        guard let stored = defaults.array(forKey: visibleKey) as? [String] else {
            return definition.defaultIsVisible
        }
        return stored.contains(definition.id)
    }

    /// Persists the visibility state for one column. The first time this is
    /// called, the full visible set (derived from defaults) is written so that
    /// subsequent reads are authoritative.
    mutating func setVisible(_ columnID: String, _ visible: Bool, allDefinitions: [ListColumnDefinition]) {
        var currentVisible = Set(allDefinitions.filter { isVisible($0) }.map(\.id))
        if visible {
            currentVisible.insert(columnID)
        } else {
            currentVisible.remove(columnID)
        }
        defaults.set(Array(currentVisible), forKey: visibleKey)
    }
}
