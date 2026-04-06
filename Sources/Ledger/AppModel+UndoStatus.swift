import Foundation
import ExifEditCore

@MainActor
extension AppModel {
    func currentPendingEditState() -> PendingEditState {
        PendingEditState(
            pendingEditsByFile: pendingEditsByFile,
            pendingImageOpsByFile: pendingImageOpsByFile,
            pendingRenameByFile: pendingRenameByFile
        )
    }

    func registerMetadataUndoIfNeeded(previous: PendingEditState) {
        guard !isApplyingMetadataUndoState else { return }
        let current = currentPendingEditState()
        guard previous != current else { return }
        metadataUndoStack.append(previous)
        if metadataUndoStack.count > 100 {
            metadataUndoStack.removeFirst(metadataUndoStack.count - 100)
        }
        metadataRedoStack.removeAll()
    }

    func applyPendingEditState(_ state: PendingEditState) {
        isApplyingMetadataUndoState = true
        let previousPreviewSources = Set(pendingImageOpsByFile.keys)
        pendingEditsByFile = state.pendingEditsByFile
        pendingImageOpsByFile = state.pendingImageOpsByFile.reduce(into: [:]) { partial, entry in
            let normalized = Self.normalizeStagedImageOperations(entry.value)
            if !normalized.isEmpty {
                partial[entry.key] = normalized
            }
        }
        let nextPreviewSources = Set(pendingImageOpsByFile.keys)
        let removedSources = previousPreviewSources.subtracting(nextPreviewSources)
        for sourceURL in removedSources {
            removeStagedQuickLookPreviewFile(for: sourceURL)
        }
        let invalidated = Array(previousPreviewSources.union(nextPreviewSources))
        if !invalidated.isEmpty {
            invalidateBrowserThumbnails(for: invalidated)
            // Do NOT clear inspectorPreviewImages here. The cached image is the raw disk
            // image; the rotation/flip transform is applied on the fly in
            // inspectorPreviewImage(for:) via displayImageForCurrentStagedState. Clearing
            // it causes the preview to blank while an identical image reloads from disk.
            // Bump stagedOpsDisplayToken instead so gallery cells reconfigure immediately
            // with the updated (undo'd) transform.
            stagedOpsDisplayToken &+= 1
        }
        let previousRenames = pendingRenameByFile
        pendingRenameByFile = state.pendingRenameByFile
        if pendingRenameByFile != previousRenames {
            stagedOpsDisplayToken &+= 1
        }
        recalculateInspectorState(forceNotify: true)
        isApplyingMetadataUndoState = false
    }

    func clearMetadataUndoHistory() {
        metadataUndoStack.removeAll()
        metadataRedoStack.removeAll()
    }

    func availableSnapshot(for fileURL: URL) -> FileMetadataSnapshot? {
        // Keep last-known metadata visible while a stale file is being refreshed.
        // This avoids inspector fields collapsing to empty during rotate/refresh cycles.
        return metadataByFile[fileURL]
    }

    func setStatusMessage(_ message: String, autoClearAfterSuccess: Bool) {
        statusResetTask?.cancel()
        statusResetTask = nil
        statusMessage = message

        guard autoClearAfterSuccess else { return }
        statusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.statusMessage == message else { return }
            self.statusMessage = "Ready"
            self.statusResetTask = nil
        }
    }

    func persistInspectorFieldVisibility() {
        let visibility = Dictionary(uniqueKeysWithValues: activeInspectorFieldCatalog.map { ($0.id, $0.isEnabled) })
        UserDefaults.standard.set(visibility, forKey: Self.inspectorFieldVisibilityKey)
    }

    func applyInspectorFieldCatalogUpdate(_ updated: [FieldCatalogEntry]) {
        guard updated != activeInspectorFieldCatalog else { return }
        activeInspectorFieldCatalog = updated
        persistInspectorFieldVisibility()
        dropPendingEditsForDisabledFields()
        recalculateInspectorState(forceNotify: true)
    }

    private func dropPendingEditsForDisabledFields() {
        let enabledIDs = Set(activeInspectorFieldCatalog.filter(\.isEnabled).map(\.id))
        var changed = false
        for fileURL in pendingEditsByFile.keys {
            guard let staged = pendingEditsByFile[fileURL] else { continue }
            let filtered = staged.filter { enabledIDs.contains($0.key.id) }
            if filtered.count != staged.count {
                pendingEditsByFile[fileURL] = filtered.isEmpty ? nil : filtered
                changed = true
            }
        }
        if changed {
            setStatusMessage("Removed staged values for hidden inspector fields.", autoClearAfterSuccess: true)
        }
    }
}
