import SwiftUI

struct InspectorClearableTextField<Trailing: View>: View {
    var text: Binding<String>
    var prompt: String
    var fieldLabel: String
    var tagID: String
    @FocusState.Binding var focusedTagID: String?
    var onClear: () -> Void
    var trailingContent: Trailing

    @State private var isHovered = false

    init(
        text: Binding<String>,
        prompt: String,
        fieldLabel: String,
        tagID: String,
        focusedTagID: FocusState<String?>.Binding,
        onClear: @escaping () -> Void,
        @ViewBuilder trailingContent: () -> Trailing
    ) {
        self.text = text
        self.prompt = prompt
        self.fieldLabel = fieldLabel
        self.tagID = tagID
        self._focusedTagID = focusedTagID
        self.onClear = onClear
        self.trailingContent = trailingContent()
    }

    private var showClearButton: Bool {
        !text.wrappedValue.isEmpty && (isHovered || focusedTagID == tagID)
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField(
                "",
                text: text,
                prompt: Text(prompt).foregroundStyle(.secondary)
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($focusedTagID, equals: tagID)
            .overlay(alignment: .trailing) {
                if showClearButton {
                    Button("Clear \(fieldLabel)", systemImage: "xmark.circle.fill", action: onClear)
                        .buttonStyle(.plain)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                        .help("Clear \(fieldLabel)")
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.1), value: showClearButton)

            trailingContent
        }
        .onHover { isHovered = $0 }
    }
}

extension InspectorClearableTextField where Trailing == EmptyView {
    init(
        text: Binding<String>,
        prompt: String,
        fieldLabel: String,
        tagID: String,
        focusedTagID: FocusState<String?>.Binding,
        onClear: @escaping () -> Void
    ) {
        self.init(
            text: text,
            prompt: prompt,
            fieldLabel: fieldLabel,
            tagID: tagID,
            focusedTagID: focusedTagID,
            onClear: onClear,
            trailingContent: { EmptyView() }
        )
    }
}
