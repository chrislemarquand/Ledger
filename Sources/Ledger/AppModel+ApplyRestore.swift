import AppKit
import ExifEditCore
import Foundation
import SharedUI

@MainActor
extension AppModel {
    func confirmDiscardUnsavedChanges(for actionDescription: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "You have unsaved changes."
        alert.informativeText = "Discard your prepared changes before \(actionDescription)?"
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        var response: NSApplication.ModalResponse = .abort
        alert.runSheetOrModal(for: nil) { response = $0 }
        return response == .alertFirstButtonReturn
    }

    func discardUnsavedEdits() {
        registerMetadataUndoIfNeeded(previous: currentPendingEditState())
        let didClearRenames = !pendingRenameByFile.isEmpty
        pendingEditsByFile.removeAll()
        pendingImageOpsByFile.removeAll()
        pendingRenameByFile.removeAll()
        if didClearRenames {
            stagedOpsDisplayToken &+= 1
        }
        removeAllStagedQuickLookPreviewFiles()
        invalidateAllBrowserThumbnails()
        invalidateInspectorPreviews(for: browserItems.map(\.url))
        recalculateInspectorState(forceNotify: true)
        setStatusMessage("Discarded unsaved changes.", autoClearAfterSuccess: true)
    }

    func clearPendingEdits(for fileURLs: [URL]) {
        let uniqueURLs = Array(Set(fileURLs))
        guard !uniqueURLs.isEmpty else { return }
        registerMetadataUndoIfNeeded(previous: currentPendingEditState())
        var didClearRenames = false
        for fileURL in uniqueURLs {
            pendingEditsByFile[fileURL] = nil
            pendingImageOpsByFile[fileURL] = nil
            if pendingRenameByFile.removeValue(forKey: fileURL) != nil {
                didClearRenames = true
            }
            removeStagedQuickLookPreviewFile(for: fileURL)
        }
        if didClearRenames {
            stagedOpsDisplayToken &+= 1
        }
        invalidateBrowserThumbnails(for: uniqueURLs)
        invalidateInspectorPreviews(for: uniqueURLs)
        recalculateInspectorState(forceNotify: true)
        let cleared = uniqueURLs.count == 1 ? "1 file" : "\(uniqueURLs.count) files"
        setStatusMessage("Cleared prepared changes for \(cleared).", autoClearAfterSuccess: true)
    }

    func applyChanges() {
        let files = browserItems
            .map(\.url)
            .filter { hasPendingEdits(for: $0) }
        applyChanges(for: files)
    }

