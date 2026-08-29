import AppKit
import Foundation

/// Payload written to the metadata clipboard pasteboard type. `kind` disambiguates a
/// single named-field copy from a whole-record copy that happens to yield only one
/// populated field — both are `[PresetFieldValue]` underneath, so the count alone can't
/// tell them apart.
private struct MetadataClipboardPayload: Codable {
    enum Kind: String, Codable { case field, allMetadata }
    let kind: Kind
    let fields: [PresetFieldValue]
}

@MainActor
extension AppModel {
    /// Custom pasteboard type for the metadata clipboard (field-level and metadata-set
    /// copy/paste both use this one type — see `MetadataClipboardPayload`).
    static let metadataFieldsPasteboardType = NSPasteboard.PasteboardType("\(AppBrand.identifierPrefix).metadata-fields")

    /// Copies one field's current value to the general pasteboard. Alongside the structured
    /// payload (used by the browser context menu's "Paste <Field>" item), the plain string is
    /// also written so a normal ⌘V / right-click → Paste inside any text field works for free.
    func copyFieldToPasteboard(_ tag: EditableTag) {
        guard !isMixedValue(for: tag) else { return }
        let value = valueForTag(tag)
        writeToPasteboard(
            MetadataClipboardPayload(kind: .field, fields: [PresetFieldValue(tagID: tag.id, value: value)]),
            plainText: value
        )
    }

    /// Copies every currently visible, non-mixed field to the general pasteboard — "visible"
    /// meaning whatever `activeEditableTags` surfaces, i.e. respecting the Settings
    /// field-visibility filter, same convention `beginCreatePresetFromCurrent()` uses. Empty
    /// fields are copied too (not skipped): this is a whole-record clone, so pasting it should
    /// clear a field on the target that's blank on the source, not just leave it untouched. No
    /// plain `.string` fallback: a whole record has no sensible single-string representation.
    func copyAllMetadataToPasteboard() {
        var fields: [PresetFieldValue] = []
        for tag in activeEditableTags {
            guard !isMixedValue(for: tag) else { continue }
            fields.append(PresetFieldValue(tagID: tag.id, value: valueForTag(tag)))
        }
        guard !fields.isEmpty else { return }
        writeToPasteboard(MetadataClipboardPayload(kind: .allMetadata, fields: fields), plainText: nil)
    }

    private func writeToPasteboard(_ payload: MetadataClipboardPayload, plainText: String?) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.metadataFieldsPasteboardType)
        if let plainText {
            item.setString(plainText, forType: .string)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    private func readPasteboardPayload() -> MetadataClipboardPayload? {
        guard let data = NSPasteboard.general.data(forType: Self.metadataFieldsPasteboardType) else { return nil }
        return try? JSONDecoder().decode(MetadataClipboardPayload.self, from: data)
    }

    /// Non-nil only for a field-level copy (see `copyFieldToPasteboard`).
    func pasteboardSingleFieldPreview() -> (tag: EditableTag, value: String)? {
        guard let payload = readPasteboardPayload(), payload.kind == .field, payload.fields.count == 1,
              let tag = editableTag(forID: payload.fields[0].tagID)
        else { return nil }
        return (tag, payload.fields[0].value)
    }

    /// Non-nil only for a whole-record copy (see `copyAllMetadataToPasteboard`).
    func pasteboardAllMetadataPreview() -> [PresetFieldValue]? {
        guard let payload = readPasteboardPayload(), payload.kind == .allMetadata else { return nil }
        return payload.fields
    }

    /// Applies the pasteboard's single-field value to `fileURLs` as a staged edit.
    func pasteField(_ tag: EditableTag, fileURLs: [URL]) {
        guard let preview = pasteboardSingleFieldPreview(), preview.tag.id == tag.id, !fileURLs.isEmpty else { return }
        let previousState = currentPendingEditState()
        stageEdit(preview.value, for: tag, fileURLs: fileURLs, source: .metadataPaste)
        registerMetadataUndoIfNeeded(previous: previousState)
        recalculateInspectorState()
        let files = fileURLs.count == 1 ? "1 file" : "\(fileURLs.count) files"
        setStatusMessage("Pasted \(tag.label) to \(files).", autoClearAfterSuccess: true)
    }

    /// Applies every field from the pasteboard's whole-record copy to `fileURLs` as staged
    /// edits — one `stageEdit` per field, all types uniformly (popup, date, keyword, plain
    /// text), exactly as `applyPreset` already does for saved presets. One undo step covers
    /// the whole batch.
    func pasteAllMetadata(fileURLs: [URL]) {
        guard let fields = pasteboardAllMetadataPreview(), !fileURLs.isEmpty else { return }

        var unknownTagIDs: [String] = []
        var stagedFieldCount = 0
        let previousState = currentPendingEditState()

        for field in fields {
            guard let tag = editableTag(forID: field.tagID) else {
                unknownTagIDs.append(field.tagID)
                continue
            }
            stageEdit(field.value, for: tag, fileURLs: fileURLs, source: .metadataPaste)
            stagedFieldCount += 1
        }

        guard stagedFieldCount > 0 else { return }
        registerMetadataUndoIfNeeded(previous: previousState)
        recalculateInspectorState()
        let ignoredCount = unknownTagIDs.count
        let ignoredText = unknownTagIDs.isEmpty ? "" : " Ignored \(ignoredCount) unsupported \(ignoredCount == 1 ? "field" : "fields")."
        let files = fileURLs.count == 1 ? "1 file" : "\(fileURLs.count) files"
        setStatusMessage("Pasted metadata to \(files).\(ignoredText)", autoClearAfterSuccess: true)
    }

    /// Whether `copyAllMetadataToPasteboard()` would currently produce a non-empty payload —
    /// used to enable/disable the browser context menu's "Copy All Metadata" item. Matches
    /// that function's own criterion: any non-mixed active field, empty or not.
    var hasCopyableMetadata: Bool {
        activeEditableTags.contains { !isMixedValue(for: $0) }
    }
}
