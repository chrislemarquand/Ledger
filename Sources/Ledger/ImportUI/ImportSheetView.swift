import AppKit
import SharedUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Import Session

@MainActor
final class ImportSession: ObservableObject {
    static let eosFocalTagID = "exif-focal"
    static let eosLensTagID = "exif-lens"

    struct EOSLensChoiceDecision {
        let lens: String
        let applyToRemainingAtFocal: Bool
    }

    struct EOSLensChoiceRequest {
        let sourceLine: Int
        let sourceIdentifier: String
        let targetFileName: String
        let focalMillimeters: Int
        let candidates: [String]
        let remainingRowsAtFocal: Int
    }

    private let coordinator = ImportCoordinator()
    private let eosLensMappingURLOverride: URL?
    private let lensChoiceProvider: ((EOSLensChoiceRequest) -> String?)?
    private let lensChoiceDecisionProvider: ((EOSLensChoiceRequest) -> EOSLensChoiceDecision?)?
    private var eosLensMappingCache: [Int: [String]]?
    @Published var options: ImportRunOptions
    @Published var preparedRun: ImportPreparedRun?
    @Published var importReport: ImportRunReport?
    @Published var shouldEnterPostImportReview = false
    @Published var isBusy = false
    @Published var previewError: String?
    private var previewTask: Task<Void, Never>?
    private unowned let model: AppModel

    init(
        model: AppModel,
        sourceKind: ImportSourceKind,
        eosLensMappingURL: URL? = nil,
        lensChoiceProvider: ((EOSLensChoiceRequest) -> String?)? = nil,
        lensChoiceDecisionProvider: ((EOSLensChoiceRequest) -> EOSLensChoiceDecision?)? = nil
    ) {
        self.model = model
        var opts = coordinator.loadPersistedOptions(for: sourceKind)
        self.eosLensMappingURLOverride = eosLensMappingURL
        self.lensChoiceProvider = lensChoiceProvider
        self.lensChoiceDecisionProvider = lensChoiceDecisionProvider
        opts.sourceKind = sourceKind
        if sourceKind == .csv {
            // CSV matching is now automatic (filename when uniquely safe, else row-order fallback).
            // Preserve row-parity window controls as the fallback policy seam.
            opts.matchStrategy = .rowParity
        }
        if sourceKind == .gpx {
            // GPX Advanced values should start from defaults on each new import
            // session to avoid carrying over stale values from prior runs.
            let defaults = ImportRunOptions.defaults(for: .gpx)
            opts.gpxToleranceSeconds = defaults.gpxToleranceSeconds
            opts.gpxCameraOffsetSeconds = defaults.gpxCameraOffsetSeconds
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

    deinit {
        previewTask?.cancel()
    }

    func schedulePreviewRefresh(model: AppModel) {
        previewTask?.cancel()
        guard options.sourceURL != nil else {
            preparedRun = nil
            importReport = nil
            shouldEnterPostImportReview = false
            previewError = nil
            return
        }
        isBusy = true
        preparedRun = nil
        importReport = nil
        shouldEnterPostImportReview = false
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
                guard !Task.isCancelled else {
                    isBusy = false
                    return
                }
                preparedRun = prepared
                previewError = nil
            } catch {
                guard !Task.isCancelled else {
                    isBusy = false
                    return
                }
                preparedRun = nil
                importReport = nil
                shouldEnterPostImportReview = false
                previewError = error.localizedDescription
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
                preparedRun = nil
                importReport = nil
                shouldEnterPostImportReview = false
                let message = error.localizedDescription
                previewError = message
                presentBlockingImportAlert(
                    title: "Couldn’t prepare import.",
                    message: error.localizedDescription
                )
                return false
            }
        }

        let resolve = coordinator.resolveAssignments(preparedRun: run, resolutions: [:])
        if !resolve.unresolvedConflicts.isEmpty {
            let conflictCount = resolve.unresolvedConflicts.count
            let conflicts = conflictCount == 1 ? "1 conflict needs" : "\(conflictCount) conflicts need"
            let message = "\(conflicts) resolution. Conflict resolution will be available in a future update."
            previewError = message
            importReport = makeImportReport(
                run: run,
                resolve: resolve,
                stageSummary: nil
            )
            shouldEnterPostImportReview = shouldReview(report: importReport)
            presentBlockingImportAlert(
                title: "Import needs conflict resolution.",
                message: message
            )
            return false
        }

        let activeTagIDs = effectiveActiveTagIDSet(model: model)
        let eosLensResult = applyEOSLensPolicy(assignments: resolve.assignments, run: run, activeTagIDs: activeTagIDs)
        if eosLensResult.cancelled {
            previewError = "Import was cancelled while choosing EOS lens values."
            return false
        }

        let policyAppliedAssignments = applyMissingFieldPolicy(
            assignments: eosLensResult.assignments,
            run: run,
            model: model,
            emptyValuePolicyOverride: options.emptyValuePolicy
        )
        let stageSummary = model.stageImportAssignments(
            filterAssignments(policyAppliedAssignments, selectedTagIDs: options.selectedTagIDs, activeTagIDs: activeTagIDs),
            sourceKind: run.options.sourceKind,
            emptyValuePolicy: options.emptyValuePolicy
        )
        importReport = makeImportReport(
            run: run,
            resolve: resolve,
            stageSummary: stageSummary
        )
        shouldEnterPostImportReview = shouldReview(report: importReport)
        guard stageSummary.stagedFiles > 0 else {
            previewError = "No metadata changes to import. Check that source rows match the target files."
            return false
        }
        let fields = stageSummary.stagedFields == 1 ? "1 field" : "\(stageSummary.stagedFields) fields"
        let files = stageSummary.stagedFiles == 1 ? "1 file" : "\(stageSummary.stagedFiles) files"
        if resolve.warnings.isEmpty {
            model.statusMessage = "Prepared \(fields) for \(files). Ready to apply."
        } else {
            let warnings = resolve.warnings.count == 1 ? "1 warning" : "\(resolve.warnings.count) warnings"
            model.statusMessage = "Prepared \(fields) for \(files) with \(warnings). Ready to apply."
        }
        return true
    }