    func applyChanges(for fileURLs: [URL]) {
        let files = Array(Set(fileURLs)).sorted { $0.path < $1.path }
            .filter { hasPendingEdits(for: $0) }
        let hasPendingRenames = !pendingRenameByFile.isEmpty

        guard !files.isEmpty || hasPendingRenames else {
            setStatusMessage("No changes to apply.", autoClearAfterSuccess: true)
            return
        }

        let reachableFiles = files.filter { FileManager.default.isReadableFile(atPath: $0.path) }
        let unreachableCount = files.count - reachableFiles.count

        guard !reachableFiles.isEmpty || hasPendingRenames else {
            setStatusMessage(
                "Selected source is unavailable. Reconnect the drive, then refresh and apply again.",
                autoClearAfterSuccess: false
            )
            return
        }

        if unreachableCount > 0 {
            setStatusMessage(
                "Skipping \(unreachableCount) unavailable \(unreachableCount == 1 ? "file" : "files"); applying remaining changes.",
                autoClearAfterSuccess: true
            )
        }

        var writableFiles: [URL] = []
        var preflightFailed: [FileError] = []
        for fileURL in reachableFiles {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            if attrs?[.immutable] as? Bool == true {
                preflightFailed.append(FileError(
                    fileURL: fileURL,
                    message: "This file is locked in Finder. Unlock it to apply changes."
                ))
            } else if let values = try? fileURL.resourceValues(forKeys: [.isWritableKey]),
                      values.isWritable == false {
                preflightFailed.append(FileError(
                    fileURL: fileURL,
                    message: "This file is not writable. Check permissions in Finder."
                ))
            } else {
                writableFiles.append(fileURL)
            }
        }

        guard !writableFiles.isEmpty || hasPendingRenames else {
            let n = preflightFailed.count
            setStatusMessage(
                "\(n == 1 ? "1 file is" : "\(n) files are") locked or not writable — no changes applied.",
                autoClearAfterSuccess: false
            )
            return
        }

        isApplyingMetadata = true
        applyMetadataCompleted = 0
        applyMetadataTotal = writableFiles.count
        let shouldKeepBackups = keepBackups
        let stagedRenames = pendingRenameByFile

        Task {
            let startedAt = Date()
            var succeeded: [URL] = []
            var failed: [FileError] = preflightFailed
            var firstBackupLocation: URL?
            var operationIDs: [UUID] = []
            var operationFilesByID: [UUID: Set<URL>] = [:]
            var appliedRenameTargets: [URL: String] = [:]

            func rekeyTrackedOperationFiles(
                _ filesByOperationID: [UUID: Set<URL>],
                renamedTargets: [URL: String]
            ) -> [UUID: Set<URL>] {
                guard !renamedTargets.isEmpty else { return filesByOperationID }
                let renamedURLs = Dictionary(uniqueKeysWithValues: renamedTargets.map { sourceURL, filename in
                    (sourceURL, sourceURL.deletingLastPathComponent().appendingPathComponent(filename))
                })
                return filesByOperationID.mapValues { files in
                    Set(files.map { renamedURLs[$0] ?? $0 })
                }
            }

            for (index, fileURL) in writableFiles.enumerated() {
                let patches = buildPatches(for: fileURL)
                let imageOps = effectiveImageOperations(for: fileURL)
                guard !patches.isEmpty || !imageOps.isEmpty else {
                    applyMetadataCompleted = index + 1
                    continue
                }
                let operationID = UUID()

                do {
                    if imageOps.isEmpty {
                        let operation = EditOperation(id: operationID, targetFiles: [fileURL], changes: patches)
                        let result: OperationResult
                        if shouldKeepBackups {
                            result = try await engine.apply(operation: operation)
                            operationIDs.append(result.operationID)
                            operationFilesByID[result.operationID] = [fileURL]
                            if firstBackupLocation == nil {
                                firstBackupLocation = result.backupLocation
                            }
                        } else {
                            result = try await engine.writeMetadataWithoutBackup(operation: operation)
                        }
                        if result.failed.isEmpty {
                            succeeded.append(fileURL)
                            pendingCommitsByFile[fileURL] = pendingEditsByFile[fileURL]?.mapValues(\.value)
                            pendingEditsByFile[fileURL] = nil
                            staleMetadataFiles.insert(fileURL)
                        } else {
                            failed.append(contentsOf: result.failed)
                        }
                    } else {
                        var didApplyImageOps = false
                        if shouldKeepBackups {
                            let backupLocation = try await engine.createBackup(operationID: operationID, files: [fileURL])
                            operationFilesByID[operationID] = [fileURL]
                            if firstBackupLocation == nil {
                                firstBackupLocation = backupLocation
                            }
                        }

                        try await Self.applyStagedImageOperations(imageOps, to: fileURL)
                        didApplyImageOps = true

                        if patches.isEmpty {
                            if shouldKeepBackups {
                                operationIDs.append(operationID)
                            }
                            succeeded.append(fileURL)
                            pendingImageOpsByFile[fileURL] = nil
                            staleMetadataFiles.insert(fileURL)
                        } else {
                            let metadataOperation = EditOperation(id: operationID, targetFiles: [fileURL], changes: patches)
                            let metadataResult = try await engine.writeMetadataWithoutBackup(operation: metadataOperation)
                            if metadataResult.failed.isEmpty {
                                if shouldKeepBackups {
                                    operationIDs.append(metadataResult.operationID)
                                    operationFilesByID[metadataResult.operationID] = [fileURL]
                                }
                                succeeded.append(fileURL)
                                pendingCommitsByFile[fileURL] = pendingEditsByFile[fileURL]?.mapValues(\.value)
                                pendingEditsByFile[fileURL] = nil
                                pendingImageOpsByFile[fileURL] = nil
                                staleMetadataFiles.insert(fileURL)
                            } else {
                                if shouldKeepBackups, didApplyImageOps {
                                    do { _ = try await engine.restore(operationID: operationID) }
                                    catch { logger.error("Fallback restore after metadata write failed: \(error)") }
                                }
                                failed.append(contentsOf: metadataResult.failed)
                            }
                        }
                    }
                    removeStagedQuickLookPreviewFile(for: fileURL)
                } catch {
                    if shouldKeepBackups, !imageOps.isEmpty {
                        do { _ = try await engine.restore(operationID: operationID) }
                        catch { logger.error("Fallback restore after apply error: \(error)") }
                    }
                    failed.append(FileError(fileURL: fileURL, message: error.localizedDescription))
                }
                applyMetadataCompleted = index + 1
            }

            let summaryOperationID = operationIDs.last ?? UUID()
            let result = OperationResult(
                operationID: summaryOperationID,
                succeeded: succeeded,
                failed: failed,
                backupLocation: firstBackupLocation,
                duration: Date().timeIntervalSince(startedAt)
            )

            if !result.succeeded.isEmpty {
                // Applied image operations mutate file pixels on disk, so any pre-apply
                // cached thumbnails become stale immediately once staged ops are cleared.
                ThumbnailPipeline.invalidateCachedImages(for: Set(result.succeeded))
                invalidateBrowserThumbnails(for: result.succeeded)
                invalidateInspectorPreviews(for: result.succeeded)
                let selectedSucceeded = result.succeeded.filter { selectedFileURLs.contains($0) }
                for fileURL in selectedSucceeded {
                    loadInspectorPreview(for: fileURL, force: true, priority: .userInitiated)
                }
            }

            // Execute staged renames
            var renamedCount = 0
            var renameFailedCount = 0
            var renameFailureMessage: String?
            var renameFailedNames: [String] = []
            var didMutatePendingRenames = false
            var didReloadFiles = false
            if !stagedRenames.isEmpty {
                let renameService = BatchRenameService()
                let renameOperationID = UUID()
                let renameTargets = stagedRenames.filter { sourceURL, proposedFilename in
                    sourceURL.lastPathComponent != proposedFilename
                }

                if !renameTargets.isEmpty {
                    do {
                        let renameBackupManager: BackupManager? = shouldKeepBackups
                            ? BackupManager(baseDirectory: AppBrand.currentSupportDirectoryURL().appendingPathComponent("Backups", isDirectory: true))
                            : nil
                        let renameResult = try await renameService.executeStagedMappings(
                            targetsBySource: renameTargets,
                            operationID: renameOperationID,
                            backupManager: renameBackupManager
                        )

                        renamedCount = renameResult.succeeded.count
                        for sourceURL in renameTargets.keys {
                            if pendingRenameByFile.removeValue(forKey: sourceURL) != nil {
                                didMutatePendingRenames = true
                            }
                        }
                        if shouldKeepBackups {
                            operationIDs.append(renameOperationID)
                            operationFilesByID[renameOperationID] = Set(renameTargets.keys)
                            if firstBackupLocation == nil {
                                firstBackupLocation = renameResult.backupLocation
                            }
                        }
                        appliedRenameTargets = renameTargets
                    } catch {
                        renameFailedCount = renameTargets.count
                        renameFailureMessage = error.localizedDescription
                        renameFailedNames = renameTargets.keys
                            .map(\.lastPathComponent)
                            .sorted()
                        logger.error("Staged atomic rename failed: \(error)")
                    }
                }

                let unchangedCount = stagedRenames.count - renameTargets.count
                if unchangedCount > 0 {
                    renamedCount += unchangedCount
                    for (sourceURL, proposedFilename) in stagedRenames where sourceURL.lastPathComponent == proposedFilename {
                        if pendingRenameByFile.removeValue(forKey: sourceURL) != nil {
                            didMutatePendingRenames = true
                        }
                    }
                }

                if didMutatePendingRenames {
                    stagedOpsDisplayToken &+= 1
                }

                if renamedCount > 0, let item = selectedSidebarItem {
                    // loadFiles calls clearLoadedContentState, which always wipes
                    // pendingEditsByFile. Any edits that failed to apply (their entries
                    // were not cleared by the metadata loop) would be silently lost.
                    // Capture them here and restore after the reload, re-keyed to the
                    // post-rename URL for files that were successfully renamed.
                    var survivingEdits: [URL: [EditableTag: StagedEditRecord]] = [:]
                    for (oldURL, edits) in pendingEditsByFile {
                        if let newFilename = renameTargets[oldURL] {
                            survivingEdits[oldURL.deletingLastPathComponent().appendingPathComponent(newFilename)] = edits
                        } else {
                            survivingEdits[oldURL] = edits
                        }
                    }
                    // Stale old-URL entries in inspectorPreviewImages survive
                    // clearLoadedContentState (preserveSessionCaches: true). Purge them
                    // before loadFiles so no racing task can sneak a stale image back in
                    // after the clear, and the new URLs start from a clean slate.
                    invalidateInspectorPreviews(for: Array(renameTargets.keys))
                    await loadFiles(for: item.kind)
                    didReloadFiles = true
                    for (url, edits) in survivingEdits {
                        pendingEditsByFile[url] = edits
                    }
                    if !survivingEdits.isEmpty {
                        recalculateInspectorState(forceNotify: true)
                    }
                }
            }

            if !appliedRenameTargets.isEmpty {
                // Restore actions target the browser's current post-rename URLs, so
                // remap tracked backup entries from source paths to renamed paths.
                operationFilesByID = rekeyTrackedOperationFiles(
                    operationFilesByID,
                    renamedTargets: appliedRenameTargets
                )
            }
            lastOperationIDs = operationIDs
            lastOperationFilesByID = operationFilesByID

            // Status message
            let metadataApplied = result.succeeded.count
            let metadataFailed = result.failed.count
            if metadataFailed == 0 && renameFailedCount == 0 {
                var parts: [String] = []
                if metadataApplied > 0 {
                    let files = metadataApplied == 1 ? "1 file" : "\(metadataApplied) files"
                    parts.append("Applied changes to \(files)")
                }
                if renamedCount > 0 {
                    let files = renamedCount == 1 ? "1 file" : "\(renamedCount) files"
                    parts.append("Renamed \(files)")
                }
                setStatusMessage(parts.joined(separator: ". ") + ".", autoClearAfterSuccess: true)
            } else if metadataApplied == 0 && result.succeeded.isEmpty && renameFailedCount > 0 && renamedCount == 0 {
                let firstError = renameFailureMessage ?? "Unknown error."
                statusMessage = "Couldn’t apply name changes. \(firstError)"
                let failedNames = renameFailedNames.prefix(5).joined(separator: "\n")
                Task { @MainActor in
                    let n = renameFailedCount
                    let files = n == 1 ? "1 file" : "\(n) files"
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t Apply Name Changes"
                    alert.informativeText = "Couldn’t rename \(files). No files were renamed.\n\(failedNames)\n\n\(firstError)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runSheetOrModal(for: NSApp.keyWindow) { _ in }
                }
            } else {
                var parts: [String] = []
                let attemptedMetadata = metadataApplied + metadataFailed
                if attemptedMetadata > 0 {
                    parts.append("Applied changes to \(metadataApplied) of \(attemptedMetadata) files")
                }
                let attemptedRenames = renamedCount + renameFailedCount
                if attemptedRenames > 0 {
                    parts.append("Renamed \(renamedCount) of \(attemptedRenames) files")
                }
                let failureCount = metadataFailed + renameFailedCount
                if failureCount > 0 {
                    parts.append("\(failureCount) \(failureCount == 1 ? "file" : "files") failed")
                }
                if let firstError = result.failed.first {
                    parts.append(firstError.message)
                }
                statusMessage = parts.joined(separator: ". ") + "."
            }
            applyMetadataCompleted = applyMetadataTotal
            clearMetadataUndoHistory()

            Task { @MainActor [weak self] in
                guard let self else { return }
                if !didReloadFiles {
                    if self.autoRefreshMetadataAfterApply {
                        await self.loadMetadataForSelection()
                    } else {
                        self.recalculateInspectorState(forceNotify: true)
                    }
                }
                self.isApplyingMetadata = false
            }
        }
    }

