import AppKit
import SwiftUI

// MARK: - View

struct GearSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedLensID: UUID?
    @State private var selectedCameraID: UUID?
    @State private var editingLens: GearLens?
    @State private var editingCamera: GearCamera?
    @State private var showLensEditor = false
    @State private var showCameraEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            lensSection
            cameraSection
        }
        .padding(20)
        .frame(width: 580)
        .sheet(isPresented: $showLensEditor) {
            if let lens = editingLens {
                LensEditorSheet(
                    lens: lens,
                    onSave: { updated in
                        if let idx = model.gearLibrary.lenses.firstIndex(where: { $0.id == updated.id }) {
                            model.gearLibrary.lenses[idx] = updated
                        } else {
                            model.gearLibrary.lenses.append(updated)
                        }
                        showLensEditor = false
                    },
                    onCancel: { showLensEditor = false }
                )
            }
        }
        .sheet(isPresented: $showCameraEditor) {
            if let camera = editingCamera {
                CameraEditorSheet(
                    camera: camera,
                    allLenses: model.gearLibrary.lenses,
                    onSave: { updated in
                        if let idx = model.gearLibrary.cameras.firstIndex(where: { $0.id == updated.id }) {
                            model.gearLibrary.cameras[idx] = updated
                        } else {
                            model.gearLibrary.cameras.append(updated)
                        }
                        showCameraEditor = false
                    },
                    onCancel: { showCameraEditor = false }
                )
            }
        }
    }

    // MARK: - Lens section

    private var lensSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lenses")
                .font(.headline)

            List(model.gearLibrary.lenses, selection: $selectedLensID) { lens in
                VStack(alignment: .leading, spacing: 2) {
                    Text(lens.name)
                    Text("\(lens.focalRange) mm · max ƒ/\(GearLibrary.formatAperture(lens.maxAperture))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(lens.id)
            }
            .frame(height: 140)

            HStack(spacing: 6) {
                Button("Add") {
                    editingLens = GearLens(name: "", focalRange: "", maxAperture: 4.0)
                    showLensEditor = true
                }
                Button("Edit…") {
                    guard let id = selectedLensID,
                          let lens = model.gearLibrary.lenses.first(where: { $0.id == id })
                    else { return }
                    editingLens = lens
                    showLensEditor = true
                }
                .disabled(selectedLensID == nil)
                Button("Remove") {
                    guard let id = selectedLensID else { return }
                    model.gearLibrary.lenses.removeAll { $0.id == id }
                    // Remove from cameras too
                    for idx in model.gearLibrary.cameras.indices {
                        model.gearLibrary.cameras[idx].lensIDs.removeAll { $0 == id }
                    }
                    selectedLensID = nil
                }
                .disabled(selectedLensID == nil)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Camera section

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cameras")
                .font(.headline)

            List(model.gearLibrary.cameras, selection: $selectedCameraID) { camera in
                VStack(alignment: .leading, spacing: 2) {
                    Text(camera.name)
                    let lensCount = model.gearLibrary.availableLenses(for: camera).count
                    Text(lensCount == 0 ? "All lenses" : "\(lensCount) \(lensCount == 1 ? "lens" : "lenses")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(camera.id)
            }
            .frame(height: 120)

            HStack(spacing: 6) {
                Button("Add") {
                    editingCamera = GearCamera(name: "")
                    showCameraEditor = true
                }
                Button("Edit…") {
                    guard let id = selectedCameraID,
                          let camera = model.gearLibrary.cameras.first(where: { $0.id == id })
                    else { return }
                    editingCamera = camera
                    showCameraEditor = true
                }
                .disabled(selectedCameraID == nil)
                Button("Remove") {
                    guard let id = selectedCameraID else { return }
                    model.gearLibrary.cameras.removeAll { $0.id == id }
                    selectedCameraID = nil
                }
                .disabled(selectedCameraID == nil)
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Lens editor sheet

private struct LensEditorSheet: View {
    @State var lens: GearLens
    let onSave: (GearLens) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lens.name.isEmpty ? "New Lens" : lens.name)
                .font(.title3.weight(.semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("e.g. EF 24-105mm f/4L IS", text: $lens.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
                GridRow {
                    Text("Focal range").gridColumnAlignment(.trailing)
                    TextField("e.g. 24-105 or 50", text: $lens.focalRange)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Max aperture").gridColumnAlignment(.trailing)
                    HStack(spacing: 6) {
                        Text("ƒ/")
                        TextField("e.g. 4.0", value: $lens.maxAperture, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
            }

            Text("Aperture stops are automatically generated from the max aperture. You can override them per-lens in a future update.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(lens) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(lens.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - Camera editor sheet

private struct CameraEditorSheet: View {
    @State var camera: GearCamera
    let allLenses: [GearLens]
    let onSave: (GearCamera) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(camera.name.isEmpty ? "New Camera" : camera.name)
                .font(.title3.weight(.semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("e.g. Canon EOS 1V", text: $camera.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
                GridRow {
                    Text("Max shutter").gridColumnAlignment(.trailing)
                    Picker("", selection: Binding(
                        get: { camera.maxShutterSpeed ?? "" },
                        set: { camera.maxShutterSpeed = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Full range").tag("")
                        ForEach(GearLibrary.allShutterSpeeds.prefix(12), id: \.self) { speed in
                            Text(speed).tag(speed)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
            }

            if !allLenses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Compatible lenses (leave blank for all)")
                        .font(.callout)
                    ForEach(allLenses) { lens in
                        Toggle(lens.name, isOn: Binding(
                            get: { camera.lensIDs.contains(lens.id) },
                            set: { include in
                                if include {
                                    if !camera.lensIDs.contains(lens.id) {
                                        camera.lensIDs.append(lens.id)
                                    }
                                } else {
                                    camera.lensIDs.removeAll { $0 == lens.id }
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(camera) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(camera.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - NSViewController wrapper

@MainActor
final class GearSettingsViewController: NSViewController {
    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let hosting = NSHostingController(rootView: GearSettingsView(model: model))
        addChild(hosting)
        view = hosting.view
    }
}