    private func makeImportReport(
        run: ImportPreparedRun,
        resolve: ImportConflictResolveResult,
        stageSummary: ImportStageSummary?
    ) -> ImportRunReport {
        var sourceRowByTarget: [URL: ImportRow] = [:]
        for match in run.matchResult.matched where sourceRowByTarget[match.targetURL] == nil {
            sourceRowByTarget[match.targetURL] = match.row
        }

        let rowItems: [ImportRowReportItem] = (stageSummary?.assignmentOutcomes ?? []).map { outcome in
            let source = sourceRowByTarget[outcome.targetURL]
            let status: ImportRowOutcomeStatus
            if outcome.stagedFields > 0 {
                status = .staged
            } else if outcome.skippedByPolicy == outcome.attemptedFields, outcome.attemptedFields > 0 {
                status = .skippedByPolicy
            } else if outcome.unsupportedFields == outcome.attemptedFields, outcome.attemptedFields > 0 {
                status = .unsupported
            } else {
                status = .unchanged
            }
            return ImportRowReportItem(
                sourceLine: source?.sourceLine,
                sourceIdentifier: source?.sourceIdentifier ?? outcome.targetURL.lastPathComponent,
                targetURL: outcome.targetURL,
                targetDisplayName: outcome.targetURL.lastPathComponent,
                status: status,
                attemptedFields: outcome.attemptedFields,
                stagedFields: outcome.stagedFields,
                skippedByPolicy: outcome.skippedByPolicy,
                unchangedFields: outcome.unchangedFields,
                unsupportedFields: outcome.unsupportedFields,
                warnings: outcome.warnings
            )
        }

        let warningStrings = (
            run.matchResult.warnings.map(formatPreviewWarning)
                + resolve.warnings
                + (stageSummary?.warnings ?? [])
        )

        let conflictItems = run.matchResult.conflicts.map {
            ImportConflictReportItem(
                sourceLine: $0.sourceLine,
                sourceIdentifier: $0.sourceIdentifier,
                message: $0.message
            )
        }

        return ImportRunReport(
            sourceKind: run.options.sourceKind,
            scope: run.options.scope,
            createdAt: Date(),
            summary: ImportRunReportSummary(
                parsedRows: run.parseResult.rows.count,
                matchedRows: run.matchResult.matched.count,
                conflictedRows: run.matchResult.conflicts.count,
                stagedFiles: stageSummary?.stagedFiles ?? 0,
                stagedFields: stageSummary?.stagedFields ?? 0,
                skippedFields: stageSummary?.skippedFields ?? 0,
                warningCount: warningStrings.count,
                conflictCount: conflictItems.count
            ),
            warnings: warningStrings,
            conflicts: conflictItems,
            rows: rowItems
        )
    }

