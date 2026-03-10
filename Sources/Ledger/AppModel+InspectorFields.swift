import Foundation
import ExifEditCore

@MainActor
extension AppModel {
    func rebuildFilteredBrowserItems() {
        let baseItems: [BrowserItem]
        if searchQuery.isEmpty {
            baseItems = browserItems
        } else {
            let query = searchQuery.lowercased()
            baseItems = browserItems.filter { $0.name.lowercased().contains(query) }
        }
        filteredBrowserItems = sortBrowserItems(baseItems)
    }

    var selectedSnapshots: [FileMetadataSnapshot] {
        selectedFileURLs.compactMap { metadataByFile[$0] }
    }

    var groupedEditableTags: [String: [EditableTag]] {
        Dictionary(grouping: activeEditableTags, by: \.section)
    }

    var orderedEditableTagSections: [EditableTagSectionGroup] {
        let grouped = groupedEditableTags
        var orderedSections: [String] = []
        for entry in activeInspectorFieldCatalog {
            if !orderedSections.contains(entry.section) {
                orderedSections.append(entry.section)
            }
        }

        return orderedSections.compactMap { section in
            guard let tags = grouped[section], !tags.isEmpty else { return nil }
            return EditableTagSectionGroup(section: section, tags: tags)
        }
    }

    var inspectorFieldSections: [(section: String, fields: [FieldCatalogEntry])] {
        var result: [(section: String, fields: [FieldCatalogEntry])] = []
        for entry in activeInspectorFieldCatalog {
            if let index = result.firstIndex(where: { $0.section == entry.section }) {
                result[index].fields.append(entry)
            } else {
                result.append((section: entry.section, fields: [entry]))
            }
        }
        return result
    }

    func isInspectorFieldEnabled(_ fieldID: String) -> Bool {
        activeInspectorFieldCatalog.first(where: { $0.id == fieldID })?.isEnabled ?? false
    }

    func isInspectorSectionEnabled(_ section: String) -> Bool {
        let fields = activeInspectorFieldCatalog.filter { $0.section == section }
        guard !fields.isEmpty else { return false }
        return fields.allSatisfy(\.isEnabled)
    }

    func setInspectorFieldEnabled(fieldID: String, isEnabled: Bool) {
        let updated = activeInspectorFieldCatalog.map { entry in
            guard entry.id == fieldID else { return entry }
            return entry.withEnabled(isEnabled)
        }
        applyInspectorFieldCatalogUpdate(updated)
    }

    func setInspectorSectionEnabled(section: String, isEnabled: Bool) {
        let updated = activeInspectorFieldCatalog.map { entry in
            guard entry.section == section else { return entry }
            return entry.withEnabled(isEnabled)
        }
        applyInspectorFieldCatalogUpdate(updated)
    }
}
