import ExifEditCore
import SharedUI
import SwiftUI

// MARK: - Sheet

struct BatchRenameSheetView: View {
    @ObservedObject var model: AppModel
    let scope: BatchRenameScope

    private static let sectionSpacing = WorkflowSheetSectionSpacing.uniform(20)
    private static let previewDebounceNanoseconds: UInt64 = 120_000_000

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
                VStack(spacing: 0) {
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
            Text("Current filename: \(currentName)")
                .font(.callout)
                .foregroundStyle(previewIssues.isEmpty ? Color.secondary : Color.red)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("New filename: \(newName)")
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
                Text("No files match the current scope.")
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
                                        .help("Disambiguated to avoid collision")
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
        let assessment = await model.previewBatchRenameAssessment(pattern: currentPattern, scope: scope)
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

private enum TokenKind: CaseIterable, Identifiable, Equatable {
    case text, originalName, newExtension, sequenceNumber, sequenceLetter, dateTime

    var id: Self { self }

    var displayName: String {
        switch self {
        case .text:           return "Text"
        case .originalName:   return "Current Filename"
        case .newExtension:   return "New extension"
        case .sequenceNumber: return "Sequence number"
        case .sequenceLetter: return "Sequence letter"
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

    private var kindBinding: Binding<TokenKind> {
        Binding(
            get: { TokenKind(token: token) },
            set: { newKind in
                if TokenKind(token: token) != newKind {
                    onUpdate(newKind.defaultToken)
                }
            }
        )
    }

    var body: some View {
        WorkflowFormRow(
            labelWidth: 152,
            labelAlignment: .leading,
            rowMinHeight: 28
        ) {
            Picker("", selection: kindBinding) {
                ForEach(TokenKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        } content: {
            HStack(spacing: 8) {
                tokenContent

                Button(action: onDelete) {
                    Text("−")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isOnlyRow)

                Button(action: onInsertAfter) {
                    Text("+")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 5)
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

        case .extension(let value):
            TextField("Type extension", text: Binding(
                get: { value },
                set: { onUpdate(.extension($0)) }
            ))
            .textFieldStyle(.roundedBorder)

        case .sequence(let start, let padding):
            HStack(spacing: 8) {
                TextField("1", value: Binding(
                    get: { start },
                    set: { onUpdate(.sequence(start: $0, padding: padding)) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

                Picker("", selection: Binding(
                    get: { padding },
                    set: { onUpdate(.sequence(start: start, padding: $0)) }
                )) {
                    ForEach(SequencePadding.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

        case .sequenceLetter(let uppercase):
            HStack(spacing: 0) {
                Picker("", selection: Binding(
                    get: { uppercase },
                    set: { onUpdate(.sequenceLetter(uppercase: $0)) }
                )) {
                    Text("UPPERCASE").tag(true)
                    Text("lowercase").tag(false)
                }
                .labelsHidden()
                .frame(width: 240, alignment: .leading)
                Spacer(minLength: 0)
            }

        case .date(let source, let format):
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { source },
                    set: { onUpdate(.date(source: $0, format: format)) }
                )) {
                    ForEach(DateSource.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Picker("", selection: Binding(
                    get: { format },
                    set: { onUpdate(.date(source: source, format: $0)) }
                )) {
                    ForEach(DateFormat.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

        case .originalName(let component, let casing):
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { component },
                    set: { onUpdate(.originalName(component: $0, casing: casing)) }
                )) {
                    ForEach(OriginalNameComponent.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Picker("", selection: Binding(
                    get: { casing },
                    set: { onUpdate(.originalName(component: component, casing: $0)) }
                )) {
                    ForEach(OriginalNameCasing.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
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
            BatchRenameSheetView(model: model, scope: scope)
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
