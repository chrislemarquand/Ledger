import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Import Session

@MainActor
final class ImportSession: ObservableObject {
    private let coordinator = ImportCoordinator()
    @Published var options: ImportRunOptions
    @Published var preparedRun: ImportPreparedRun?
    @Published var isBusy = false
    @Published var previewError: String?
    private var previewTask: Task<Void, Never>?

    init(model: AppModel, sourceKind: ImportSourceKind) {
        var opts = coordinator.loadPersistedOptions(for: sourceKind)
        opts.sourceKind = sourceKind
        let selectedCount = model.selectedFileURLs.count
        opts.scope = selectedCount >= 2 ? .selection : .folder
        opts.emptyValuePolicy = .clear
        if opts.matchStrategy == .rowParity {
            opts.rowParityStartRow = max(1, opts.rowParityStartRow)
            // When defaulting to Folder scope, always parse all rows (count = 0 = unlimited).
            // When defaulting to Selection scope (2+ files selected), cap to the selection size.
            opts.rowParityRowCount = selectedCount >= 2 ? selectedCount : 0
        }
        // Always start fresh — don't restore the last-used source or field selection
        opts.sourceURLPath = nil
        opts.auxiliaryURLPaths = []
        opts.selectedTagIDs = []
        options = opts
    }

    func schedulePreviewRefresh(model: AppModel) {
        previewTask?.cancel()
        guard options.sourceURL != nil else {
            preparedRun = nil
            previewError = nil
            return
        }
        isBusy = true
        preparedRun = nil
        previewError = nil
        let opts = options
        let targetFiles = model.importTargetFiles(for: opts.scope)
        previewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let prepared = try await coordinator.prepareRun(
                    options: opts,
                    targetFiles: targetFiles,
                    tagCatalog: model.importTagCatalog,
                    metadataProvider: { files in
                        await model.importMetadataSnapshots(for: files)
                    }
                )
                guard !Task.isCancelled else { return }
                preparedRun = prepared
                previewError = nil
            } catch {
                guard !Task.isCancelled else { return }
                preparedRun = nil
                previewError = "⚠ \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    /// Returns true on success.
    func performImport(model: AppModel) async -> Bool {
        let run: ImportPreparedRun
        if let existing = preparedRun {
            run = existing
        } else {
            isBusy = true
            let opts = options
            let targetFiles = model.importTargetFiles(for: opts.scope)
            do {
                run = try await coordinator.prepareRun(
                    options: opts,
                    targetFiles: targetFiles,
                    tagCatalog: model.importTagCatalog,
                    metadataProvider: { files in
                        await model.importMetadataSnapshots(for: files)
                    }
                )
                preparedRun = run
                isBusy = false
            } catch {
                isBusy = false
                previewError = "⚠ \(error.localizedDescription)"
                return false
            }
        }

        let resolve = coordinator.resolveAssignments(preparedRun: run, resolutions: [:])
        if !resolve.unresolvedConflicts.isEmpty {
            previewError = "⚠ \(resolve.unresolvedConflicts.count) conflict(s) need resolution. Conflict resolution will be available in a future update."
            return false
        }

        let stageSummary = model.stageImportAssignments(
            filterAssignments(resolve.assignments, selectedTagIDs: run.options.selectedTagIDs),
            sourceKind: run.options.sourceKind,
            emptyValuePolicy: run.options.emptyValuePolicy
        )
        model.statusMessage = "Staged \(stageSummary.stagedFields) field(s) on \(stageSummary.stagedFiles) file(s)."
        return true
    }

    /// Tag IDs that actually appear in the parsed data. Nil until a run is prepared.
    var foundTagIDs: Set<String>? {
        guard let run = preparedRun else { return nil }
        var ids = Set<String>()
        for match in run.matchResult.matched {
            for field in match.row.fields { ids.insert(field.tagID) }
        }
        for conflict in run.matchResult.conflicts {
            for field in conflict.rowFields { ids.insert(field.tagID) }
        }
        return ids
    }

    private func filterAssignments(_ assignments: [ImportAssignment], selectedTagIDs: [String]) -> [ImportAssignment] {
        guard !selectedTagIDs.isEmpty else { return assignments }
        let selected = Set(selectedTagIDs)
        return assignments.map { ImportAssignment(targetURL: $0.targetURL, fields: $0.fields.filter { selected.contains($0.tagID) }) }
    }

    private func effectiveFieldCount(for fields: [ImportFieldValue]) -> Int {
        let ids = options.selectedTagIDs
        guard !ids.isEmpty else { return fields.count }
        let selected = Set(ids)
        return fields.filter { selected.contains($0.tagID) }.count
    }

    var previewText: String {
        if let error = previewError { return error }
        guard let run = preparedRun else { return "" }
        var lines: [String] = []
        for match in run.matchResult.matched.prefix(200) {
            lines.append("\(match.row.sourceIdentifier) → \(match.targetURL.lastPathComponent) (\(effectiveFieldCount(for: match.row.fields)) fields)")
        }
        if run.matchResult.matched.count > 200 {
            lines.append("… \(run.matchResult.matched.count - 200) more rows")
        }
        if !run.matchResult.conflicts.isEmpty {
            lines.append("")
            lines.append("⚠ \(run.matchResult.conflicts.count) conflict(s) need resolution")
        }
        if lines.isEmpty {
            lines.append("No matches found.")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Import Sheet View

struct ImportSheetView: View {
    @ObservedObject var model: AppModel
    let sourceKind: ImportSourceKind
    @StateObject private var session: ImportSession
    @State private var showFields = false
    @State private var showAdvanced = false
    @State private var showPreview = false
    @State private var showInfo = false
    @State private var importProgress: Double?

    init(model: AppModel, sourceKind: ImportSourceKind) {
        self.model = model
        self.sourceKind = sourceKind
        _session = StateObject(wrappedValue: ImportSession(model: model, sourceKind: sourceKind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title with inline ⓘ
            HStack(spacing: 6) {
                Text("Import from \(sourceKind.title)")
                    .font(.title3.weight(.semibold))
                Button {
                    showInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showInfo) {
                    Text(infoText)
                        .padding()
                        .frame(maxWidth: 280)
                }
            }

            // File picker row
            HStack {
                TextField("", text: .constant(session.options.sourceURLPath ?? ""))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                Button("Choose…") {
                    chooseSource()
                }
            }

            // Options row: Apply to | If no match | Match by (CSV only)
            HStack(alignment: .top, spacing: 28) {
                optionGroup("Apply to:") {
                    Picker("", selection: $session.options.scope) {
                        Text("Folder").tag(ImportScope.folder)
                        Text(selectionLabel).tag(ImportScope.selection)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                optionGroup("If no match:") {
                    Picker("", selection: $session.options.emptyValuePolicy) {
                        Text("Clear").tag(ImportEmptyValuePolicy.clear)
                        Text("Skip").tag(ImportEmptyValuePolicy.skip)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                if sourceKind == .csv {
                    optionGroup("Match by:") {
                        Picker("", selection: $session.options.matchStrategy) {
                            Text("Filename").tag(ImportMatchStrategy.filename)
                            Text("Row order").tag(ImportMatchStrategy.rowParity)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }
                }
            }

            ProgressView(value: importProgress ?? 0)
                .opacity(importProgress == nil ? 0 : 1)

            // Footer: Fields… | [Advanced…] | [Preview…]   Cancel  Import
            HStack {
                Button("Fields…") {
                    showFields = true
                }
                .disabled(session.foundTagIDs == nil)
                .popover(isPresented: $showFields) {
                    fieldsPopover
                }
                if hasAdvancedOptions {
                    Button("Advanced…") {
                        showAdvanced = true
                    }
                    .popover(isPresented: $showAdvanced) {
                        advancedPopover
                    }
                }
                if hasPreview {
                    Button("Preview…") {
                        showPreview = true
                    }
                    .disabled(session.options.sourceURL == nil)
                    .popover(isPresented: $showPreview) {
                        previewPopover
                    }
                }
                Spacer()
                Button("Cancel") {
                    model.dismissImportSheet()
                }
                .keyboardShortcut(.cancelAction)
                Button("Import") {
                    performImport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.options.sourceURL == nil || session.isBusy || importProgress != nil)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 560)
        .onChange(of: session.options.sourceURLPath) { _, _ in
            session.schedulePreviewRefresh(model: model)
        }
        .onChange(of: session.options.scope) { _, _ in
            session.schedulePreviewRefresh(model: model)
        }
        .onChange(of: session.options.matchStrategy) { _, _ in
            session.schedulePreviewRefresh(model: model)
        }
    }

    // MARK: - Computed

    private var isRowParityActive: Bool {
        sourceKind == .eos1v || session.options.matchStrategy == .rowParity
    }

    private var hasAdvancedOptions: Bool {
        sourceKind == .csv || sourceKind == .gpx
    }

    private var hasPreview: Bool {
        sourceKind != .referenceImage
    }

    private var selectionLabel: String {
        let count = model.selectedFileURLs.count
        return count > 0 ? "Selection (\(count))" : "Selection"
    }

    private var infoText: String {
        switch sourceKind {
        case .csv: return "Expects an ExifTool-format CSV with a SourceFile column."
        case .eos1v: return "Expects an EOS 1V CSV export file."
        case .gpx: return "One or more GPX track files. Photos are matched by timestamp."
        case .referenceFolder: return "A folder of reference images. Metadata is read from embedded EXIF or sidecar."
        case .referenceImage: return "A single reference image to copy metadata from."
        }
    }

    // MARK: - View Helpers

    @ViewBuilder
    private func optionGroup(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private var fieldsPopover: some View {
        let tags = model.importTagCatalog
        let foundIDs = session.foundTagIDs ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Fields")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tags, id: \.id) { tag in
                        let isFound = foundIDs.contains(tag.id)
                        Toggle(tag.label, isOn: Binding(
                            get: {
                                guard isFound else { return false }
                                let ids = session.options.selectedTagIDs
                                // Empty = all found fields selected
                                return ids.isEmpty ? true : ids.contains(tag.id)
                            },
                            set: { isOn in
                                // Initialise from found IDs if nothing explicitly chosen yet
                                var ids = Set(session.options.selectedTagIDs.isEmpty
                                    ? foundIDs
                                    : Set(session.options.selectedTagIDs))
                                if isOn { ids.insert(tag.id) } else { ids.remove(tag.id) }
                                session.options.selectedTagIDs = Array(ids)
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .disabled(!isFound)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 300)
            HStack {
                Spacer()
                Button("Apply") {
                    showFields = false
                    session.schedulePreviewRefresh(model: model)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 240)
    }

    @ViewBuilder
    private var previewPopover: some View {
        ScrollView {
            HStack(alignment: .top) {
                if session.isBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reading file…")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                } else {
                    Text(session.previewText.isEmpty ? "No matches found." : session.previewText)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: 560, height: 300)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.quaternary.opacity(0.35)))
    }

    @ViewBuilder
    private var advancedPopover: some View {
        switch sourceKind {
        case .csv:
            csvAdvancedView
        case .gpx:
            gpxAdvancedView
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var csvAdvancedView: some View {
        let rowCount = session.preparedRun?.parseResult.rows.count ?? 1
        let selectedCount = model.selectedFileURLs.count
        VStack(alignment: .leading, spacing: 12) {
            Text("Row Matching")
                .font(.headline)
            HStack {
                Text("Start row:")
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: $session.options.rowParityStartRow) {
                    ForEach(1 ... max(1, rowCount), id: \.self) { row in
                        Text("\(row)").tag(row)
                    }
                }
                .labelsHidden()
                .disabled(!isRowParityActive)
            }
            HStack {
                Text("End row:")
                    .frame(width: 90, alignment: .leading)
                Text(isRowParityActive
                    ? "\(session.options.rowParityStartRow + max(0, selectedCount - 1))"
                    : "—")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") {
                    showAdvanced = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 220)
    }

    @ViewBuilder
    private var gpxAdvancedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GPX Options")
                .font(.headline)
            HStack {
                Text("Tolerance (sec):")
                    .frame(width: 130, alignment: .leading)
                TextField("", value: $session.options.gpxToleranceSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }
            HStack {
                Text("Camera offset (sec):")
                    .frame(width: 130, alignment: .leading)
                TextField("", value: $session.options.gpxCameraOffsetSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }
            HStack {
                Spacer()
                Button("Done") {
                    showAdvanced = false
                    session.schedulePreviewRefresh(model: model)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 280)
    }

    // MARK: - Actions

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = false
        switch sourceKind {
        case .csv, .eos1v:
            if let csvType = UTType(filenameExtension: "csv") {
                panel.allowedContentTypes = [.commaSeparatedText, csvType]
            } else {
                panel.allowedContentTypes = [.commaSeparatedText]
            }
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.title = "Choose CSV"
        case .gpx:
            if let gpxType = UTType(filenameExtension: "gpx") {
                panel.allowedContentTypes = [gpxType]
            }
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.title = "Choose GPX Files"
        case .referenceFolder:
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = "Choose Reference Folder"
        case .referenceImage:
            panel.allowedContentTypes = ReferenceImportSupport.supportedImageExtensions
                .compactMap { UTType(filenameExtension: $0) }
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.title = "Choose Reference Image"
        }
        guard panel.runModal() == .OK else { return }
        if sourceKind == .gpx {
            session.options.sourceURLPath = panel.urls.first?.path
            session.options.auxiliaryURLPaths = panel.urls.dropFirst().map(\.path)
        } else {
            session.options.sourceURLPath = panel.url?.path
            session.options.auxiliaryURLPaths = []
        }
        session.schedulePreviewRefresh(model: model)
    }

    private func performImport() {
        importProgress = 0.0
        Task {
            let success = await session.performImport(model: model)
            if success {
                withAnimation(.easeInOut(duration: 0.35)) {
                    importProgress = 1.0
                }
                try? await Task.sleep(for: .milliseconds(500))
                model.dismissImportSheet()
            } else {
                importProgress = nil
            }
        }
    }
}
