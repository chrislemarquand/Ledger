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
                .font(.title3.weight(.semibold))
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
        TableColumn("Frame No.") { Text($0.frameNumber) }.width(ideal: 60)
        TableColumn("Focal length") { Text($0.focalLength) }.width(ideal: 90)
        TableColumn("Max. aperture") { Text($0.maxAperture) }.width(ideal: 95)
        TableColumn("Tv") { Text($0.tv) }.width(ideal: 55)
        TableColumn("Av") { Text($0.av) }.width(ideal: 45)
        TableColumn("ISO (M)") { Text($0.isoM) }.width(ideal: 60)
        TableColumn("Exp. comp.") { Text($0.exposureCompensation) }.width(ideal: 75)
        TableColumn("Flash exp. comp.") { Text($0.flashExposureCompensation) }.width(ideal: 110)
        TableColumn("Flash mode") { Text($0.flashMode) }.width(ideal: 85)
        TableColumn("Metering mode") { Text($0.meteringMode) }.width(ideal: 105)
    }

    @TableColumnBuilder<EOS1VFrameRecord, Never>
    private var secondColumns: some TableColumnContent<EOS1VFrameRecord, Never> {
        TableColumn("Shooting mode") { Text($0.shootingMode) }.width(ideal: 150)
        TableColumn("Film advance") { Text($0.filmAdvance) }.width(ideal: 105)
        TableColumn("AF mode") { Text($0.afMode) }.width(ideal: 95)
        TableColumn("AF pt. focus") { Text($0.afPointAchievingFocus) }.width(ideal: 90)
        TableColumn("AF pt. select") { Text($0.afPointSelection) }.width(ideal: 90)
        TableColumn("Multiple exp.") { Text($0.multipleExposure) }.width(ideal: 95)
        TableColumn("Date") { Text($0.date) }.width(ideal: 90)
        TableColumn("Time") { Text($0.time) }.width(ideal: 75)
        TableColumn("Battery date") { Text($0.batteryDate) }.width(ideal: 100)
        TableColumn("Battery time") { Text($0.batteryTime) }.width(ideal: 90)
    }
}
