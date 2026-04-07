import SharedUI
import SwiftUI

// MARK: - Column definitions

private struct ReviewColumn {
    let tagID: String
    let label: String
    let width: CGFloat
}

private let fileColumnWidth: CGFloat = 180
private let rowToggleWidth: CGFloat = 24

// MARK: - Sheet

struct ImportReviewSheetView: View {
    @ObservedObject var model: AppModel
    @Binding var reviewState: ImportReviewState
    let onApply: ([ImportReviewRow]) -> Void
    let onCancel: () -> Void

    private static let sectionSpacing = WorkflowSheetSectionSpacing.uniform(16)

    private var columns: [ReviewColumn] {
        reviewState.columnTagIDs.map { tagID in
            ReviewColumn(
                tagID: tagID,
                label: reviewState.columnLabels[tagID] ?? tagID,
                width: columnWidth(for: tagID)
            )
        }
    }

    private var totalGridWidth: CGFloat {
        rowToggleWidth + fileColumnWidth + columns.reduce(0) { $0 + $1.width + 8 }
    }

    var body: some View {
        WorkflowSheetContainer(
            title: "Review Import",
            subtitle: rowSummary,
            width: max(totalGridWidth + 40, 620),
            sectionSpacing: Self.sectionSpacing
        ) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                    .padding(.bottom, 4)

                Divider()

                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach($reviewState.rows) { $row in
                            ReviewRowView(
                                row: $row,
                                columns: columns,
                                gearLibrary: model.gearLibrary,
                                onLensEdited: { newValue in
                                    cascadeLens(newValue, fromRowID: row.id)
                                }
                            )
                            Divider().opacity(0.4)
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 420)
                .padding(.bottom, Self.sectionSpacing.mainToFooter)

                footerRow
            }
        }
    }

    // MARK: - Header row

    private var headerRow: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: rowToggleWidth)
            Text("File")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: fileColumnWidth, alignment: .leading)
            ForEach(columns, id: \.tagID) { col in
                Text(col.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: col.width, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Apply") {
                onApply(reviewState.rows.filter(\.isIncluded))
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Helpers

    private var rowSummary: String {
        let total = reviewState.rows.count
        let included = reviewState.rows.filter(\.isIncluded).count
        if included == total {
            return "\(total) \(total == 1 ? "frame" : "frames")"
        }
        return "\(included) of \(total) \(total == 1 ? "frame" : "frames") selected"
    }

    private func columnWidth(for tagID: String) -> CGFloat {
        switch tagID {
        case "exif-aperture":  return 80
        case "exif-shutter":   return 90
        case "exif-focal":     return 80
        case "exif-lens":      return 200
        case "exif-make", "exif-model": return 120
        default:               return 120
        }
    }

    private func cascadeLens(_ newValue: String, fromRowID: UUID) {
        guard let startIdx = reviewState.rows.firstIndex(where: { $0.id == fromRowID }) else { return }
        for idx in (startIdx + 1)..<reviewState.rows.count {
            guard reviewState.rows[idx].lensIsCarriedForward else { continue }
            let lensIdx = reviewState.rows[idx].fields.firstIndex(where: { $0.tagID == "exif-lens" })
            guard let lensIdx else { continue }
            if reviewState.rows[idx].fields[lensIdx].isEdited { continue }
            reviewState.rows[idx].fields[lensIdx].value = newValue
        }
    }
}

// MARK: - Row view

private struct ReviewRowView: View {
    @Binding var row: ImportReviewRow
    let columns: [ReviewColumn]
    let gearLibrary: GearLibrary
    let onLensEdited: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $row.isIncluded)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: rowToggleWidth)

            Text(row.displayName)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.isIncluded ? .primary : .tertiary)
                .frame(width: fileColumnWidth, alignment: .leading)

            ForEach(columns, id: \.tagID) { col in
                cellView(for: col)
                    .frame(width: col.width)
                    .disabled(!row.isIncluded)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func cellView(for col: ReviewColumn) -> some View {
        let tagID = col.tagID
        let currentValue = row.field(forTagID: tagID)?.value ?? ""
        let valueBinding = Binding<String>(
            get: { row.field(forTagID: tagID)?.value ?? "" },
            set: { newVal in
                row.setValue(newVal, forTagID: tagID)
                if tagID == "exif-lens" { onLensEdited(newVal) }
            }
        )

        if tagID == "exif-lens", !gearLibrary.lenses.isEmpty {
            let options = [InspectorPopupOption(value: "", label: "—")] +
                gearLibrary.lenses.map { InspectorPopupOption(value: $0.name, label: $0.name) }
            InspectorPopupField(selection: valueBinding, options: options)
        } else if tagID == "exif-aperture" {
            let lens = currentLens
            let stops = gearLibrary.apertureOptions(for: lens)
            if !stops.isEmpty {
                let options = [InspectorPopupOption(value: "", label: "—")] +
                    stops.map { InspectorPopupOption(value: $0, label: "ƒ/\($0)") }
                InspectorPopupField(selection: valueBinding, options: options)
            } else {
                textCell(binding: valueBinding, placeholder: "—")
            }
        } else if tagID == "exif-shutter" {
            let camera = currentCamera
            let speeds = gearLibrary.shutterOptions(for: camera)
            let options = [InspectorPopupOption(value: "", label: "—")] +
                speeds.map { InspectorPopupOption(value: $0, label: "\($0) s") }
            InspectorPopupField(selection: valueBinding, options: options)
        } else {
            textCell(binding: valueBinding, placeholder: "—")
        }
    }

    private func textCell(binding: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: binding)
            .textFieldStyle(.roundedBorder)
            .font(.callout)
    }

    private var currentLens: GearLens? {
        let lensName = row.field(forTagID: "exif-lens")?.value ?? ""
        return gearLibrary.lenses.first { $0.name == lensName }
    }

    private var currentCamera: GearCamera? {
        nil  // camera selection not yet surfaced in the row model; future extension
    }
}

// MARK: - Sheet presenter

extension View {
    func importReviewSheet(
        model: AppModel,
        reviewState: Binding<ImportReviewState?>,
        onApply: @escaping ([ImportReviewRow]) -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        sheet(item: reviewState) { _ in
            ImportReviewSheetView(
                model: model,
                reviewState: Binding(
                    get: { reviewState.wrappedValue ?? ImportReviewState(rows: [], columnTagIDs: [], columnLabels: [:]) },
                    set: { reviewState.wrappedValue = $0 }
                ),
                onApply: { rows in
                    onApply(rows)
                    reviewState.wrappedValue = nil
                },
                onCancel: {
                    onCancel()
                    reviewState.wrappedValue = nil
                }
            )
        }
    }
}
