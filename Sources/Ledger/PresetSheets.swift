import SwiftUI

struct PresetEditorSheet: View {
    @ObservedObject var model: AppModel
    @State private var editor: PresetEditorState
    @State private var validationMessage: String?
    @State private var duplicateConflict: MetadataPreset?

    init(model: AppModel, initialEditor: PresetEditorState) {
        self.model = model
        _editor = State(initialValue: initialEditor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editorTitle)
                .font(.title3.weight(.semibold))

            HStack {
                Text("Name")
                    .frame(width: 70, alignment: .leading)
                TextField("Enter a name", text: $editor.name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top) {
                Text("Notes")
                    .frame(width: 70, alignment: .leading)
                    .padding(.top, 6)
                TextField("Add notes (optional)", text: $editor.notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 3)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.groupedEditableTags, id: \.section) { grouped in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(grouped.section.uppercased())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.4)

                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(grouped.tags) { tag in
                                    HStack(alignment: .top, spacing: 10) {
                                        Toggle("", isOn: includeBinding(for: tag))
                                            .labelsHidden()
                                            .toggleStyle(.checkbox)
                                            .padding(.top, 3)

                                        Text(tag.label)
                                            .font(.callout)
                                            .frame(width: 160, alignment: .leading)
                                            .padding(.top, 4)

                                        presetControl(for: tag)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.quaternary.opacity(0.35))
                            )
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    let reopenManagePresets: Bool = {
                        switch editor.mode {
                        case .createFromCurrent:
                            return false
                        case .createBlank, .edit:
                            return true
                        }
                    }()
                    model.dismissPresetEditor(reopenManagePresets: reopenManagePresets)
                }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    handleSave()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 760, height: 520)
        .alert("A preset with this name already exists.", isPresented: duplicateAlertBinding) {
            Button("Replace") {
                replaceExistingPreset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose a different name, or replace the existing preset.")
        }
    }

    private var editorTitle: String {
        switch editor.mode {
        case .createFromCurrent:
            return "Save as Preset"
        case .createBlank:
            return "New Preset"
        case .edit:
            return "Edit Preset"
        }
    }

    private var duplicateAlertBinding: Binding<Bool> {
        Binding(
            get: { duplicateConflict != nil },
            set: { newValue in
                if !newValue { duplicateConflict = nil }
            }
        )
    }

    private func includeBinding(for tag: AppModel.EditableTag) -> Binding<Bool> {
        Binding(
            get: { editor.includedTagIDs.contains(tag.id) },
            set: { include in
                if include {
                    editor.includedTagIDs.insert(tag.id)
                } else {
                    editor.includedTagIDs.remove(tag.id)
                }
            }
        )
    }

    private func valueBinding(for tag: AppModel.EditableTag) -> Binding<String> {
        Binding(
            get: { editor.valuesByTagID[tag.id] ?? "" },
            set: { updatePresetValue($0, for: tag) }
        )
    }