    private func shouldReview(report: ImportRunReport?) -> Bool {
        guard let report else { return false }
        if report.summary.warningCount > 0 || report.summary.conflictCount > 0 {
            return true
        }
        return report.rows.contains { row in
            row.attemptedFields > 0 && row.status != .staged
        }
    }

    private func presentBlockingImportAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runSheetOrModal(for: NSApp.keyWindow) { _ in }
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

    var shouldShowEOSLensDependencyBanner: Bool {
        guard options.sourceKind == .eos1v else { return false }
        guard hasPreparedEOSFocalData else { return false }
        let found = foundTagIDs ?? []
        return !resolvedSelectedTagIDs(foundTagIDs: found).contains(Self.eosFocalTagID)
    }

    func isTagSelectableInFields(_ tagID: String, foundTagIDs: Set<String>) -> Bool {
        defaultSelectableTagIDs(foundTagIDs: foundTagIDs).contains(tagID)
    }

    func isTagDependencyBlockedInFields(_ tagID: String, foundTagIDs: Set<String>) -> Bool {
        guard options.sourceKind == .eos1v, tagID == Self.eosLensTagID else { return false }
        let selected = resolvedSelectedTagIDs(foundTagIDs: foundTagIDs)
        return !selected.contains(Self.eosFocalTagID)
    }

    func isTagSelectedInFields(_ tagID: String, foundTagIDs: Set<String>) -> Bool {
        resolvedSelectedTagIDs(foundTagIDs: foundTagIDs).contains(tagID)
    }

    func setTagSelectedInFields(_ tagID: String, isOn: Bool, foundTagIDs: Set<String>) {
        let selectable = defaultSelectableTagIDs(foundTagIDs: foundTagIDs)
        guard selectable.contains(tagID) else { return }

        var selected = resolvedSelectedTagIDs(foundTagIDs: foundTagIDs)
        if isOn {
            selected.insert(tagID)
        } else {
            selected.remove(tagID)
        }
        enforceEOSLensDependency(on: &selected)

        let defaultSelected = defaultSelectableTagIDs(foundTagIDs: foundTagIDs)
        if selected == defaultSelected {
            options.selectedTagIDs = []
        } else {
            options.selectedTagIDs = Array(selected).sorted()
        }
    }

    private func filterAssignments(
        _ assignments: [ImportAssignment],
        selectedTagIDs: [String],
        activeTagIDs: Set<String>
    ) -> [ImportAssignment] {
        let selected = selectedTagIDs.isEmpty ? activeTagIDs : Set(selectedTagIDs).intersection(activeTagIDs)
        return assignments.map {
            ImportAssignment(targetURL: $0.targetURL, fields: $0.fields.filter { selected.contains($0.tagID) })
        }
    }

