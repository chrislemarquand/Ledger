import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Import Session

@MainActor
final class ImportSession: ObservableObject {
    struct EOSLensChoiceRequest {
        let sourceLine: Int
        let sourceIdentifier: String
        let focalMillimeters: Int
        let candidates: [String]
    }

    private let coordinator = ImportCoordinator()
    private let eosLensMappingURL: URL
    private let lensChoiceProvider: ((EOSLensChoiceRequest) -> String?)?
    private var eosLensMappingCache: [Int: [String]]?
    @Published var options: ImportRunOptions
    @Published var preparedRun: ImportPreparedRun?
    @Published var isBusy = false
    @Published var previewError: String?
    private var previewTask: Task<Void, Never>?

    init(
        model: AppModel,
        sourceKind: ImportSourceKind,
        eosLensMappingURL: URL? = nil,
        lensChoiceProvider: ((EOSLensChoiceRequest) -> String?)? = nil
    ) {
        var opts = coordinator.loadPersistedOptions(for: sourceKind)
        self.eosLensMappingURL = eosLensMappingURL
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/lensfocalength.csv")
        self.lensChoiceProvider = lensChoiceProvider
        opts.sourceKind = sourceKind
        if sourceKind == .csv {
            // CSV matching is now automatic (filename when uniquely safe, else row-order fallback).
            // Preserve row-parity window controls as the fallback policy seam.
            opts.matchStrategy = .rowParity
        }
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

        let eosLensResult = applyEOSLensPolicy(assignments: resolve.assignments, run: run)
        if eosLensResult.cancelled {
            previewError = "⚠ Import cancelled while choosing EOS lens values."
            return false
        }

        let policyAppliedAssignments = applyMissingFieldPolicy(
            assignments: eosLensResult.assignments,
            run: run,
            model: model
        )
        let stageSummary = model.stageImportAssignments(
            filterAssignments(policyAppliedAssignments, selectedTagIDs: run.options.selectedTagIDs),
            sourceKind: run.options.sourceKind,
            emptyValuePolicy: run.options.emptyValuePolicy
        )
        if resolve.warnings.isEmpty {
            model.statusMessage = "Staged \(stageSummary.stagedFields) field(s) on \(stageSummary.stagedFiles) file(s)."
        } else {
            model.statusMessage = "Staged \(stageSummary.stagedFields) field(s) on \(stageSummary.stagedFiles) file(s) with \(resolve.warnings.count) merge warning(s)."
        }
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

    private func applyEOSLensPolicy(
        assignments: [ImportAssignment],
        run: ImportPreparedRun
    ) -> (assignments: [ImportAssignment], cancelled: Bool) {
        guard run.options.sourceKind == .eos1v else {
            return (assignments, false)
        }
        if !run.options.selectedTagIDs.isEmpty, !run.options.selectedTagIDs.contains("exif-lens") {
            return (assignments, false)
        }
        let mapping = loadEOSLensMapping()
        guard !mapping.isEmpty else {
            return (assignments, false)
        }

        let rowByTargetURL = Dictionary(uniqueKeysWithValues: run.matchResult.matched.map { ($0.targetURL, $0.row) })
        var updatedAssignments = assignments

        for index in updatedAssignments.indices {
            let assignment = updatedAssignments[index]
            guard let row = rowByTargetURL[assignment.targetURL] else { continue }

            var valueByTagID: [String: String] = [:]
            var orderedTagIDs: [String] = []
            for field in assignment.fields {
                if valueByTagID[field.tagID] == nil {
                    orderedTagIDs.append(field.tagID)
                }
                valueByTagID[field.tagID] = field.value
            }
            if let existingLens = valueByTagID["exif-lens"], !CSVSupport.trim(existingLens).isEmpty {
                continue
            }
            guard let focalRaw = row.fields.first(where: { $0.tagID == "exif-focal" })?.value,
                  let focalMM = focalLengthMillimeters(from: focalRaw),
                  let candidates = mapping[focalMM],
                  !candidates.isEmpty
            else { continue }

            let chosenLens: String?
            if candidates.count == 1 {
                chosenLens = candidates[0]
            } else {
                let request = EOSLensChoiceRequest(
                    sourceLine: row.sourceLine,
                    sourceIdentifier: row.sourceIdentifier,
                    focalMillimeters: focalMM,
                    candidates: candidates
                )
                chosenLens = chooseLens(for: request)
            }

            guard let chosenLens, !CSVSupport.trim(chosenLens).isEmpty else {
                return (assignments, true)
            }

            if valueByTagID["exif-lens"] == nil {
                orderedTagIDs.append("exif-lens")
            }
            valueByTagID["exif-lens"] = chosenLens
            updatedAssignments[index] = ImportAssignment(
                targetURL: assignment.targetURL,
                fields: orderedTagIDs.map { ImportFieldValue(tagID: $0, value: valueByTagID[$0] ?? "") }
            )
        }

        return (updatedAssignments, false)
    }

    private func loadEOSLensMapping() -> [Int: [String]] {
        if let cached = eosLensMappingCache {
            return cached
        }
        guard let data = try? Data(contentsOf: eosLensMappingURL),
              let rows = try? CSVSupport.parseRows(from: data),
              let header = rows.first
        else {
            eosLensMappingCache = [:]
            return [:]
        }

        let normalizedHeader = header.map(CSVSupport.normalizedHeader)
        guard let focalColumn = normalizedHeader.firstIndex(where: { $0.contains("focallength") }) else {
            eosLensMappingCache = [:]
            return [:]
        }
        let lensColumns = normalizedHeader.enumerated()
            .filter { $0.element.hasPrefix("lens") }
            .map(\.offset)
        guard !lensColumns.isEmpty else {
            eosLensMappingCache = [:]
            return [:]
        }

        var map: [Int: [String]] = [:]
        for row in rows.dropFirst() {
            guard focalColumn < row.count,
                  let focalMM = focalLengthMillimeters(from: row[focalColumn])
            else { continue }
            var candidates: [String] = []
            for column in lensColumns where column < row.count {
                let lens = CSVSupport.trim(row[column])
                if lens.isEmpty { continue }
                if !candidates.contains(lens) {
                    candidates.append(lens)
                }
            }
            if !candidates.isEmpty {
                map[focalMM] = candidates
            }
        }

        eosLensMappingCache = map
        return map
    }

    private func focalLengthMillimeters(from raw: String) -> Int? {
        let trimmed = CSVSupport.trim(raw)
        guard !trimmed.isEmpty else { return nil }
        guard let range = trimmed.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(trimmed[range])
    }

    private func chooseLens(for request: EOSLensChoiceRequest) -> String? {
        if let provider = lensChoiceProvider {
            return provider(request)
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Choose Lens for \(request.sourceIdentifier)"
        alert.informativeText = "Row \(request.sourceLine), focal length \(request.focalMillimeters) mm has multiple candidate lenses."

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
        popup.addItems(withTitles: request.candidates)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Use Selected Lens")
        alert.addButton(withTitle: "Cancel Import")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return popup.titleOfSelectedItem
    }

    private func applyMissingFieldPolicy(
        assignments: [ImportAssignment],
        run: ImportPreparedRun,
        model: AppModel
    ) -> [ImportAssignment] {
        // CSV import supports full-field replacement semantics:
        // when policy is .clear, missing incoming fields are cleared on matched files.
        guard run.options.sourceKind == .csv, run.options.emptyValuePolicy == .clear else {
            return assignments
        }

        let activeTagIDs: [String]
        if !run.options.selectedTagIDs.isEmpty {
            activeTagIDs = run.options.selectedTagIDs
        } else {
            activeTagIDs = model.importTagCatalog.map(\.id)
        }
        guard !activeTagIDs.isEmpty else {
            return assignments
        }
        let activeTagIDSet = Set(activeTagIDs)

        return assignments.map { assignment in
            var valueByTagID: [String: String] = [:]
            for field in assignment.fields where activeTagIDSet.contains(field.tagID) {
                valueByTagID[field.tagID] = field.value
            }
            for tagID in activeTagIDs where valueByTagID[tagID] == nil {
                valueByTagID[tagID] = ""
            }
            let fields = valueByTagID.keys.sorted().map { tagID in
                ImportFieldValue(tagID: tagID, value: valueByTagID[tagID] ?? "")
            }
            return ImportAssignment(targetURL: assignment.targetURL, fields: fields)
        }
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
        if !run.matchResult.warnings.isEmpty {
            lines.append("")
            lines.append("Warnings (\(run.matchResult.warnings.count))")
            let visibleWarnings = run.matchResult.warnings.prefix(20)
            for warning in visibleWarnings {
                lines.append(formatPreviewWarning(warning))
            }
            if run.matchResult.warnings.count > visibleWarnings.count {
                lines.append("… \(run.matchResult.warnings.count - visibleWarnings.count) more warnings")
            }
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

    private func formatPreviewWarning(_ warning: ImportWarning) -> String {
        let message: String
        if warning.message.hasPrefix("Using row-order matching:") {
            let reason = warning.message.replacingOccurrences(of: "Using row-order matching:", with: "").trimmingCharacters(in: .whitespaces)
            message = "Matching mode: Row order. Reason: \(reason)"
        } else {
            message = warning.message
        }
        if let sourceLine = warning.sourceLine {
            return "⚠ Line \(sourceLine): \(message)"
        }
        return "⚠ \(message)"
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

            // Options row: Apply to | If no match
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
        .onChange(of: model.selectedFileURLs.count) { _, newCount in
            if newCount == 0, session.options.scope == .selection {
                session.options.scope = .folder
            }
        }
    }

    // MARK: - Computed

    private var isRowParityActive: Bool {
        sourceKind == .csv || sourceKind == .eos1v || session.options.matchStrategy == .rowParity
    }

    private var hasAdvancedOptions: Bool {
        sourceKind == .csv || sourceKind == .gpx || sourceKind == .referenceFolder
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
        case .csv: return "Expects an ExifTool-format CSV. Ledger auto-matches by SourceFile when uniquely safe, otherwise falls back to row order."
        case .eos1v: return "Expects an EOS 1V CSV export file."
        case .gpx: return "One or more GPX track files. Photos are matched by timestamp."
        case .referenceFolder: return "A folder of reference images. Metadata is read from embedded EXIF or sidecar. Optional fallback can apply unmatched rows by row order."
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
        case .referenceFolder:
            referenceFolderAdvancedView
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

    @ViewBuilder
    private var referenceFolderAdvancedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reference Folder Options")
                .font(.headline)
            Toggle(
                "Fallback unmatched rows by row order",
                isOn: $session.options.referenceFolderRowFallbackEnabled
            )
            .toggleStyle(.checkbox)
            Text("Match by filename first. If enabled, remaining unmatched rows are applied in row order to remaining unmatched target files.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        .frame(minWidth: 340)
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
