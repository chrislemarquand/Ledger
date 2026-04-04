import ExifEditCore
import SharedUI
import SwiftUI

// MARK: - Sheet

struct BatchRenameSheetView: View {
    @ObservedObject var model: AppModel
    let scope: BatchRenameScope
    let capturedMetadata: [URL: FileMetadataSnapshot]

    private static let sectionSpacing = WorkflowSheetSectionSpacing.uniform(20)
    private static let formRowSpacing: CGFloat = 10
    private static let previewDebounceNanoseconds: UInt64 = 120_000_000

    // Column grid (content width = 540pt, +/- buttons = 80pt)
    fileprivate static let col1Width: CGFloat = 152   // type picker
    fileprivate static let col2Width: CGFloat = 142   // first content column
    fileprivate static let col3Width: CGFloat = 142   // second content column
    fileprivate static let colSpacing: CGFloat = 8
    fileprivate static let contentSpan: CGFloat = col2Width + colSpacing + col3Width  // 292

    @State private var tokens: [RenameToken] = [.text("")]
    @State private var showPreview = false
    @State private var preview: [RenamePlanEntry] = []
    @State private var previewIssues: [RenameValidationIssue] = []
    @State private var isLoadingPreview = false

    private var fileCount: Int {
        model.renameFilesForBatchRename(scope).count
    }

    private var pattern: RenamePattern {
        RenamePattern(tokens: tokens)
    }

    var body: some View {
        WorkflowSheetContainer(
            title: "Batch Rename",
            subtitle: scopeSummary,
            sectionSpacing: Self.sectionSpacing
        ) {
            VStack(alignment: .leading, spacing: 0) {
                // Token rows
                VStack(alignment: .leading, spacing: Self.formRowSpacing) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                        TokenRow(
                            token: token,
                            isOnlyRow: tokens.count == 1,
                            onUpdate: { tokens[index] = $0 },
                            onDelete: { tokens.remove(at: index) },
                            onInsertAfter: { tokens.insert(.text(""), at: index + 1) }
                        )
                    }
                }
                .padding(.bottom, Self.sectionSpacing.topToMain)

                // Inline preview — always same two-line structure to prevent height toggling
                inlinePreview
                    .padding(.bottom, Self.sectionSpacing.mainToFooter)

                // Footer
                HStack {
                    Button("Preview…") {
                        if preview.isEmpty && !isLoadingPreview {
                            Task { await refreshPreview() }
                        }
                        showPreview = true
                    }
                    .popover(isPresented: $showPreview) {
                        previewPopover
                    }

                    Spacer()

                    Button("Cancel") {
                        model.dismissBatchRenameSheet()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Rename") {
                        let files = model.renameFilesForBatchRename(scope)
                        let operation = RenameOperation(files: files, pattern: pattern)
                        Task { @MainActor in
                            await model.stageBatchRename(operation: operation)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(tokens.isEmpty || !previewIssues.isEmpty)
                }
            }
        }
        .task(id: pattern) {
            do { try await Task.sleep(nanoseconds: Self.previewDebounceNanoseconds) } catch { return }
            await refreshPreview()
        }
    }

    // MARK: - Inline preview

