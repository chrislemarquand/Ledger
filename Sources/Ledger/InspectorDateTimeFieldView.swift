import SwiftUI
import SharedUI

struct InspectorDateTimeFieldView: View {
    let tag: AppModel.EditableTag
    @ObservedObject var model: AppModel
    let onBeginEditSession: () -> Void
    let onOpenDateTimeAdjust: () -> Void

    @State private var isHovered = false

    var body: some View {
        if let date = model.dateValueForTag(tag) {
            HStack(spacing: 6) {
                InspectorDatePickerField(
                    selection: dateBinding(fallback: date),
                    datePickerStyle: .textField,
                    accessibilityLabel: tag.label
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if isHovered {
                        Button("Clear \(tag.label)", systemImage: "xmark.circle.fill") {
                            onBeginEditSession()
                            model.clearDateValue(for: tag)
                        }
                        .buttonStyle(.plain)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                        .help("Clear date and time")
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.1), value: isHovered)

                Button("Set\u{2026}", action: onOpenDateTimeAdjust)
                    .controlSize(.small)
            }
            .onHover { isHovered = $0 }
        } else {
            HStack(spacing: 6) {
                if model.isMixedValue(for: tag) {
                    HStack {
                        Text("Multiple values")
                            .foregroundStyle(.secondary)
                            .font(.body)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    )
                } else {
                    TextField("", text: .constant(""))
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("Set\u{2026}", action: onOpenDateTimeAdjust)
                    .controlSize(.small)
            }
        }
    }

    private func dateBinding(fallback: Date) -> Binding<Date> {
        Binding(
            get: { model.dateValueForTag(tag) ?? fallback },
            set: { newDate in
                onBeginEditSession()
                model.updateDateValue(newDate, for: tag)
            }
        )
    }
}
