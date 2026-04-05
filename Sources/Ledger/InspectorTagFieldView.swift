import SwiftUI
import SharedUI

struct InspectorTagFieldView: View {
    let tag: AppModel.EditableTag
    @ObservedObject var model: AppModel
    @FocusState.Binding var focusedTagID: String?
    let onBeginEditSession: () -> Void
    let onOpenDateTimeAdjust: () -> Void
    let onOpenLocationAdjust: () -> Void

    var body: some View {
        if model.isDateTimeTag(tag) {
            InspectorDateTimeFieldView(
                tag: tag,
                model: model,
                onBeginEditSession: onBeginEditSession,
                onOpenDateTimeAdjust: onOpenDateTimeAdjust
            )
        } else if let options = model.pickerOptions(for: tag) {
            InspectorPopupField(
                selection: popupBinding,
                options: popupOptions(from: options),
                accessibilityLabel: tag.label
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if isKeywordTag {
            InspectorTokenField(
                text: textBinding,
                placeholder: model.placeholderForTag(tag)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            InspectorClearableTextField(
                text: textBinding,
                prompt: model.isMixedValue(for: tag) ? "Multiple values" : model.placeholderForTag(tag),
                fieldLabel: tag.label,
                tagID: tag.id,
                focusedTagID: $focusedTagID,
                onClear: {
                    onBeginEditSession()
                    model.updateValue("", for: tag)
                }
            ) {
                if isLocationCoordinateTag {
                    Button("Set\u{2026}", action: onOpenLocationAdjust)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Bindings

    private var popupBinding: Binding<String> {
        Binding(
            get: { model.valueForTag(tag) },
            set: { newValue in
                guard newValue != model.valueForTag(tag) else { return }
                onBeginEditSession()
                model.updateValue(newValue, for: tag)
            }
        )
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { model.valueForTag(tag) },
            set: { newValue in
                onBeginEditSession()
                model.updateValue(newValue, for: tag)
            }
        )
    }

    // MARK: - Helpers

    private func popupOptions(from options: [AppModel.PickerOption]) -> [InspectorPopupOption] {
        let currentValue = model.valueForTag(tag)
        var result: [InspectorPopupOption] = [
            .init(value: "", label: model.isMixedValue(for: tag) ? "Multiple values" : "—")
        ]
        if !currentValue.isEmpty, !options.contains(where: { $0.value == currentValue }) {
            result.append(.init(value: currentValue, label: currentValue))
        }
        result.append(contentsOf: options.map { .init(value: $0.value, label: $0.label) })
        return result
    }

    private var isKeywordTag: Bool {
        tag.id == "xmp-subject" || tag.id == "iptc-keywords"
    }

    private var isLocationCoordinateTag: Bool {
        tag.id == "exif-gps-lat" || tag.id == "exif-gps-lon"
    }
}
