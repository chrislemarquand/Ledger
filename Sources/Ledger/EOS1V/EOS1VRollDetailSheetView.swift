import SwiftUI

/// Roll detail sheet: a header info block plus a full multi-column frame
/// grid, matching Canon's own "EOS-1V Memory" per-roll window. Read-only for
/// now — editing (Title/Remarks, per-field overrides) is parked pending a
/// local roll-metadata store (see docs/eos1v-roll-metadata-plan-2026-08.md).
///
/// A SwiftUI leaf presented via `NSHostingController` + `presentAsSheet(_:)`
/// from `EOS1VShootingViewController` (an AppKit controller) — the same
/// pattern already used for `LensProfileManagerSheet` from
/// `SettingsWindowController`. The outer EOS-1V device screen stays AppKit;
/// this is a self-contained modal, which is exactly the "isolated leaf
/// island" case the project's SwiftUI-by-default convention calls for.
struct EOS1VRollDetailSheetView: View {
    let roll: EOS1VFilmRoll
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            frameTable
            HStack {
                Spacer()
                Button("Close", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 960, minHeight: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(roll.id)
                .font(.title2)
                .bold()
            HStack(spacing: 24) {
                labeled("Loaded", "\(roll.loadedDate) \(roll.loadedTime)")
                labeled("Frame count", "\(roll.frames.count)")
                labeled("ISO (DX)", roll.frames.first?.isoDX ?? "—")
            }
        }
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }

    private var frameTable: some View {
        // TableColumnBuilder caps out around 10 columns per block, so the
        // full field list is split across two grouped builder properties.
        Table(roll.frames) {
            firstColumns
            secondColumns
        }
    }

    @TableColumnBuilder<EOS1VFrameRecord, Never>
    private var firstColumns: some TableColumnContent<EOS1VFrameRecord, Never> {
        TableColumn("Frame No.") { Text($0.frameNumber) }
        TableColumn("Focal length") { Text($0.focalLength) }
        TableColumn("Max. aperture") { Text($0.maxAperture) }
        TableColumn("Tv") { Text($0.tv) }
        TableColumn("Av") { Text($0.av) }
        TableColumn("ISO (M)") { Text($0.isoM) }
        TableColumn("Exp. comp.") { Text($0.exposureCompensation) }
        TableColumn("Flash exp. comp.") { Text($0.flashExposureCompensation) }
        TableColumn("Flash mode") { Text($0.flashMode) }
        TableColumn("Metering mode") { Text($0.meteringMode) }
    }

    @TableColumnBuilder<EOS1VFrameRecord, Never>
    private var secondColumns: some TableColumnContent<EOS1VFrameRecord, Never> {
        TableColumn("Shooting mode") { Text($0.shootingMode) }
        TableColumn("Film advance") { Text($0.filmAdvance) }
        TableColumn("AF mode") { Text($0.afMode) }
        TableColumn("AF pt. focus") { Text($0.afPointAchievingFocus) }
        TableColumn("AF pt. select") { Text($0.afPointSelection) }
        TableColumn("Multiple exp.") { Text($0.multipleExposure) }
        TableColumn("Date") { Text($0.date) }
        TableColumn("Time") { Text($0.time) }
        TableColumn("Battery date") { Text($0.batteryDate) }
        TableColumn("Battery time") { Text($0.batteryTime) }
    }
}
