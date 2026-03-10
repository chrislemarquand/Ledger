import AppKit
import ExifEditCore
import Foundation

@MainActor
extension AppModel {
    func confirmDiscardUnsavedChanges(for actionDescription: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "You have unsaved metadata changes."
        alert.informativeText = "Discard unsaved edits before \(actionDescription)?"
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func discardUnsavedEdits() {
        registerMetadataUndoIfNeeded(previous: currentPendingEditState())
        pendingEditsByFile.removeAll()
        pendingImageOpsByFile.removeAll()
        removeAllStagedQuickLookPreviewFiles()
        invalidateAllBrowserThumbnails()
        invalidateInspectorPreviews(for: browserItems.map(\.url))
        recalculateInspectorState(forceNotify: true)
        setStatusMessage("Discarded unsaved metadata changes.", autoClearAfterSuccess: true)
    }

    func clearPendingEdits(for fileURLs: [URL]) {
        let uniqueURLs = Array(Set(fileURLs))
        guard !uniqueURLs.isEmpty else { return }
        registerMetadataUndoIfNeeded(previous: currentPendingEditState())
        for fileURL in uniqueURLs {
            pendingEditsByFile[fileURL] = nil
            pendingImageOpsByFile[fileURL] = nil
            removeStagedQuickLookPreviewFile(for: fileURL)
        }
        invalidateBrowserThumbnails(for: uniqueURLs)
        invalidateInspectorPreviews(for: uniqueURLs)
        recalculateInspectorState(forceNotify: true)
        let cleared = uniqueURLs.count == 1 ? "1 file" : "\(uniqueURLs.count) files"
        setStatusMessage("Cleared metadata changes for \(cleared).", autoClearAfterSuccess: true)
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
        guard !files.isEmpty else {
            setStatusMessage("No metadata changes to apply.", autoClearAfterSuccess: true)
            return
        }

        let reachableFiles = files.filter { FileManager.default.isReadableFile(atPath: $0.path) }
        let unreachableCount = files.count - reachableFiles.count

        guard !reachableFiles.isEmpty else {
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

        guard !writableFiles.isEmpty else {
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

        Task {
            let startedAt = Date()
            var succeeded: [URL] = []
            var failed: [FileError] = preflightFailed
            var firstBackupLocation: URL?
            var operationIDs: [UUID] = []
            var operationFilesByID: [UUID: URL] = [:]

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
                            operationFilesByID[result.operationID] = fileURL
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
                            operationFilesByID[operationID] = fileURL
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
                                    operationFilesByID[metadataResult.operationID] = fileURL
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
            lastOperationIDs = operationIDs
            lastOperationFilesByID = operationFilesByID

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

            if result.failed.isEmpty {
                let n = result.succeeded.count
                setStatusMessage(
                    "Applied \(n) \(n == 1 ? "image" : "images")",
                    autoClearAfterSuccess: true
                )
            } else if result.succeeded.isEmpty {
                let firstError = result.failed.first?.message ?? "Unknown write error."
                statusMessage = "Couldn’t apply changes. \(firstError)"
                let failedNames = result.failed.prefix(5).map { $0.fileURL.lastPathComponent }.joined(separator: "\n")
                Task { @MainActor in
                    let n = result.failed.count
                    let images = n == 1 ? "1 image" : "\(n) images"
                    let alert = NSAlert()
                    alert.messageText = "Couldn't Apply Changes"
                    alert.informativeText = "Metadata couldn't be written to \(images):\n\(failedNames)\n\n\(firstError)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } else {
                statusMessage = "Applied \(result.succeeded.count) of \(result.succeeded.count + result.failed.count) — \(result.failed.count) failed"
            }
            applyMetadataCompleted = applyMetadataTotal
            clearMetadataUndoHistory()

            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.autoRefreshMetadataAfterApply {
                    await self.loadMetadataForSelection()
                } else {
                    self.recalculateInspectorState(forceNotify: true)
                }
                self.isApplyingMetadata = false
            }
        }
    }

    func hasRestorableBackup(for fileURL: URL) -> Bool {
        lastOperationFilesByID.values.contains(fileURL)
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
        let files = lastOperationIDs.compactMap { lastOperationFilesByID[$0] }
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
            guard let fileURL = lastOperationFilesByID[operationID] else { return false }
            return requestedSet.contains(fileURL)
        }

        let skippedCount = requestedFiles.count - operationIDsToRestore.count
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

            for operationID in operationIDsToRestore {
                do {
                    let result = try await engine.restore(operationID: operationID)
                    if backupLocation == nil {
                        backupLocation = result.backupLocation
                    }
                    succeeded.append(contentsOf: result.succeeded)
                    failed.append(contentsOf: result.failed)
                } catch {
                    guard let fileURL = operationFilesByID[operationID] else { continue }
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
                // Remove restored operation IDs so "Restore from Backup" disables once
                // no backup remains for the selection.
                let succeededSet = Set(summary.succeeded)
                for opID in operationIDsToRestore {
                    guard let fileURL = operationFilesByID[opID],
                          succeededSet.contains(fileURL) else { continue }
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
                    alert.runModal()
                }
            } else {
                statusMessage = "Restored \(summary.succeeded.count) of \(summary.succeeded.count + summary.failed.count) — \(summary.failed.count) failed"
            }
            await loadMetadataForSelection()
        }
    }
}
