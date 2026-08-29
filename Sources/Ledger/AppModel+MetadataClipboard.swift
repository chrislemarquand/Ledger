import AppKit
import Foundation

@MainActor
extension AppModel {
    /// Custom pasteboard type for the metadata clipboard. Payload is a JSON-encoded
    /// `[PresetFieldValue]` — currently always a single element (field-level copy/paste);
    /// a future metadata-set copy/paste would write more than one element to the same type.
    static let metadataFieldsPasteboardType = NSPasteboard.PasteboardType("\(AppBrand.identifierPrefix).metadata-fields")

    /// Copies one field's current value to the general pasteboard. Alongside the structured
    /// payload (used by the browser context menu's "Paste <Field>" item), the plain string is
    /// also written so a normal ⌘V / right-click → Paste inside any text field works for free.
    func copyFieldToPasteboard(_ tag: EditableTag) {
        guard !isMixedValue(for: tag) else { return }
        let value = valueForTag(tag)
        writeFieldsToPasteboard([PresetFieldValue(tagID: tag.id, value: value)], plainText: value)
    }

    private func writeFieldsToPasteboard(_ fields: [PresetFieldValue], plainText: String?) {
        guard let data = try? JSONEncoder().encode(fields) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.metadataFieldsPasteboardType)
        if let plainText {
            item.setString(plainText, forType: .string)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    /// Non-nil only when exactly one field is on the pasteboard — the field-level paste case.
    /// A future metadata-set paste would read the same payload without the `count == 1` restriction.
    func pasteboardSingleFieldPreview() -> (tag: EditableTag, value: String)? {
        guard let data = NSPasteboard.general.data(forType: Self.metadataFieldsPasteboardType),
              let fields = try? JSONDecoder().decode([PresetFieldValue].self, from: data),
              fields.count == 1,
              let tag = editableTag(forID: fields[0].tagID)
        else { return nil }
        return (tag, fields[0].value)
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
}