    private var inlinePreview: some View {
        let currentName: String
        let newName: String
        if let first = preview.first, previewIssues.isEmpty {
            currentName = first.sourceURL.lastPathComponent
            newName = first.finalTargetURL.lastPathComponent
        } else if let issue = previewIssues.first {
            currentName = issue.message
            newName = ""
        } else {
            currentName = "—"
            newName = "—"
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Current name: \(currentName)")
                .font(.callout)
                .foregroundStyle(previewIssues.isEmpty ? Color.secondary : Color.red)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("New name: \(newName)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Preview popover

    @ViewBuilder
    private var previewPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoadingPreview {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .padding()
            } else if !previewIssues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(previewIssues.prefix(4).enumerated()), id: \.offset) { _, issue in
                        Text(issue.message)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                .padding()
            } else if preview.isEmpty {
                Text("No files to rename.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(preview.enumerated()), id: \.offset) { _, entry in
                            HStack(spacing: 6) {
                                Text(entry.sourceURL.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(entry.finalTargetURL.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if hasConflict(entry) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.yellow)
                                        .help("Renamed to avoid a duplicate")
                                }
                            }
                            .font(.system(.caption, design: .monospaced))
                            .padding(.vertical, 2)
                        }
                    }
                    .padding()
                }
                .frame(width: 540, height: 320)
            }
        }
    }

    // MARK: - Helpers

    private var scopeSummary: String {
        let n = fileCount
        let noun = n == 1 ? "file" : "files"
        switch scope {
        case .selection: return "Renaming \(n) selected \(noun)"
        case .folder: return "Renaming \(n) \(noun) in folder"
        }
    }

    private func refreshPreview() async {
        isLoadingPreview = true
        let currentPattern = pattern
        let assessment = await model.previewBatchRenameAssessment(pattern: currentPattern, scope: scope, metadata: capturedMetadata)
        preview = assessment.entries
        previewIssues = assessment.issues
        isLoadingPreview = false
    }

    private func hasConflict(_ entry: RenamePlanEntry) -> Bool {
        let proposed = entry.extensionPreservingProposedName
        return entry.finalTargetURL.lastPathComponent != proposed
    }
}

// MARK: - Token Row

private enum TokenKind: String, CaseIterable, Identifiable, Equatable {
    case text
    case originalName
    case newExtension
    case sequenceNumber
    case sequenceLetter
    case dateTime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text:           return "Text"
        case .originalName:   return "Current Name"
        case .newExtension:   return "New Extension"
        case .sequenceNumber: return "Sequence Number"
        case .sequenceLetter: return "Sequence Letter"
        case .dateTime:       return "Date and Time"
        }
    }

    init(token: RenameToken) {
        switch token {
        case .text:           self = .text
        case .originalName:   self = .originalName
        case .extension:      self = .newExtension
        case .sequence:       self = .sequenceNumber
        case .sequenceLetter: self = .sequenceLetter
        case .date:           self = .dateTime
        }
    }

    var defaultToken: RenameToken {
        switch self {
        case .text:           return .text("")
        case .originalName:   return .originalName(component: .name, casing: .original)
        case .newExtension:   return .extension("")
        case .sequenceNumber: return .sequence(start: 1, padding: .three)
        case .sequenceLetter: return .sequenceLetter(uppercase: true)
        case .dateTime:       return .date(source: .dateTimeOriginal, format: .yyyymmdd)
        }
    }
}

private struct TokenRow: View {
    let token: RenameToken
    let isOnlyRow: Bool
    let onUpdate: (RenameToken) -> Void
    let onDelete: () -> Void
    let onInsertAfter: () -> Void

    // Layout constants (mirrors BatchRenameSheetView grid)
    private static let col1Width    = BatchRenameSheetView.col1Width
    private static let col2Width    = BatchRenameSheetView.col2Width
    private static let col3Width    = BatchRenameSheetView.col3Width
    private static let colSpacing   = BatchRenameSheetView.colSpacing
    private static let contentSpan  = BatchRenameSheetView.contentSpan

    // Static option arrays — built once, shared across all rows
    private static let tokenKindOptions    = TokenKind.allCases.map            { InspectorPopupOption(value: $0.rawValue,        label: $0.displayName) }
    private static let componentOptions    = OriginalNameComponent.allCases.map { InspectorPopupOption(value: $0.rawValue,        label: $0.displayName) }
    private static let casingOptions       = OriginalNameCasing.allCases.map    { InspectorPopupOption(value: $0.rawValue,        label: $0.displayName) }
    private static let dateSourceOptions   = DateSource.allCases.map            { InspectorPopupOption(value: $0.rawValue,        label: $0.displayName) }
    private static let dateFormatOptions   = DateFormat.allCases.map            { InspectorPopupOption(value: $0.rawValue,        label: $0.displayName) }
    private static let paddingOptions      = SequencePadding.allCases.map       { InspectorPopupOption(value: String($0.rawValue), label: $0.displayName) }
    private static let uppercaseOptions    = [
        InspectorPopupOption(value: "true",  label: "UPPERCASE"),
        InspectorPopupOption(value: "false", label: "lowercase"),
    ]

