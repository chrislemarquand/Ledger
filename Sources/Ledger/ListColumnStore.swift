import Foundation

/// Persists list column visibility and initial-fit state to UserDefaults.
///
/// NSTableView.autosaveTableColumns handles column widths and order natively;
/// this type handles the visibility state that autosave does not cover.
struct ListColumnStore {
    private let defaults = UserDefaults.standard
    private let visibleKey: String
    private let initialFitKey: String

    init(identifierPrefix: String) {
        visibleKey = "\(identifierPrefix).listColumns.visible"
        initialFitKey = "\(identifierPrefix).listColumns.initialFitApplied"
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

    /// True after applyInitialColumnFit has run once. Persisted so that
    /// NSTableView autosave takes over column widths on subsequent launches.
    var hasAppliedInitialFit: Bool {
        get { defaults.bool(forKey: initialFitKey) }
        set { defaults.set(newValue, forKey: initialFitKey) }
    }
}
