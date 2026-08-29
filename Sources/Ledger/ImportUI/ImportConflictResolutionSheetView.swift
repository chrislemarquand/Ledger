import SharedUI
import SwiftUI

/// Presented as a second sheet on top of `ImportSheetView` when an import run
/// has unresolved `ImportConflict`s. Lets the user resolve or skip each row in
/// one screen, instead of the batch being blocked outright.
struct ImportConflictResolutionSheetView: View {
    let conflicts: [ImportConflict]
    let onCancel: () -> Void
    let onResolve: ([UUID: ImportConflictResolutionChoice]) -> Void

    @State private var selections: [UUID: String] = [:]

    private static let skipOptionID = "skip"
    private static let sectionSpacing = WorkflowSheetSectionSpacing.uniform(16)

    var body: some View {
        WorkflowSheetContainer(
            title: "Resolve Import Conflicts",
            subtitle: subtitle,
            width: 620,
            sectionSpacing: Self.sectionSpacing
        ) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip All Remaining") {
                        skipAllRemaining()
                    }
                    .controlSize(.small)
                }
                .padding(.bottom, Self.sectionSpacing.topToMain)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(conflicts) { conflict in
                            ConflictRow(
                                title: rowTitle(for: conflict),
                                detail: conflict.message,
                                candidates: candidateOptions(for: conflict),
                                selectedOptionID: binding(for: conflict),
                                diffText: diffText(for: conflict)
                            )
                            if conflict.id != conflicts.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(width: 580, height: min(CGFloat(conflicts.count) * 52 + 16, 360))
                .padding(.bottom, Self.sectionSpacing.mainToFooter)

                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Resolve & Continue") {
                        onResolve(resolutions())
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear(perform: seedSelectionsIfNeeded)
    }

    private var subtitle: String {
        let n = conflicts.count
        return n == 1 ? "1 row needs attention." : "\(n) rows need attention."
    }

    private func rowTitle(for conflict: ImportConflict) -> String {
        "\(conflict.sourceIdentifier) (line \(conflict.sourceLine))"
    }

    private func candidateOptions(for conflict: ImportConflict) -> [ConflictOption] {
        conflict.candidateTargets.map { target in
            ConflictOption(id: target.path, label: target.lastPathComponent)
        }
    }

    private func diffText(for conflict: ImportConflict) -> String {
        guard !conflict.rowFields.isEmpty else {
            return "No field values in this row."
        }
        return conflict.rowFields
            .map { "\($0.tagID): \($0.value)" }
            .joined(separator: "\n")
    }

    private func binding(for conflict: ImportConflict) -> Binding<String> {
        Binding(
            get: { selections[conflict.id] ?? defaultSelection(for: conflict) },
            set: { selections[conflict.id] = $0 }
        )
    }

    private func defaultSelection(for conflict: ImportConflict) -> String {
        conflict.candidateTargets.first?.path ?? Self.skipOptionID
    }

    private func seedSelectionsIfNeeded() {
        for conflict in conflicts where selections[conflict.id] == nil {
            selections[conflict.id] = defaultSelection(for: conflict)
        }
    }

    private func skipAllRemaining() {
        for conflict in conflicts {
            selections[conflict.id] = Self.skipOptionID
        }
    }

    private func resolutions() -> [UUID: ImportConflictResolutionChoice] {
        var result: [UUID: ImportConflictResolutionChoice] = [:]
        for conflict in conflicts {
            let selected = selections[conflict.id] ?? defaultSelection(for: conflict)
            if selected == Self.skipOptionID {
                result[conflict.id] = .skip
            } else {
                result[conflict.id] = .target(URL(fileURLWithPath: selected))
            }
        }
        return result
    }
}

private struct ConflictOption: Identifiable, Hashable {
    let id: String
    let label: String
}

private struct ConflictRow: View {
    let title: String
    let detail: String
    let candidates: [ConflictOption]
    @Binding var selectedOptionID: String
    let diffText: String

    @State private var showDetails = false

    private static let skipOptionID = "skip"

    var body: some View {
        WorkflowFormRow(labelWidth: 260, labelAlignment: .leading) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } content: {
            HStack(spacing: 6) {
                resolutionControl
                Button {
                    showDetails = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .popover(isPresented: $showDetails) {
                    WorkflowDetailsPopover(text: diffText, width: 360, height: 180)
                }
            }
        }
    }

    @ViewBuilder
    private var resolutionControl: some View {
        switch candidates.count {
        case 0:
            // Nothing to choose between — a dropdown with one disabled item
            // reads as broken UI, so just state the outcome.
            Text("Skip — no matching file")
                .font(.callout)
                .foregroundStyle(.secondary)

        case 1:
            let candidate = candidates[0]
            Toggle("Use “\(candidate.label)”", isOn: Binding(
                get: { selectedOptionID == candidate.id },
                set: { selectedOptionID = $0 ? candidate.id : Self.skipOptionID }
            ))
            .toggleStyle(.checkbox)

        default:
            Picker("", selection: $selectedOptionID) {
                ForEach(candidates) { candidate in
                    Text(candidate.label).tag(candidate.id)
                }
                Text("Skip").tag(Self.skipOptionID)
            }
            .labelsHidden()
            .frame(maxWidth: 240)
        }
    }
}

// MARK: - Preview

// No real import adapter can currently produce `.multipleTargets` (would need
// two files sharing a filename in one folder — impossible on a case-insensitive
// filesystem) or a `.duplicateSourceIdentifier` with a real candidate to resolve
// against (CSVImportAdapter falls back to row-order matching before the matcher
// ever sees the collision). This preview fabricates all three conflict kinds
// directly so the non-Skip resolution controls (checkbox, dropdown) can still be
// visually verified without a real end-to-end scenario.
#Preview("Mixed conflict kinds") {
    ImportConflictResolutionSheetView(
        conflicts: [
            ImportConflict(
                id: UUID(),
                kind: .missingTarget,
                sourceLine: 6,
                sourceIdentifier: "IMG_0037.tif",
                rowFields: [ImportFieldValue(tagID: "xmp-rating", value: "5")],
                candidateTargets: [],
                message: "No target file named “IMG_0037.tif” in scope."
            ),
            ImportConflict(
                id: UUID(),
                kind: .duplicateSourceIdentifier,
                sourceLine: 9,
                sourceIdentifier: "IMG_0004.tif",
                rowFields: [
                    ImportFieldValue(tagID: "xmp-headline", value: "Second pass"),
                    ImportFieldValue(tagID: "xmp-rating", value: "3"),
                ],
                candidateTargets: [URL(fileURLWithPath: "/Users/chris/Photos/IMG_0004.tif")],
                message: "Multiple source rows target “IMG_0004.tif”."
            ),
            ImportConflict(
                id: UUID(),
                kind: .multipleTargets,
                sourceLine: 14,
                sourceIdentifier: "IMG_0042",
                rowFields: [ImportFieldValue(tagID: "xmp-headline", value: "Beach walk")],
                candidateTargets: [
                    URL(fileURLWithPath: "/Users/chris/Photos/IMG_0042.CR2"),
                    URL(fileURLWithPath: "/Users/chris/Photos/IMG_0042.jpg"),
                ],
                message: "Multiple target files match “IMG_0042”."
            ),
        ],
        onCancel: {},
        onResolve: { _ in }
    )
}
