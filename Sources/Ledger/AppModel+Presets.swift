import AppKit
import ExifEditCore
import Foundation
import SharedUI

@MainActor
extension AppModel {
    func loadPresets() {
        do {
            presets = try presetStore.loadPresets().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            if let selectedPresetID,
               !presets.contains(where: { $0.id == selectedPresetID }) {
                self.selectedPresetID = nil
            }
        } catch ExifEditError.presetSchemaVersionTooNew {
            presets = []
            selectedPresetID = nil
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "Presets saved by a newer version"
                alert.informativeText = "Your presets were saved by a newer version of \(AppBrand.displayName) and can't be read. Update \(AppBrand.displayName) to access them."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runSheetOrModal(for: nil) { _ in }
            }
        } catch {
            presets = []
            selectedPresetID = nil
            statusMessage = "Couldn’t load presets. \(error.localizedDescription)"
        }
    }

    @discardableResult
    func createPreset(name: String, notes: String?, fields: [PresetFieldValue]) -> MetadataPreset? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFields = normalizePresetFields(fields)
        guard !trimmedName.isEmpty, !normalizedFields.isEmpty else { return nil }

        let now = Date()
        let preset = MetadataPreset(
            id: UUID(),
            name: trimmedName,
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            fields: normalizedFields,
            createdAt: now,
            updatedAt: now
        )
        presets.append(preset)
        sortPresets()
        persistPresets()
        selectedPresetID = preset.id
        setStatusMessage("Saved preset “\(preset.name)”.", autoClearAfterSuccess: true)
        return preset
    }

    @discardableResult
    func updatePreset(id: UUID, name: String, notes: String?, fields: [PresetFieldValue]) -> MetadataPreset? {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return nil }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFields = normalizePresetFields(fields)
        guard !trimmedName.isEmpty, !normalizedFields.isEmpty else { return nil }

        var preset = presets[index]
        preset.name = trimmedName
        preset.notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        preset.fields = normalizedFields
        preset.updatedAt = Date()
        presets[index] = preset
        sortPresets()
        persistPresets()
        selectedPresetID = preset.id
        setStatusMessage("Updated preset “\(preset.name)”.", autoClearAfterSuccess: true)
        return preset
    }

    @discardableResult
    func duplicatePreset(id: UUID) -> MetadataPreset? {
        guard let preset = preset(withID: id) else { return nil }
        return createPreset(name: "\(preset.name) Copy", notes: preset.notes, fields: preset.fields)
    }

    func deletePreset(id: UUID) {
        let previousCount = presets.count
        presets.removeAll { $0.id == id }
        guard presets.count != previousCount else { return }

        if selectedPresetID == id {
            selectedPresetID = nil
        }
        persistPresets()
        setStatusMessage("Deleted preset.", autoClearAfterSuccess: true)
    }

    func preset(withID id: UUID) -> MetadataPreset? {
        presets.first(where: { $0.id == id })
    }

    func beginCreatePresetFromCurrent() {
        var includedTagIDs = Set<String>()
        var valuesByTagID: [String: String] = [:]

        for tag in activeEditableTags {
            let value = valueForTag(tag).trimmingCharacters(in: .whitespacesAndNewlines)
            valuesByTagID[tag.id] = value
            if !value.isEmpty, !isMixedValue(for: tag) {
                includedTagIDs.insert(tag.id)
            }
        }

        activePresetEditor = PresetEditorState(
            mode: .createFromCurrent,
            name: "",
            notes: "",
            includedTagIDs: includedTagIDs,
            valuesByTagID: valuesByTagID
        )
    }

    func beginCreateBlankPreset() {
        var valuesByTagID: [String: String] = [:]
        for tag in activeEditableTags {
            valuesByTagID[tag.id] = ""
        }

        activePresetEditor = PresetEditorState(
            mode: .createBlank,
            name: "",
            notes: "",
            includedTagIDs: [],
            valuesByTagID: valuesByTagID
        )
    }

    func beginEditPreset(_ presetID: UUID) {
        guard let preset = preset(withID: presetID) else { return }

        var includedTagIDs = Set<String>()
        var valuesByTagID: [String: String] = [:]
        for field in preset.fields {
            includedTagIDs.insert(field.tagID)
            valuesByTagID[field.tagID] = field.value
        }
        for tag in activeEditableTags where valuesByTagID[tag.id] == nil {
            valuesByTagID[tag.id] = ""
        }

        activePresetEditor = PresetEditorState(
            mode: .edit(preset.id),
            name: preset.name,
            notes: preset.notes ?? "",
            includedTagIDs: includedTagIDs,
            valuesByTagID: valuesByTagID
        )
    }

    func dismissPresetEditor(reopenManagePresets: Bool = false) {
        activePresetEditor = nil
        guard reopenManagePresets else { return }
        DispatchQueue.main.async { [weak self] in
            self?.isManagePresetsPresented = true
        }
    }

    func requestImport(sourceKind: ImportSourceKind) {
        guard !browserItems.isEmpty else {
            statusMessage = "Open a folder with images before importing."
            return
        }
        pendingImportSourceKind = sourceKind
    }

    func dismissImportSheet() {
        pendingImportSourceKind = nil
    }

    func applyPreset(presetID: UUID) {
        guard let preset = preset(withID: presetID) else {
            statusMessage = "Preset not found."
            return
        }

        let files = Array(selectedFileURLs)
        guard !files.isEmpty else {
            statusMessage = "Select images to apply a preset."
            return
        }

        var unknownTagIDs: [String] = []
        var stagedFieldCount = 0
        let previousState = currentPendingEditState()

        for field in preset.fields {
            guard let tag = editableTag(forID: field.tagID) else {
                unknownTagIDs.append(field.tagID)
                continue
            }
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            stageEdit(
                value,
                for: tag,
                fileURLs: files,
                source: .preset(preset.id)
            )
            stagedFieldCount += 1
        }

        guard stagedFieldCount > 0 else {
            statusMessage = unknownTagIDs.isEmpty
                ? "Preset has no applicable fields."
                : "Preset contains unsupported fields only."
            return
        }
        registerMetadataUndoIfNeeded(previous: previousState)
        recalculateInspectorState()
        let ignoredCount = unknownTagIDs.count
        let ignoredText = unknownTagIDs.isEmpty ? "" : " Ignored \(ignoredCount) unsupported preset \(ignoredCount == 1 ? "field" : "fields")."
        let presetFiles = files.count == 1 ? "1 file" : "\(files.count) files"
        setStatusMessage(
            "Staged preset \u{201C}\(preset.name)\u{201D} for \(presetFiles).\(ignoredText)",
            autoClearAfterSuccess: true
        )
    }
}