    func hasRestorableBackup(for fileURL: URL) -> Bool {
        return lastOperationFilesByID.values.contains { $0.contains(fileURL) }
    }

    func hasAnyRestorableBackup(for fileURLs: [URL]) -> Bool {
        guard keepBackups else { return false }
        let requested = Set(fileURLs)
        guard !requested.isEmpty else { return false }
        return lastOperationFilesByID.values.contains { !$0.intersection(requested).isEmpty }
    }

    func pruneBackupsToRetentionLimit() {
        let backupDirectory = AppBrand.currentSupportDirectoryURL().appendingPathComponent("Backups", isDirectory: true)
        let count = backupRetentionCount
        Task.detached(priority: .background) { [backupDirectory, count] in
            try? BackupManager(baseDirectory: backupDirectory).pruneOperations(keepLast: count)
        }
    }

    func clearAllBackups() throws -> Int {
        let backupDirectory = AppBrand.currentSupportDirectoryURL().appendingPathComponent("Backups", isDirectory: true)
        let trashName = AppBrand.localizedTrashDisplayName
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backupDirectory.path) else {
            lastOperationIDs.removeAll()
            lastOperationFilesByID.removeAll()
            setStatusMessage("No backups to clear.", autoClearAfterSuccess: true)
            return 0
        }

