import SharedUI
import SwiftUI

struct LensProfileManagerSheet: View {
    @ObservedObject var model: AppModel
    /// Presented via NSHostingController + presentAsSheet (an AppKit sheet, not a SwiftUI
    /// one) — @Environment(\.dismiss) has nothing to dismiss in that context, so closing
    /// has to go back out to the hosting controller instead.
    let onDone: () -> Void
    @State private var selectedLensID: UUID?
    @State private var pendingDeleteLensID: UUID?
    @State private var editorTarget: LensProfileEditorTarget?

    private static let sectionSpacing = WorkflowSheetSectionSpacing.uniform(12)

    var body: some View {
        WorkflowSheetContainer(
            title: "Lenses",
            subtitle: "Used to resolve ambiguous focal lengths during EOS-1V import.",
            width: 480,
            sectionSpacing: Self.sectionSpacing
        ) {
            VStack(alignment: .leading, spacing: 12) {
                List(model.lensProfiles, selection: $selectedLensID) { profile in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                        Text(summary(for: profile))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(profile.id)
                }
                .frame(minHeight: 240)

                HStack {
                    Button("New…") {
                        editorTarget = .createBlank
                    }
                    Button("Edit…") {
                        guard let profile = selectedProfile else { return }
                        editorTarget = .edit(profile)
                    }
                    .disabled(selectedProfile == nil)
                    Button("Duplicate") {
                        guard let selectedLensID else { return }
                        if let duplicate = model.duplicateLensProfile(id: selectedLensID) {
                            self.selectedLensID = duplicate.id
                        }
                    }
                    .disabled(selectedProfile == nil)
                    Button("Delete", role: .destructive) {
                        pendingDeleteLensID = selectedLensID
                    }
                    .disabled(selectedProfile == nil)

                    Spacer()

                    Button("Done") {
                        onDone()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            LensProfileEditorSheet(model: model, target: target)
        }
        .alert(
            pendingDeleteLensID.flatMap { id in model.lensProfiles.first { $0.id == id }?.name }.map { "Delete “\($0)”?" } ?? "Delete Lens?",
            isPresented: Binding(
                get: { pendingDeleteLensID != nil },
                set: { newValue in if !newValue { pendingDeleteLensID = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let pendingDeleteLensID else { return }
                model.deleteLensProfile(id: pendingDeleteLensID)
                if selectedLensID == pendingDeleteLensID { selectedLensID = nil }
                self.pendingDeleteLensID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteLensID = nil
            }
        } message: {
            Text("This action can’t be undone.")
        }
    }

    private var selectedProfile: LensProfile? {
        guard let selectedLensID else { return nil }
        return model.lensProfiles.first { $0.id == selectedLensID }
    }

    private func summary(for profile: LensProfile) -> String {
        let focal = profile.kind == .prime
            ? "\(profile.minFocalLengthMM)mm"
            : "\(profile.minFocalLengthMM)–\(profile.maxFocalLengthMM)mm"
        let aperture: String
        if let near = profile.widestApertureAtMinFocal {
            if let far = profile.widestApertureAtMaxFocal, far != near {
                aperture = "f/\(formatted(near))–\(formatted(far))"
            } else {
                aperture = "f/\(formatted(near))"
            }
        } else {
            aperture = "aperture unknown"
        }
        return "\(focal) · \(aperture)"
    }

    private func formatted(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

enum LensProfileEditorTarget: Identifiable, Hashable {
    case createBlank
    case edit(LensProfile)

    var id: String {
        switch self {
        case .createBlank: return "createBlank"
        case let .edit(profile): return profile.id.uuidString
        }
    }
}

struct LensProfileEditorSheet: View {
    @ObservedObject var model: AppModel
    let target: LensProfileEditorTarget
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var kind: LensKind
    @State private var minFocalLengthMM: Int
    @State private var maxFocalLengthMM: Int
    @State private var widestApertureAtMinFocal: Double?
    @State private var widestApertureAtMaxFocal: Double?

    private static let sectionSpacing = WorkflowSheetSectionSpacing.uniform(14)
    private static let labelColumnWidth: CGFloat = 132
    private static let formRowSpacing: CGFloat = 10

    init(model: AppModel, target: LensProfileEditorTarget) {
        self.model = model
        self.target = target
        let existing: LensProfile? = {
            if case let .edit(profile) = target { return profile }
            return nil
        }()
        _name = State(initialValue: existing?.name ?? "")
        _kind = State(initialValue: existing?.kind ?? .prime)
        _minFocalLengthMM = State(initialValue: existing?.minFocalLengthMM ?? 50)
        _maxFocalLengthMM = State(initialValue: existing?.maxFocalLengthMM ?? 50)
        _widestApertureAtMinFocal = State(initialValue: existing?.widestApertureAtMinFocal)
        _widestApertureAtMaxFocal = State(initialValue: existing?.widestApertureAtMaxFocal)
    }

    var body: some View {
        WorkflowSheetContainer(
            title: isEditing ? "Edit Lens" : "New Lens",
            sectionSpacing: Self.sectionSpacing
        ) {
            VStack(alignment: .leading, spacing: Self.formRowSpacing) {
                row("Name:") {
                    TextField("e.g. EF50mm f1.8 STM", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                }

                row("Kind:") {
                    Picker("", selection: $kind) {
                        Text("Prime").tag(LensKind.prime)
                        Text("Zoom").tag(LensKind.zoom)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                if kind == .prime {
                    row("Focal Length:") {
                        focalLengthField(value: $minFocalLengthMM, suffix: "mm")
                    }
                    row("Maximum Aperture:") {
                        apertureField(value: $widestApertureAtMinFocal)
                    }
                } else {
                    row("Narrowest Focal Length:") {
                        focalLengthField(value: $maxFocalLengthMM, suffix: "mm")
                    }
                    row("Widest Focal Length:") {
                        focalLengthField(value: $minFocalLengthMM, suffix: "mm")
                    }
                    row("Aperture at Wide End:") {
                        apertureField(value: $widestApertureAtMinFocal)
                    }
                    row("Aperture at Tele End:") {
                        HStack(spacing: 6) {
                            apertureField(value: $widestApertureAtMaxFocal)
                            Text("(blank = constant)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid)
                }
                .padding(.top, 4)
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Every row in this sheet shares one left-aligned label column, so labels line up
    /// down the left edge and fields all start at the same x and stretch to the trailing
    /// edge — matching the Figma "Adjust Date and Time" reference rather than
    /// WorkflowFormRow's default right-aligned label.
    @ViewBuilder
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        WorkflowFormRow(label, labelWidth: Self.labelColumnWidth, labelAlignment: .leading, content: content)
    }

    @ViewBuilder
    private func focalLengthField(value: Binding<Int>, suffix: String) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            Text(suffix).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func apertureField(value: Binding<Double?>) -> some View {
        HStack(spacing: 6) {
            Text("f/").foregroundStyle(.secondary)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
        }
    }

    private func save() {
        let now = Date()
        var minMM = minFocalLengthMM
        var maxMM = maxFocalLengthMM
        var minAperture = widestApertureAtMinFocal
        var maxAperture = widestApertureAtMaxFocal
        if kind == .prime {
            maxMM = minMM
            maxAperture = nil
        }
        // Keep the stored range ordered even if the fields were entered backwards.
        if minMM > maxMM { swap(&minMM, &maxMM) }
        if let minA = minAperture, let maxA = maxAperture, minA > maxA {
            swap(&minAperture, &maxAperture)
        }

        switch target {
        case .createBlank:
            model.createLensProfile(
                LensProfile(
                    id: UUID(),
                    name: name,
                    kind: kind,
                    minFocalLengthMM: minMM,
                    maxFocalLengthMM: maxMM,
                    widestApertureAtMinFocal: minAperture,
                    widestApertureAtMaxFocal: maxAperture,
                    notes: nil,
                    createdAt: now,
                    updatedAt: now
                )
            )
        case let .edit(existing):
            model.updateLensProfile(
                LensProfile(
                    id: existing.id,
                    name: name,
                    kind: kind,
                    minFocalLengthMM: minMM,
                    maxFocalLengthMM: maxMM,
                    widestApertureAtMinFocal: minAperture,
                    widestApertureAtMaxFocal: maxAperture,
                    notes: existing.notes,
                    createdAt: existing.createdAt,
                    updatedAt: now
                )
            )
        }
        dismiss()
    }
}
