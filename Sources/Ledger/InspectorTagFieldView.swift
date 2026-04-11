import SwiftUI
import SharedUI

struct InspectorTagFieldView: View {
    let tag: AppModel.EditableTag
    @ObservedObject var model: AppModel
    let onBeginEditSession: () -> Void
    let onOpenDateTimeAdjust: () -> Void
    let onOpenLocationAdjust: () -> Void
    let onFocusChange: (Bool) -> Void
    let onEscape: () -> Void

    @State private var isEditing = false

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
            InspectorNSTokenField(
                text: textBinding,
                placeholder: model.placeholderForTag(tag),
                tagID: tag.id,
                onClearAll: {
                    onBeginEditSession()
                    model.updateValue("", for: tag)
                },
                onFocusChange: onFocusChange,
                onEscape: onEscape,
                onTab: {
                    NotificationCenter.default.post(
                        name: .inspectorDidRequestFieldNavigation,
                        object: nil,
                        userInfo: ["backward": false]
                    )
                },
                onShiftTab: {
                    NotificationCenter.default.post(
                        name: .inspectorDidRequestFieldNavigation,
                        object: nil,
                        userInfo: ["backward": true]
                    )
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 6) {
                InspectorTextField(
                    text: textBinding,
                    placeholder: model.isMixedValue(for: tag) ? "Multiple values" : model.placeholderForTag(tag),
                    fieldLabel: tag.label,
                    tagID: tag.id,
                    isMixedValue: model.isMixedValue(for: tag),
                    editingPrefix: tag.id == "exif-shutter" ? "1/" : nil,
                    onFocusChange: { focused in
                        DispatchQueue.main.async { isEditing = focused }
                        onFocusChange(focused)
                    },
                    onEscape: onEscape,
                    onCommit: { NSApp.keyWindow?.makeFirstResponder(nil) },
                    onTab: {
                        NotificationCenter.default.post(
                            name: .inspectorDidRequestFieldNavigation,
                            object: nil,
                            userInfo: ["backward": false]
                        )
                    },
                    onShiftTab: {
                        NotificationCenter.default.post(
                            name: .inspectorDidRequestFieldNavigation,
                            object: nil,
                            userInfo: ["backward": true]
                        )
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
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
            get: {
                let raw = model.valueForTag(tag)
                guard !raw.isEmpty, !isEditing else { return raw }
                return FieldDecoration.apply(raw, tagID: tag.id)
            },
            set: { newValue in
                let stripped = FieldDecoration.strip(newValue, tagID: tag.id)
                onBeginEditSession()
                model.updateValue(stripped, for: tag)
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