        let operationFolders = try fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { UUID(uuidString: $0.lastPathComponent) != nil }

        guard !operationFolders.isEmpty else {
            setStatusMessage("No backups to clear.", autoClearAfterSuccess: true)
            return 0
        }

        var trashedOperationIDs: Set<UUID> = []
        var failedTrashCount = 0

        for folder in operationFolders {
            guard let operationID = UUID(uuidString: folder.lastPathComponent) else { continue }
            do {
                _ = try fileManager.trashItem(at: folder, resultingItemURL: nil)
                trashedOperationIDs.insert(operationID)
            } catch {
                failedTrashCount += 1
            }
        }

        if !trashedOperationIDs.isEmpty {
            lastOperationIDs.removeAll { trashedOperationIDs.contains($0) }
            for operationID in trashedOperationIDs {
                lastOperationFilesByID.removeValue(forKey: operationID)
            }
        }

        let clearedCount = trashedOperationIDs.count
        let backups = clearedCount == 1 ? "1 backup" : "\(clearedCount) backups"
        if failedTrashCount > 0 {
            statusMessage = "Moved \(backups) to \(trashName). \(failedTrashCount) couldn’t be moved."
        } else {
            setStatusMessage("Moved \(backups) to \(trashName).", autoClearAfterSuccess: true)
        }
        return clearedCount
    }

    func restoreLastOperation() {
        guard keepBackups else {
            statusMessage = "Backups are disabled in Settings."
            return
        }
        guard !lastOperationIDs.isEmpty else {
            statusMessage = "No backup to restore."
            return
        }
        let files = lastOperationIDs.flatMap { Array(lastOperationFilesByID[$0] ?? []) }
        restoreLastOperation(for: files)
    }

    func restoreLastOperation(for fileURLs: [URL]) {
        guard keepBackups else {
            statusMessage = "Backups are disabled in Settings."
            return
        }
        let requestedFiles = Array(Set(fileURLs))
        guard !requestedFiles.isEmpty else {
            statusMessage = "Select images to restore from backup."
            return
        }

        let requestedSet = Set(requestedFiles)
        let operationIDsToRestore = lastOperationIDs.filter { operationID in
            guard let files = lastOperationFilesByID[operationID] else { return false }
            return !files.intersection(requestedSet).isEmpty
        }.reversed()

        let restorableFiles = Set(operationIDsToRestore.flatMap { lastOperationFilesByID[$0] ?? [] })
        let skippedCount = requestedSet.subtracting(restorableFiles).count
        guard !operationIDsToRestore.isEmpty else {
            statusMessage = "No backup available for the selected images."
            return
        }

        let operationFilesByID = lastOperationFilesByID

        Task {
            var succeeded: [URL] = []
            var failed: [FileError] = []
            var backupLocation: URL?
            let startedAt = Date()
            var fullyRestoredOperationIDs: Set<UUID> = []
            var restoredFilesByOperationID: [UUID: Set<URL>] = [:]

            for operationID in operationIDsToRestore {
                do {
                    let result = try await engine.restore(operationID: operationID)
                    if backupLocation == nil {
                        backupLocation = result.backupLocation
                    }
                    succeeded.append(contentsOf: result.succeeded)
                    failed.append(contentsOf: result.failed)
                    restoredFilesByOperationID[operationID] = Set(result.succeeded)
                    if result.failed.isEmpty {
                        fullyRestoredOperationIDs.insert(operationID)
                    }
                } catch {
                    guard let files = operationFilesByID[operationID], let fileURL = files.first else { continue }
                    failed.append(FileError(fileURL: fileURL, message: error.localizedDescription))
                }
            }

            let summary = OperationResult(
                operationID: operationIDsToRestore.last ?? UUID(),
                succeeded: succeeded,
                failed: failed,
                backupLocation: backupLocation,
                duration: Date().timeIntervalSince(startedAt)
            )
            if !summary.succeeded.isEmpty {
                for fileURL in summary.succeeded {
                    pendingEditsByFile[fileURL] = nil
                    pendingImageOpsByFile[fileURL] = nil
                    removeStagedQuickLookPreviewFile(for: fileURL)
                    // Mark stale so loadMetadataForSelection re-reads from disk.
                    // Without this, metadataByFile retains the applied values and
                    // the inspector continues to show the pre-restore metadata.
                    staleMetadataFiles.insert(fileURL)
                }
                let succeededSet = Set(summary.succeeded)
                let didRestorePathChangingOperation = fullyRestoredOperationIDs.contains { operationID in
                    guard let tracked = operationFilesByID[operationID],
                          let restored = restoredFilesByOperationID[operationID]
                    else {
                        return false
                    }
                    return tracked != restored
                }
                if didRestorePathChangingOperation, let item = selectedSidebarItem {
                    await loadFiles(for: item.kind)
                    let restoredOriginalURLs = Set(fullyRestoredOperationIDs.flatMap { restoredFilesByOperationID[$0] ?? [] })
                    let availableURLs = Set(browserItems.map(\.url))
                    let restoredSelection = restoredOriginalURLs.intersection(availableURLs)
                    if !restoredSelection.isEmpty {
                        let focusedURL = restoredSelection.sorted { $0.path < $1.path }.first
                        setSelectionFromList(restoredSelection, focusedURL: focusedURL)
                    }
                }
                // Remove fully restored operation IDs so "Restore from Backup"
                // disables once no backup remains for the current files.
                for opID in fullyRestoredOperationIDs {
                    lastOperationIDs.removeAll { $0 == opID }
                    lastOperationFilesByID.removeValue(forKey: opID)
                }
                ThumbnailPipeline.invalidateCachedImages(for: succeededSet)
                invalidateBrowserThumbnails(for: summary.succeeded)
                invalidateInspectorPreviews(for: summary.succeeded)
                let selectedSucceeded = summary.succeeded.filter { selectedFileURLs.contains($0) }
                for fileURL in selectedSucceeded {
                    loadInspectorPreview(for: fileURL, force: true, priority: .userInitiated)
                }
            }
            if summary.failed.isEmpty {
                let restoredFiles = summary.succeeded.count == 1 ? "1 file" : "\(summary.succeeded.count) files"
                var message = "Restored \(restoredFiles)."
                if skippedCount > 0 {
                    message += " \(skippedCount) had no backup."
                }
                setStatusMessage(message, autoClearAfterSuccess: true)
            } else if summary.succeeded.isEmpty {
                let firstError = summary.failed.first?.message ?? "Unknown restore error."
                statusMessage = "Couldn’t restore metadata. \(firstError)"
                let failedNames = summary.failed.prefix(5).map { $0.fileURL.lastPathComponent }.joined(separator: "\n")
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = "Restore failed"
                    let failedFiles = summary.failed.count == 1 ? "1 file" : "\(summary.failed.count) files"
                    alert.informativeText = "Could not restore \(failedFiles):\n\(failedNames)\n\n\(firstError)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runSheetOrModal(for: NSApp.keyWindow) { _ in }
                }
            } else {
                statusMessage = "Restored \(summary.succeeded.count) of \(summary.succeeded.count + summary.failed.count) — \(summary.failed.count) failed"
            }
            await loadMetadataForSelection()
        }
    }
}