    private var kindStringBinding: Binding<String> {
        Binding(
            get: { TokenKind(token: token).rawValue },
            set: { newRawValue in
                guard let newKind = TokenKind(rawValue: newRawValue),
                      newKind != TokenKind(token: token) else { return }
                onUpdate(newKind.defaultToken)
            }
        )
    }

    var body: some View {
        HStack(spacing: Self.colSpacing) {
            // Col 1: type picker
            InspectorPopupField(selection: kindStringBinding, options: Self.tokenKindOptions)
                .frame(width: Self.col1Width)

            // Cols 2+3: token-specific content
            tokenContent

            // +/- buttons
            Button(action: onDelete) {
                Text("−").frame(width: 16, height: 16)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isOnlyRow)

            Button(action: onInsertAfter) {
                Text("+").frame(width: 16, height: 16)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(minHeight: 28)
    }

    @ViewBuilder
    private var tokenContent: some View {
        switch token {

        case .text(let value):
            TextField("Type text", text: Binding(
                get: { value },
                set: { onUpdate(.text($0)) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: Self.contentSpan)

        case .extension(let value):
            TextField("Type extension", text: Binding(
                get: { value },
                set: { onUpdate(.extension($0)) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: Self.contentSpan)

        case .sequence(let start, let padding):
            HStack(spacing: Self.colSpacing) {
                TextField("1", value: Binding(
                    get: { start },
                    set: { onUpdate(.sequence(start: $0, padding: padding)) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: Self.col2Width)

                InspectorPopupField(
                    selection: Binding(
                        get: { String(padding.rawValue) },
                        set: { str in
                            guard let raw = Int(str), let p = SequencePadding(rawValue: raw) else { return }
                            onUpdate(.sequence(start: start, padding: p))
                        }
                    ),
                    options: Self.paddingOptions
                )
                .frame(width: Self.col3Width)
            }

        case .sequenceLetter(let uppercase):
            InspectorPopupField(
                selection: Binding(
                    get: { uppercase ? "true" : "false" },
                    set: { onUpdate(.sequenceLetter(uppercase: $0 == "true")) }
                ),
                options: Self.uppercaseOptions
            )
            .frame(width: Self.contentSpan)

        case .date(let source, let format):
            HStack(spacing: Self.colSpacing) {
                InspectorPopupField(
                    selection: Binding(
                        get: { source.rawValue },
                        set: { onUpdate(.date(source: DateSource(rawValue: $0) ?? source, format: format)) }
                    ),
                    options: Self.dateSourceOptions
                )
                .frame(width: Self.col2Width)

                InspectorPopupField(
                    selection: Binding(
                        get: { format.rawValue },
                        set: { onUpdate(.date(source: source, format: DateFormat(rawValue: $0) ?? format)) }
                    ),
                    options: Self.dateFormatOptions
                )
                .frame(width: Self.col3Width)
            }

        case .originalName(let component, let casing):
            HStack(spacing: Self.colSpacing) {
                InspectorPopupField(
                    selection: Binding(
                        get: { component.rawValue },
                        set: { onUpdate(.originalName(component: OriginalNameComponent(rawValue: $0) ?? component, casing: casing)) }
                    ),
                    options: Self.componentOptions
                )
                .frame(width: Self.col2Width)

                InspectorPopupField(
                    selection: Binding(
                        get: { casing.rawValue },
                        set: { onUpdate(.originalName(component: component, casing: OriginalNameCasing(rawValue: $0) ?? casing)) }
                    ),
                    options: Self.casingOptions
                )
                .frame(width: Self.col3Width)
            }
        }
    }
}

// MARK: - View modifier

extension View {
    func batchRenameSheet(model: AppModel) -> some View {
        self.sheet(item: Binding(
            get: { model.pendingBatchRenameScope },
            set: { newValue in
                Task { @MainActor in
                    model.pendingBatchRenameScope = newValue
                }
            }
        )) { scope in
            BatchRenameSheetView(model: model, scope: scope, capturedMetadata: model.pendingBatchRenameMetadata)
        }
    }
}

// MARK: - RenamePlanEntry helper

private extension RenamePlanEntry {
    var extensionPreservingProposedName: String {
        let ext = sourceURL.pathExtension
        return ext.isEmpty ? proposedBasename : "\(proposedBasename).\(ext)"
    }
}
