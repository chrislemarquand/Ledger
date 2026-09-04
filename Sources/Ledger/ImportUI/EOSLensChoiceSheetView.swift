import SharedUI
import SwiftUI

/// Presented as a second sheet on top of `ImportSheetView` when an EOS-1V import has rows
/// whose focal length matches more than one registered lens. Replaces the old per-row
/// blocking `NSAlert` loop (`ImportSession.chooseLens`) with one screen showing every
/// ambiguous frame at once, laid out like `BatchRenameSheetView`'s token rows — the sheet
/// grows to fit its rows rather than scrolling a fixed-height box.
struct EOSLensChoiceSheetView: View {
    let rows: [ImportSession.EOSLensAmbiguousRow]
    let onCancel: () -> Void
    let onContinue: ([URL: String]) -> Void

    @State private var selections: [URL: String] = [:]
    @State private var linkedByFocal: [Int: Bool] = [:]
    @State private var linkedSelectionByFocal: [Int: String] = [:]

    private static let leaveBlankID = "leaveBlank"
    private static let sheetWidth: CGFloat = 620
    private static let sectionSpacing = WorkflowSheetSectionSpacing.uniform(16)
    private static let rowSpacing: CGFloat = 10
    private static let columnSpacing: CGFloat = 12
    private static let focalColumnWidth: CGFloat = 56
    private static let apertureColumnWidth: CGFloat = 56
    private static let pickerWidth: CGFloat = 220
    // WorkflowSheetContainer pads its content 20pt per side, so this is the exact
    // width every row/header/footer HStack below is pinned to — the only way to
    // guarantee their trailing elements share one right edge, rather than hoping
    // SwiftUI's flexible-frame size negotiation lines them up on its own.
    private static let contentWidth: CGFloat = sheetWidth - 40

    var body: some View {
        WorkflowSheetContainer(
            title: "Choose Lenses",
            subtitle: subtitle,
            width: Self.sheetWidth,
            sectionSpacing: Self.sectionSpacing
        ) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groupedByFocal, id: \.focalMillimeters) { group in
                        VStack(alignment: .leading, spacing: Self.rowSpacing) {
                            HStack(spacing: Self.columnSpacing) {
                                Text("\(group.focalMillimeters)mm — \(group.rows.count) frame\(group.rows.count == 1 ? "" : "s")")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if group.rows.count > 1 {
                                    Toggle("Apply to all at this focal length", isOn: linkedBinding(for: group))
                                        .toggleStyle(.checkbox)
                                        .font(.caption)
                                }
                            }
                            .frame(width: Self.contentWidth, alignment: .leading)

                            ForEach(group.rows) { row in
                                LensChoiceRow(
                                    fileName: row.targetFileName,
                                    focalMillimeters: row.focalMillimeters,
                                    frameMaxAperture: row.frameMaxAperture,
                                    candidates: row.candidates,
                                    rowWidth: Self.contentWidth,
                                    columnSpacing: Self.columnSpacing,
                                    focalColumnWidth: Self.focalColumnWidth,
                                    apertureColumnWidth: Self.apertureColumnWidth,
                                    pickerWidth: Self.pickerWidth,
                                    selectedOptionID: binding(for: row)
                                )
                            }
                        }
                    }
                }
                .padding(.bottom, Self.sectionSpacing.mainToFooter)

                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Continue") {
                        onContinue(resolutions())
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                .frame(width: Self.contentWidth, alignment: .leading)
            }
        }
        .onAppear(perform: seedSelectionsIfNeeded)
    }

    private var subtitle: String {
        let n = rows.count
        return n == 1 ? "1 frame matched more than one lens." : "\(n) frames matched more than one lens."
    }

    private struct FocalGroup {
        let focalMillimeters: Int
        let rows: [ImportSession.EOSLensAmbiguousRow]
    }

    private var groupedByFocal: [FocalGroup] {
        let grouped = Dictionary(grouping: rows, by: \.focalMillimeters)
        return grouped.keys.sorted().map { mm in
            FocalGroup(focalMillimeters: mm, rows: grouped[mm] ?? [])
        }
    }

    private func defaultSelection(for row: ImportSession.EOSLensAmbiguousRow) -> String {
        row.candidates.first ?? Self.leaveBlankID
    }

    private func seedSelectionsIfNeeded() {
        for row in rows where selections[row.targetURL] == nil {
            selections[row.targetURL] = defaultSelection(for: row)
        }
    }

    /// While a focal-length group is linked, every row in it shares one selection —
    /// changing any row's picker changes them all, rather than only copying once.
    private func binding(for row: ImportSession.EOSLensAmbiguousRow) -> Binding<String> {
        Binding(
            get: {
                if linkedByFocal[row.focalMillimeters] == true {
                    return linkedSelectionByFocal[row.focalMillimeters] ?? defaultSelection(for: row)
                }
                return selections[row.targetURL] ?? defaultSelection(for: row)
            },
            set: { newValue in
                if linkedByFocal[row.focalMillimeters] == true {
                    linkedSelectionByFocal[row.focalMillimeters] = newValue
                } else {
                    selections[row.targetURL] = newValue
                }
            }
        )
    }

    private func linkedBinding(for group: FocalGroup) -> Binding<Bool> {
        Binding(
            get: { linkedByFocal[group.focalMillimeters] ?? false },
            set: { newValue in
                linkedByFocal[group.focalMillimeters] = newValue
                if newValue, let first = group.rows.first {
                    linkedSelectionByFocal[group.focalMillimeters] = selections[first.targetURL] ?? defaultSelection(for: first)
                }
            }
        )
    }

    private func resolutions() -> [URL: String] {
        var result: [URL: String] = [:]
        for row in rows {
            let selected: String
            if linkedByFocal[row.focalMillimeters] == true {
                selected = linkedSelectionByFocal[row.focalMillimeters] ?? defaultSelection(for: row)
            } else {
                selected = selections[row.targetURL] ?? defaultSelection(for: row)
            }
            // Every row gets an explicit entry, even "Leave Blank" (as ""), so
            // applyEOSLensPolicy's detection pass knows this row is decided and
            // doesn't flag it as still-ambiguous on the next pass.
            result[row.targetURL] = selected == Self.leaveBlankID ? "" : selected
        }
        return result
    }
}

private struct LensChoiceRow: View {
    let fileName: String
    let focalMillimeters: Int
    let frameMaxAperture: Double?
    let candidates: [String]
    let rowWidth: CGFloat
    let columnSpacing: CGFloat
    let focalColumnWidth: CGFloat
    let apertureColumnWidth: CGFloat
    let pickerWidth: CGFloat
    @Binding var selectedOptionID: String

    private static let leaveBlankID = "leaveBlank"

    private var popupOptions: [InspectorPopupOption] {
        candidates.map { InspectorPopupOption(value: $0, label: $0) }
            + [InspectorPopupOption(value: Self.leaveBlankID, label: "Leave Blank")]
    }

    var body: some View {
        HStack(spacing: columnSpacing) {
            Text(fileName)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(focalMillimeters)mm")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: focalColumnWidth, alignment: .trailing)

            Text(apertureText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: apertureColumnWidth, alignment: .trailing)

            InspectorPopupField(selection: $selectedOptionID, options: popupOptions)
                .frame(width: pickerWidth)
        }
        .frame(width: rowWidth, alignment: .leading)
    }

    private var apertureText: String {
        guard let frameMaxAperture else { return "—" }
        return "f/\(formatted(frameMaxAperture))"
    }

    private func formatted(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