    private func applyEOSLensPolicy(
        assignments: [ImportAssignment],
        run: ImportPreparedRun,
        activeTagIDs: Set<String>
    ) -> (assignments: [ImportAssignment], cancelled: Bool) {
        guard run.options.sourceKind == .eos1v else {
            return (assignments, false)
        }
        guard activeTagIDs.contains("exif-lens") else {
            return (assignments, false)
        }
        let mapping = loadEOSLensMapping()
        guard !mapping.isEmpty else {
            return (assignments, false)
        }

        // Defensive: matching should provide unique target URLs, but avoid
        // precondition crashes if an upstream edge case produces duplicates.
        var rowByTargetURL: [URL: ImportRow] = [:]
        for match in run.matchResult.matched where rowByTargetURL[match.targetURL] == nil {
            rowByTargetURL[match.targetURL] = match.row
        }
        var updatedAssignments = assignments
        var applyLensChoiceToRemainingByFocal: [Int: String] = [:]
        var remainingAmbiguousRowsByFocal: [Int: Int] = [:]

        for assignment in assignments {
            guard let row = rowByTargetURL[assignment.targetURL] else { continue }
            let hasLens = assignment.fields.contains {
                $0.tagID == "exif-lens" && !CSVSupport.trim($0.value).isEmpty
            }
            if hasLens { continue }
            guard let focalRaw = row.fields.first(where: { $0.tagID == "exif-focal" })?.value,
                  let focalMM = focalLengthMillimeters(from: focalRaw),
                  let candidates = mapping[focalMM],
                  candidates.count > 1
            else { continue }
            remainingAmbiguousRowsByFocal[focalMM, default: 0] += 1
        }

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
                defer {
                    if let current = remainingAmbiguousRowsByFocal[focalMM], current > 0 {
                        remainingAmbiguousRowsByFocal[focalMM] = current - 1
                    }
                }

                if let remembered = applyLensChoiceToRemainingByFocal[focalMM],
                   candidates.contains(remembered)
                {
                    chosenLens = remembered
                } else {
                    let request = EOSLensChoiceRequest(
                        sourceLine: row.sourceLine,
                        sourceIdentifier: row.sourceIdentifier,
                        targetFileName: assignment.targetURL.lastPathComponent,
                        focalMillimeters: focalMM,
                        candidates: candidates,
                        remainingRowsAtFocal: max(remainingAmbiguousRowsByFocal[focalMM, default: 0] - 1, 0)
                    )
                    guard let decision = chooseLens(for: request) else {
                        return (assignments, true)
                    }
                    chosenLens = decision.lens
                    if decision.applyToRemainingAtFocal {
                        applyLensChoiceToRemainingByFocal[focalMM] = decision.lens
                    }
                }
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
        let data: Data
        if let overrideURL = eosLensMappingURLOverride,
           let overrideData = try? Data(contentsOf: overrideURL) {
            data = overrideData
        } else {
            data = Data(EOSLensMappingEmbedded.csv.utf8)
        }

        guard let rows = try? CSVSupport.parseRows(from: data),
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

    private func chooseLens(for request: EOSLensChoiceRequest) -> EOSLensChoiceDecision? {
        if let provider = lensChoiceDecisionProvider {
            return provider(request)
        }
        if let provider = lensChoiceProvider {
            guard let lens = provider(request), !CSVSupport.trim(lens).isEmpty else { return nil }
            return EOSLensChoiceDecision(lens: lens, applyToRemainingAtFocal: false)
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Multiple Lenses Matched"
        alert.informativeText = "\(request.targetFileName) matched more than one lens at \(request.focalMillimeters) mm. Choose which lens to assign."

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: request.candidates)
        popup.sizeToFit()

        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 12
        accessory.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        accessory.addArrangedSubview(popup)

        let applyToRemainingCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        if request.remainingRowsAtFocal > 0 {
            let suffix = request.remainingRowsAtFocal == 1 ? "image" : "images"
            applyToRemainingCheckbox.title = "Apply to \(request.remainingRowsAtFocal) more \(suffix)"
            accessory.addArrangedSubview(applyToRemainingCheckbox)
        }

        // Let the accessory size to its content — NSAlert will widen itself if needed.
        accessory.layoutSubtreeIfNeeded()
        accessory.frame = NSRect(origin: .zero, size: accessory.fittingSize)

        alert.accessoryView = accessory
        alert.addButton(withTitle: "Use Lens")
        alert.addButton(withTitle: "Cancel")

        var response: NSApplication.ModalResponse = .abort
        alert.runSheetOrModal(for: nil) { response = $0 }
        guard response == .alertFirstButtonReturn,
              let selectedLens = popup.titleOfSelectedItem,
              !CSVSupport.trim(selectedLens).isEmpty
        else {
            return nil
        }

        return EOSLensChoiceDecision(
            lens: selectedLens,
            applyToRemainingAtFocal: applyToRemainingCheckbox.state == .on
        )
    }

    private func applyMissingFieldPolicy(
        assignments: [ImportAssignment],
        run: ImportPreparedRun,
        model: AppModel,
        emptyValuePolicyOverride: ImportEmptyValuePolicy? = nil
    ) -> [ImportAssignment] {
        // CSV import supports full-field replacement semantics:
        // when policy is .clear, missing incoming fields are cleared on matched files.
        let effectiveEmptyValuePolicy = emptyValuePolicyOverride ?? run.options.emptyValuePolicy
        guard run.options.sourceKind == .csv, effectiveEmptyValuePolicy == .clear else {
            return assignments
        }

        let activeTagIDSet = effectiveActiveTagIDSet(model: model)
        guard !activeTagIDSet.isEmpty else {
            return assignments
        }
        let activeTagIDs = model.importTagCatalog.map(\.id).filter { activeTagIDSet.contains($0) }

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
        let ids = Array(effectiveActiveTagIDSet(model: model))
        let uniqueFieldTagIDs = Set(fields.map(\.tagID))
        guard !ids.isEmpty else { return uniqueFieldTagIDs.count }
        let selected = Set(ids)
        var count = uniqueFieldTagIDs.filter { selected.contains($0) }.count
        if options.sourceKind == .eos1v,
           selected.contains(Self.eosFocalTagID),
           selected.contains(Self.eosLensTagID),
           uniqueFieldTagIDs.contains(Self.eosFocalTagID),
           !uniqueFieldTagIDs.contains(Self.eosLensTagID)
        {
            // EOS lens assignment is derived from focal length during import.
            // Reflect that in preview field counts so focal toggles are +/-2.
            count += 1
        }
        return count
    }

    private func effectiveActiveTagIDSet(model: AppModel) -> Set<String> {
        let catalogIDs = Set(model.importTagCatalog.map(\.id))
        var active: Set<String>
        if options.selectedTagIDs.isEmpty {
            active = catalogIDs
        } else {
            active = Set(options.selectedTagIDs).intersection(catalogIDs)
        }
        enforceEOSLensDependency(on: &active)
        return active
    }

    private func defaultSelectableTagIDs(foundTagIDs: Set<String>) -> Set<String> {
        var ids = foundTagIDs
        if options.sourceKind == .eos1v,
           hasPreparedEOSFocalData,
           Set(model.importTagCatalog.map(\.id)).contains(Self.eosLensTagID)
        {
            ids.insert(Self.eosLensTagID)
        }
        return ids
    }

    private func resolvedSelectedTagIDs(foundTagIDs: Set<String>) -> Set<String> {
        let defaultSelected = defaultSelectableTagIDs(foundTagIDs: foundTagIDs)
        var selected: Set<String>
        if options.selectedTagIDs.isEmpty {
            selected = defaultSelected
        } else {
            selected = Set(options.selectedTagIDs).intersection(defaultSelected)
        }
        enforceEOSLensDependency(on: &selected)
        return selected
    }

    private func enforceEOSLensDependency(on selected: inout Set<String>) {
        guard options.sourceKind == .eos1v else { return }
        if !selected.contains(Self.eosFocalTagID) {
            selected.remove(Self.eosLensTagID)
        }
    }

    private var hasPreparedEOSFocalData: Bool {
        guard options.sourceKind == .eos1v, let run = preparedRun else { return false }
        return run.parseResult.rows.contains { row in
            row.fields.contains(where: { $0.tagID == Self.eosFocalTagID && !CSVSupport.trim($0.value).isEmpty })
        }
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
            let cc = run.matchResult.conflicts.count
            lines.append("\(cc) \(cc == 1 ? "conflict needs" : "conflicts need") resolution")
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
            return "Line \(sourceLine): \(message)"
        }
        return message
    }

