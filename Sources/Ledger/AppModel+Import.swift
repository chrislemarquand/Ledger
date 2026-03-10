import ExifEditCore
import Foundation

@MainActor
extension AppModel {
    var importTagCatalog: [ImportTagDescriptor] {
        activeInspectorFieldCatalog.filter(\.isEnabled).map {
            ImportTagDescriptor(
                id: $0.id,
                key: $0.key,
                namespace: $0.namespace,
                label: $0.label,
                section: $0.section,
                inputKind: $0.inputKind
            )
        }
    }

    /// Returns files in stable browser-visible order for import matching.
    /// Row-parity import depends on this order: row 1 -> index 0, row 2 -> index 1, etc.
    func importTargetFiles(for scope: ImportScope) -> [URL] {
        let visibleOrder = filteredBrowserItems.map(\.url)
        switch scope {
        case .selection:
            let selectionSet = selectedFileURLs
            let selection = visibleOrder.filter { selectionSet.contains($0) }
            if !selection.isEmpty {
                return selection
            }
            return visibleOrder
        case .folder:
            return visibleOrder
        }
    }

    func hasPendingEdits(inImportScope scope: ImportScope) -> Bool {
        importTargetFiles(for: scope).contains(where: { hasPendingEdits(for: $0) })
    }

    func exportExifToolCSV(scope: ImportScope, destinationURL: URL) async throws -> Int {
        let files = importTargetFiles(for: scope)
        guard !files.isEmpty else {
            throw ImportAdapterError.unsupported("No files are available to export.")
        }

        let fileCount = files.count
        let filesSnapshot = files
        let destinationSnapshot = destinationURL
        try await ExifToolCSVExportService().export(fileURLs: filesSnapshot, destinationURL: destinationSnapshot)

        setStatusMessage(
            "Exported ExifTool CSV for \(fileCount == 1 ? "1 file" : "\(fileCount) files").",
            autoClearAfterSuccess: true
        )
        return fileCount
    }

    func importMetadataSnapshots(for files: [URL]) async -> [URL: FileMetadataSnapshot] {
        let unique = Array(Set(files)).sorted(by: { $0.path < $1.path })
        guard !unique.isEmpty else { return [:] }
        var map = metadataByFile

        // Start from cached metadata so imports still work if one refresh call fails.
        var result: [URL: FileMetadataSnapshot] = [:]
        for fileURL in unique {
            if let cached = map[fileURL] {
                result[fileURL] = cached
            }
        }

        // Read import metadata in smaller batches so one slow call does not drop an entire run.
        let batchSize = max(1, Self.folderMetadataBatchSize)
        for start in stride(from: 0, to: unique.count, by: batchSize) {
            let end = min(start + batchSize, unique.count)
            let batch = Array(unique[start..<end])
            let snapshots = await readMetadataBatchResilient(batch)
            for snapshot in snapshots {
                result[snapshot.fileURL] = snapshot
                map[snapshot.fileURL] = snapshot
                staleMetadataFiles.remove(snapshot.fileURL)
            }
        }

        // Import matching should see staged values (for example, staged EOS date/time before apply).
        for fileURL in unique {
            guard var snapshot = result[fileURL],
                  let staged = pendingEditsByFile[fileURL],
                  !staged.isEmpty
            else {
                continue
            }

            var fields = snapshot.fields
            for (tag, record) in staged {
                let value = record.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let index = fields.firstIndex(where: { $0.namespace == tag.namespace && $0.key == tag.key }) {
                    if value.isEmpty {
                        fields.remove(at: index)
                    } else {
                        fields[index] = MetadataField(key: tag.key, namespace: tag.namespace, value: value)
                    }
                } else if !value.isEmpty {
                    fields.append(MetadataField(key: tag.key, namespace: tag.namespace, value: value))
                }
            }
            snapshot = FileMetadataSnapshot(fileURL: snapshot.fileURL, fields: fields)
            result[fileURL] = snapshot
        }

        metadataByFile = map
        return result
    }

    func stageImportAssignments(
        _ assignments: [ImportAssignment],
        sourceKind: ImportSourceKind,
        emptyValuePolicy: ImportEmptyValuePolicy
    ) -> ImportStageSummary {
        guard !assignments.isEmpty else {
            return ImportStageSummary(
                stagedFiles: 0,
                stagedFields: 0,
                skippedFields: 0,
                warnings: [],
                assignmentOutcomes: []
            )
        }

        let previousState = currentPendingEditState()

        var stagedFiles: Set<URL> = []
        var stagedFields = 0
        var skippedFields = 0
        var warnings: [String] = []
        var assignmentOutcomes: [ImportAssignmentOutcome] = []

        for assignment in assignments {
            var attemptedFields = 0
            var rowStagedFields = 0
            var rowSkippedByPolicy = 0
            var rowUnchangedFields = 0
            var rowUnsupportedFields = 0
            var rowWarnings: [String] = []
            for field in assignment.fields {
                attemptedFields += 1
                guard let tag = editableTag(forID: field.tagID) else {
                    skippedFields += 1
                    rowUnsupportedFields += 1
                    let warning = "Unsupported tag \(field.tagID) skipped."
                    warnings.append(warning)
                    rowWarnings.append(warning)
                    continue
                }
                let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty, emptyValuePolicy == .skip {
                    skippedFields += 1
                    rowSkippedByPolicy += 1
                    continue
                }
                stageEdit(
                    trimmed,
                    for: tag,
                    fileURLs: [assignment.targetURL],
                    source: .importSource(sourceKind)
                )
                if pendingEditsByFile[assignment.targetURL]?[tag] != nil {
                    stagedFields += 1
                    rowStagedFields += 1
                    stagedFiles.insert(assignment.targetURL)
                } else {
                    rowUnchangedFields += 1
                }
            }
            assignmentOutcomes.append(
                ImportAssignmentOutcome(
                    targetURL: assignment.targetURL,
                    attemptedFields: attemptedFields,
                    stagedFields: rowStagedFields,
                    skippedByPolicy: rowSkippedByPolicy,
                    unchangedFields: rowUnchangedFields,
                    unsupportedFields: rowUnsupportedFields,
                    warnings: rowWarnings
                )
            )
        }

        registerMetadataUndoIfNeeded(previous: previousState)
        recalculateInspectorState(forceNotify: true)
        setStatusMessage(
            "Staged import for \(stagedFiles.count == 1 ? "1 file" : "\(stagedFiles.count) files").",
            autoClearAfterSuccess: true
        )
        return ImportStageSummary(
            stagedFiles: stagedFiles.count,
            stagedFields: stagedFields,
            skippedFields: skippedFields,
            warnings: warnings,
            assignmentOutcomes: assignmentOutcomes
        )
    }
}