    private func updatePresetValue(_ value: String, for tag: AppModel.EditableTag) {
        editor.valuesByTagID[tag.id] = value
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editor.includedTagIDs.insert(tag.id)
        }
    }

    @ViewBuilder
    private func presetControl(for tag: AppModel.EditableTag) -> some View {
        if model.isDateTimeTag(tag) {
            let raw = editor.valuesByTagID[tag.id] ?? ""
            if let date = model.parseEditableDateValue(raw) {
                HStack(spacing: 6) {
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { model.parseEditableDateValue(editor.valuesByTagID[tag.id] ?? "") ?? date },
                            set: { updatePresetValue(model.formatEditableDateValue($0), for: tag) }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .datePickerStyle(.field)

                    Button {
                        updatePresetValue("", for: tag)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 6) {
                    TextField("", text: .constant(""))
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button("Set") {
                        updatePresetValue(model.formatEditableDateValue(Date()), for: tag)
                    }
                    .controlSize(.small)
                }
            }
        } else if let options = presetPickerOptions(for: tag) {
            Picker("", selection: valueBinding(for: tag)) {
                Text("Not Set").tag("")
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        } else {
            TextField("", text: valueBinding(for: tag), axis: .vertical)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func presetPickerOptions(for tag: AppModel.EditableTag) -> [AppModel.PickerOption]? {
        switch tag.id {
        case "exif-exposure-program":
            return [
                .init(value: "0", label: "Not Defined"),
                .init(value: "1", label: "Manual"),
                .init(value: "2", label: "Program AE"),
                .init(value: "3", label: "Aperture-priority AE"),
                .init(value: "4", label: "Shutter-priority AE"),
                .init(value: "5", label: "Creative Program"),
                .init(value: "6", label: "Action Program"),
                .init(value: "7", label: "Portrait Mode"),
                .init(value: "8", label: "Landscape Mode")
            ]
        case "exif-flash":
            return [
                .init(value: "0", label: "No Flash"),
                .init(value: "1", label: "Fired"),
                .init(value: "5", label: "Fired, Return Not Detected"),
                .init(value: "7", label: "Fired, Return Detected"),
                .init(value: "9", label: "On, Did Not Fire"),
                .init(value: "13", label: "On, Return Not Detected"),
                .init(value: "15", label: "On, Return Detected"),
                .init(value: "16", label: "Off, Did Not Fire"),
                .init(value: "24", label: "Auto, Did Not Fire"),
                .init(value: "25", label: "Auto, Fired"),
                .init(value: "29", label: "Auto, Fired, Return Not Detected"),
                .init(value: "31", label: "Auto, Fired, Return Detected"),
                .init(value: "32", label: "No Flash Function"),
                .init(value: "65", label: "Fired, Red-eye Reduction"),
                .init(value: "69", label: "Fired, Red-eye, Return Not Detected"),
                .init(value: "71", label: "Fired, Red-eye, Return Detected"),
                .init(value: "73", label: "On, Red-eye, Did Not Fire"),
                .init(value: "77", label: "On, Red-eye, Return Not Detected"),
                .init(value: "79", label: "On, Red-eye, Return Detected"),
                .init(value: "89", label: "Auto, Fired, Red-eye"),
                .init(value: "93", label: "Auto, Fired, Red-eye, Return Not Detected"),
                .init(value: "95", label: "Auto, Fired, Red-eye, Return Detected")
            ]
        case "exif-metering-mode":
            return [
                .init(value: "0", label: "Unknown"),
                .init(value: "1", label: "Average"),
                .init(value: "2", label: "Center-weighted Average"),
                .init(value: "3", label: "Spot"),
                .init(value: "4", label: "Multi-spot"),
                .init(value: "5", label: "Multi-segment"),
                .init(value: "6", label: "Partial"),
                .init(value: "255", label: "Other")
            ]
        default:
            return nil
        }
    }

    private func handleSave() {
        validationMessage = nil

        let trimmedName = editor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Preset name is required."
            return
        }
        guard !editor.includedTagIDs.isEmpty else {
            validationMessage = "Select at least one field to include."
            return
        }

        let conflictingPreset = model.presets.first { preset in
            if case let .edit(editingID) = editor.mode, preset.id == editingID {
                return false
            }
            return preset.name.compare(trimmedName, options: .caseInsensitive) == .orderedSame
        }

        if let conflictingPreset {
            duplicateConflict = conflictingPreset
            return
        }

        persist(editorName: trimmedName, overridePresetID: nil)
    }

    private func replaceExistingPreset() {
        guard let duplicateConflict else { return }
        persist(
            editorName: editor.name.trimmingCharacters(in: .whitespacesAndNewlines),
            overridePresetID: duplicateConflict.id
        )
        self.duplicateConflict = nil
    }

    private func persist(editorName: String, overridePresetID: UUID?) {
        let fields = editor.includedTagIDs.map { tagID in
            PresetFieldValue(tagID: tagID, value: editor.valuesByTagID[tagID] ?? "")
        }
        let notes = editor.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNotes = notes.isEmpty ? nil : notes

        let saved: MetadataPreset?
        if let overridePresetID {
            saved = model.updatePreset(id: overridePresetID, name: editorName, notes: normalizedNotes, fields: fields)
        } else {
            switch editor.mode {
            case .createFromCurrent, .createBlank:
                saved = model.createPreset(name: editorName, notes: normalizedNotes, fields: fields)
            case let .edit(id):
                saved = model.updatePreset(id: id, name: editorName, notes: normalizedNotes, fields: fields)
            }
        }

        if saved != nil {
            model.dismissPresetEditor()
        } else {
            validationMessage = "Could not save preset."
        }
    }
}

struct PresetManagerSheet: View {
    @ObservedObject var model: AppModel
    @State private var selectedPresetID: UUID?
    @State private var pendingDeletePresetID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Presets")
                .font(.title3.weight(.semibold))

            List(model.presets, selection: $selectedPresetID) { preset in
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                    Text("\(preset.fields.count) field\(preset.fields.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(preset.id)
            }
            .frame(minHeight: 280)

            HStack {
                Button("New Preset…") {
                    DispatchQueue.main.async {
                        model.beginCreateBlankPreset()
                        model.isManagePresetsPresented = false
                    }
                }

                Button("Edit…") {
                    guard let selectedPresetID else { return }
                    DispatchQueue.main.async {
                        model.beginEditPreset(selectedPresetID)
                        model.isManagePresetsPresented = false
                    }
                }
                .disabled(selectedPresetID == nil)

                Button("Duplicate") {
                    guard let selectedPresetID else { return }
                    _ = model.duplicatePreset(id: selectedPresetID)
                }
                .disabled(selectedPresetID == nil)

                Button("Delete", role: .destructive) {
                    pendingDeletePresetID = selectedPresetID
                }
                .disabled(selectedPresetID == nil)

                Spacer()

                Button("Done") {
                    DispatchQueue.main.async {
                        model.isManagePresetsPresented = false
                    }
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 420)
        .onAppear {
            if selectedPresetID == nil {
                selectedPresetID = model.selectedPresetID ?? model.presets.first?.id
            }
        }
        .alert(
            pendingDeletePresetID.flatMap { id in model.presets.first { $0.id == id }?.name }.map { "Delete “\($0)”?" } ?? "Delete Preset?",
            isPresented: Binding(
            get: { pendingDeletePresetID != nil },
            set: { newValue in
                if !newValue { pendingDeletePresetID = nil }
            }
        )) {
            Button("Delete", role: .destructive) {
                guard let pendingDeletePresetID else { return }
                model.deletePreset(id: pendingDeletePresetID)
                selectedPresetID = model.selectedPresetID ?? model.presets.first?.id
                self.pendingDeletePresetID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletePresetID = nil
            }
        } message: {
            Text("This action can’t be undone.")
        }
    }
}
