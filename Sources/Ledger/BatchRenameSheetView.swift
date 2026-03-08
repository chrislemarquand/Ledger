import ExifEditCore
import SwiftUI

// MARK: - Sheet

struct BatchRenameSheetView: View {
    @ObservedObject var model: AppModel
    let scope: BatchRenameScope

    @State private var tokens: [RenameToken] = [.originalName]
    @State private var extensionOverrideEnabled = false
    @State private var extensionOverrideText = ""
    @State private var preview: [RenamePlanEntry] = []
    @State private var isLoadingPreview = false
    @State private var showConfirmation = false

    private var fileCount: Int {
        switch scope {
        case .selection: return model.selectedFileURLs.count
        case .folder: return model.browserItems.count
        }
    }

    private var pattern: RenamePattern {
        RenamePattern(
            tokens: tokens,
            extensionOverride: extensionOverrideEnabled && !extensionOverrideText.isEmpty
                ? extensionOverrideText : nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Batch Rename")
                        .font(.headline)
                    Text(scopeSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Token builder
                    tokenBuilderSection

                    // Extension override
                    extensionSection

                    // Live preview
                    previewSection
                }
                .padding()
            }

            Divider()

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    model.dismissBatchRenameSheet()
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename…") {
                    showConfirmation = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tokens.isEmpty || isLoadingPreview)
            }
            .padding()
        }
        .frame(width: 560, height: 520)
        .task(id: pattern) {
            await refreshPreview()
        }
        .confirmationDialog(confirmationTitle, isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Rename Files", role: .destructive) {
                let files: [URL]
                switch scope {
                case .selection:
                    files = model.filteredBrowserItems
                        .map(\.url)
                        .filter { model.selectedFileURLs.contains($0) }
                case .folder:
                    files = model.filteredBrowserItems.map(\.url)
                }
                let operation = RenameOperation(files: files, pattern: pattern)
                Task { @MainActor in
                    await model.applyBatchRename(operation: operation)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files on disk will be renamed. You can restore original names from Backup via Image > Restore from Backup.")
        }
    }

    // MARK: - Sections

    private var scopeSummary: String {
        let n = fileCount
        let noun = n == 1 ? "file" : "files"
        switch scope {
        case .selection: return "Renaming \(n) selected \(noun)"
        case .folder: return "Renaming \(n) \(noun) in folder"
        }
    }

    private var confirmationTitle: String {
        "Rename \(fileCount) \(fileCount == 1 ? "File" : "Files")?"
    }

    @ViewBuilder
    private var tokenBuilderSection: some View {
        GroupBox("Rename Pattern") {
            VStack(alignment: .leading, spacing: 8) {
                if tokens.isEmpty {
                    Text("Add at least one token.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                    TokenRow(
                        token: token,
                        onUpdate: { updated in
                            tokens[index] = updated
                        },
                        onDelete: {
                            tokens.remove(at: index)
                        }
                    )
                }

                Menu("Add Token") {
                    Button("Original Name") { tokens.append(.originalName) }
                    Button("Custom Text…") { tokens.append(.text("")) }
                    Button("Sequence Number") { tokens.append(.sequence(start: 1, step: 1, padding: 3)) }
                    Button("Date (yyyyMMdd)") { tokens.append(.date(format: "yyyyMMdd")) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var extensionSection: some View {
        GroupBox("Extension") {
            HStack(spacing: 10) {
                Toggle("Override extension", isOn: $extensionOverrideEnabled)
                if extensionOverrideEnabled {
                    TextField("e.g. jpg", text: $extensionOverrideText)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }
                Spacer()
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        GroupBox("Preview (up to 20 files)") {
            if isLoadingPreview {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if preview.isEmpty {
                Text("No files match the current scope.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(preview.prefix(20).enumerated()), id: \.offset) { _, entry in
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
                .padding(6)
            }
        }
    }

    // MARK: - Helpers

    private func refreshPreview() async {
        isLoadingPreview = true
        let currentPattern = pattern
        let entries = await model.previewBatchRename(pattern: currentPattern, scope: scope)
        preview = entries
        isLoadingPreview = false
    }

    private func hasConflict(_ entry: RenamePlanEntry) -> Bool {
        let proposed = entry.extensionPreservingProposedName
        return entry.finalTargetURL.lastPathComponent != proposed
    }
}

// MARK: - Token Row

private struct TokenRow: View {
    let token: RenameToken
    let onUpdate: (RenameToken) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            tokenEditor
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(4)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var tokenEditor: some View {
        switch token {
        case .originalName:
            Label("Original Name", systemImage: "doc.text")
                .font(.caption)
        case .text(let value):
            HStack {
                Image(systemName: "character.cursor.ibeam")
                TextField("Custom text", text: Binding(
                    get: { value },
                    set: { onUpdate(.text($0)) }
                ))
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(minWidth: 80)
            }
        case .sequence(let start, let step, let padding):
            HStack(spacing: 6) {
                Image(systemName: "number")
                Text("Start:").font(.caption)
                TextField("", value: Binding(
                    get: { start },
                    set: { onUpdate(.sequence(start: $0, step: step, padding: padding)) }
                ), format: .number)
                .textFieldStyle(.plain)
                .frame(width: 36)
                .font(.caption)
                Text("Step:").font(.caption)
                TextField("", value: Binding(
                    get: { step },
                    set: { onUpdate(.sequence(start: start, step: $0, padding: padding)) }
                ), format: .number)
                .textFieldStyle(.plain)
                .frame(width: 30)
                .font(.caption)
                Text("Pad:").font(.caption)
                TextField("", value: Binding(
                    get: { padding },
                    set: { onUpdate(.sequence(start: start, step: step, padding: $0)) }
                ), format: .number)
                .textFieldStyle(.plain)
                .frame(width: 30)
                .font(.caption)
            }
        case .date(let format):
            HStack {
                Image(systemName: "calendar")
                TextField("Date format", text: Binding(
                    get: { format },
                    set: { onUpdate(.date(format: $0)) }
                ))
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(minWidth: 80)
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