    var rowOrderFallbackWarnings: [String] {
        guard let run = preparedRun else { return [] }
        return run.matchResult.warnings
            .filter(Self.isRowOrderFallbackWarning)
            .map(formatPreviewWarning)
    }

    var requiresPostImportReview: Bool {
        guard let report = importReport else { return false }
        if report.summary.warningCount > 0 || report.summary.conflictCount > 0 {
            return true
        }
        return report.rows.contains { row in
            row.attemptedFields > 0 && row.status != .staged
        }
    }

    var reportPreviewText: String {
        guard let report = importReport else { return "No import report available." }
        var lines: [String] = []
        lines.append("Import Summary")
        lines.append("Kind: \(report.sourceKind.title)")
        lines.append("Scope: \(report.scope.title)")
        lines.append("Rows: \(report.summary.parsedRows), Matched: \(report.summary.matchedRows), Conflicts: \(report.summary.conflictCount)")
        lines.append("Staged: \(report.summary.stagedFiles) files, \(report.summary.stagedFields) fields")
        if report.summary.warningCount > 0 {
            lines.append("Warnings: \(report.summary.warningCount)")
        }
        if !report.warnings.isEmpty {
            lines.append("")
            lines.append("Warnings")
            for warning in report.warnings.prefix(20) {
                lines.append("- \(warning)")
            }
            if report.warnings.count > 20 {
                lines.append("… \(report.warnings.count - 20) more warnings")
            }
        }
        if !report.conflicts.isEmpty {
            lines.append("")
            lines.append("Conflicts")
            for conflict in report.conflicts.prefix(20) {
                lines.append("Line \(conflict.sourceLine): \(conflict.sourceIdentifier) — \(conflict.message)")
            }
            if report.conflicts.count > 20 {
                lines.append("… \(report.conflicts.count - 20) more conflicts")
            }
        }
        if !report.rows.isEmpty {
            lines.append("")
            lines.append("Row Outcomes")
            for row in report.rows.prefix(120) {
                lines.append("\(row.sourceIdentifier) → \(row.targetDisplayName) [\(row.status.rawValue)] attempted \(row.attemptedFields), staged \(row.stagedFields), skipped \(row.skippedByPolicy), unchanged \(row.unchangedFields), unsupported \(row.unsupportedFields)")
            }
            if report.rows.count > 120 {
                lines.append("… \(report.rows.count - 120) more rows")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func isRowOrderFallbackWarning(_ warning: ImportWarning) -> Bool {
        warning.message.hasPrefix("Using row-order matching:")
            || warning.message.hasPrefix("Using row-order fallback for ")
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
    @State private var isPostImportReviewMode = false

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
                        .font(.callout)
                        .padding()
                        .frame(minWidth: 260, maxWidth: 340)
                        .fixedSize(horizontal: false, vertical: true)
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
                .disabled(isPostImportReviewMode || session.isBusy || importProgress != nil)
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
                    .disabled(isPostImportReviewMode)
                }

                optionGroup("If no match:") {
                    Picker("", selection: $session.options.emptyValuePolicy) {
                        Text("Clear").tag(ImportEmptyValuePolicy.clear)
                        Text("Skip").tag(ImportEmptyValuePolicy.skip)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(isPostImportReviewMode)
                }
            }

            if let banner = activeBanner {
                InlineSheetMessageBanner(
                    tone: banner.tone,
                    title: banner.title,
                    messages: banner.messages
                )
            }

            ProgressView(value: importProgress ?? 0)
                .opacity(importProgress == nil ? 0 : 1)

            // Footer: Fields… | [Advanced…] | [Details…]   Cancel  Import
            HStack {
                Button("Fields…") {
                    showFields = true
                }
                .disabled(session.foundTagIDs == nil || isPostImportReviewMode)
                .popover(isPresented: $showFields) {
                    fieldsPopover
                }
                if hasAdvancedOptions {
                    Button("Advanced…") {
                        showAdvanced = true
                    }
                    .disabled(isPostImportReviewMode)
                    .popover(isPresented: $showAdvanced) {
                        advancedPopover
                    }
                }
                if hasPreview {
                    Button("Details…") {
                        showPreview = true
                    }
                    .disabled(session.options.sourceURL == nil)
                    .popover(isPresented: $showPreview) {
                        previewPopover
                    }
                }
                Spacer()
                if !isPostImportReviewMode {
                    Button("Cancel") {
                        model.dismissImportSheet()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                Button(isPostImportReviewMode ? "Close" : "Import") {
                    if isPostImportReviewMode {
                        model.dismissImportSheet()
                    } else {
                        performImport()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isPostImportReviewMode ? false : (session.options.sourceURL == nil || session.isBusy || importProgress != nil))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 560)
        .onChange(of: session.options.sourceURLPath) { _, _ in
            isPostImportReviewMode = false
            session.schedulePreviewRefresh(model: model)
        }
        .onChange(of: session.options.scope) { _, _ in
            isPostImportReviewMode = false
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

    private var activeBanner: (tone: InlineSheetMessageTone, title: String, messages: [String])? {
        if isPostImportReviewMode, session.requiresPostImportReview, let report = session.importReport {
            return (
                .warning,
                "Import completed with issues",
                [
                    "\(report.summary.warningCount) warnings · \(report.summary.conflictCount) conflicts",
                    "Review Details… before closing.",
                ]
            )
        }
        if !session.rowOrderFallbackWarnings.isEmpty {
            return (
                .warning,
                "Matching images by position",
                ["Images will be matched to CSV rows in order rather than by filename. Check the preview carefully."]
            )
        }
        if session.shouldShowEOSLensDependencyBanner {
            return (
                .info,
                "Lens Model requires Focal Length",
                ["Enable Focal Length in Fields to include lens tags."]
            )
        }
        return nil
    }

    private var infoText: String {
        switch sourceKind {
        case .csv: return "Import metadata from an ExifTool CSV file. Each row is matched to an image by filename. If filenames aren't available, rows are matched in the order images appear in the current view."
        case .eos1v: return "Import shooting data from a Canon EOS-1V CSV export. Rows are matched to images in the order they appear in the current view."
        case .gpx: return "Add GPS coordinates from a GPX track file. Each image is matched to a location by its capture time."
        case .referenceFolder: return "Copy metadata from a folder of reference images. Images are matched by filename. If no match is found, an optional fallback matches rows in the order images appear in the current view."
        case .referenceImage: return "Copy metadata fields from a single reference image to your selection."
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
                        let isSelectable = session.isTagSelectableInFields(tag.id, foundTagIDs: foundIDs)
                        let isDependencyBlocked = session.isTagDependencyBlockedInFields(tag.id, foundTagIDs: foundIDs)
                        Toggle(tag.label, isOn: Binding(
                            get: {
                                session.isTagSelectedInFields(tag.id, foundTagIDs: foundIDs)
                            },
                            set: { isOn in
                                session.setTagSelectedInFields(tag.id, isOn: isOn, foundTagIDs: foundIDs)
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .disabled(!isSelectable || isDependencyBlocked)
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
                    let text = isPostImportReviewMode ? session.reportPreviewText : session.previewText
                    Text(text.isEmpty ? "No matches found." : text)
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
        isPostImportReviewMode = false
        importProgress = 0.0
        Task {
            let success = await session.performImport(model: model)
            if success {
                withAnimation(.easeInOut(duration: 0.35)) {
                    importProgress = 1.0
                }
                try? await Task.sleep(for: .milliseconds(500))
                if session.shouldEnterPostImportReview {
                    importProgress = nil
                    isPostImportReviewMode = true
                } else {
                    model.dismissImportSheet()
                }
            } else {
                importProgress = nil
                if session.shouldEnterPostImportReview {
                    isPostImportReviewMode = true
                }
            }
        }
    }
}

enum InlineSheetMessageTone {
    case info
    case warning
    case error
}

struct InlineSheetMessageBanner: View {
    let tone: InlineSheetMessageTone
    let title: String
    let messages: [String]

    private var iconName: String {
        switch tone {
        case .info:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(messages, id: \.self) { message in
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
    }
}
