import AppKit
import ExifEditCore
import Foundation

@MainActor
extension AppModel {
    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let folderURL = panel.url else { return }
                Task { @MainActor in
                    guard let self else { return }
                    if self.hasUnsavedEdits {
                        let shouldDiscard = self.confirmDiscardUnsavedChanges(for: "opening a different folder")
                        guard shouldDiscard else { return }
                        self.discardUnsavedEdits()
                    }
                    self.didChooseFolder(folderURL)
                }
            }
            return
        }

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        if hasUnsavedEdits {
            let shouldDiscard = confirmDiscardUnsavedChanges(for: "opening a different folder")
            guard shouldDiscard else { return }
            discardUnsavedEdits()
        }
        didChooseFolder(folderURL)
    }

    func openFolder(at folderURL: URL) {
        var isDirectory: ObjCBool = false
        let standardized = folderURL.standardizedFileURL
        if !FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) {
            clearLoadedContentState(preserveSessionCaches: true)
            browserEnumerationError = CocoaError(.fileNoSuchFile)
            return
        }
        didChooseFolder(folderURL)
    }

    func refresh() {
        invalidateAllBrowserThumbnails()
        if let item = selectedSidebarItem {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.loadFiles(for: item.kind)
            }
        }

        Task {
            await loadMetadataForSelection()
        }
    }

    /// Called when the app becomes active. If a folder is selected but the browser
    /// is empty — e.g. because a TCC permission prompt blocked the initial enumeration
    /// — silently retry the file load now that permission may have been granted.
    ///
    /// Privacy-gated locations (Desktop, Downloads) are skipped until the user has
    /// explicitly clicked a sidebar item; startup/background retries should not probe
    /// privacy-sensitive locations before explicit user intent.
    func reloadFilesIfBrowserEmpty() {
        guard let item = selectedSidebarItem, browserItems.isEmpty else { return }
        guard !isPrivacySensitiveSidebarKind(item.kind) || hasHadExplicitSidebarSelection else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadFiles(for: item.kind)
        }
    }

    func refreshMetadata(for fileURLs: [URL], allowFolderReloadFallback: Bool = true) {
        let files = Array(Set(fileURLs)).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }

        Task {
            let existingFiles = files.filter { FileManager.default.fileExists(atPath: $0.path) }
            let missingCount = files.count - existingFiles.count

            if allowFolderReloadFallback, missingCount > 0, let item = selectedSidebarItem {
                await loadFiles(for: item.kind)
                refreshMetadata(for: browserItems.map(\.url), allowFolderReloadFallback: false)
                return
            }

            guard !existingFiles.isEmpty else {
                if missingCount > 0 {
                    let missingText = missingCount == 1 ? "1 file was" : "\(missingCount) files were"
                    statusMessage = "\(missingText) not found. Refresh the folder to update renamed or moved files."
                }
                return
            }

            do {
                let snapshots = try await engine.readMetadata(files: existingFiles)
                var map = metadataByFile
                for snapshot in snapshots {
                    map[snapshot.fileURL] = snapshot
                    staleMetadataFiles.remove(snapshot.fileURL)
                    pendingCommitsByFile.removeValue(forKey: snapshot.fileURL)
                }
                metadataByFile = map
                invalidateInspectorPreviews(for: existingFiles)
                ThumbnailPipeline.invalidateCachedImages(for: Set(existingFiles))
                for fileURL in existingFiles {
                    forceReloadInspectorPreview(for: fileURL)
                }
                invalidateBrowserThumbnails(for: existingFiles)
                recalculateInspectorState()
                if let selectedURL = primarySelectionURL, existingFiles.contains(selectedURL) {
                    ensureInspectorPreviewLoaded(for: selectedURL)
                }
                let refreshed = existingFiles.count == 1 ? "1 file" : "\(existingFiles.count) files"
                if missingCount > 0 {
                    let missing = missingCount == 1 ? "1 file was missing." : "\(missingCount) files were missing."
                    setStatusMessage("Refreshed metadata for \(refreshed). \(missing)", autoClearAfterSuccess: true)
                } else {
                    setStatusMessage("Refreshed metadata for \(refreshed).", autoClearAfterSuccess: true)
                }
            } catch {
                let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
                statusMessage = firstLine.isEmpty ? "Couldn’t refresh metadata." : firstLine
            }
        }
    }

    func selectSidebar(id: String?) {
        hasHadExplicitSidebarSelection = true
        selectedSidebarID = id
        if let id {
            backgroundWarmTasksBySelectionID[id]?.cancel()
            backgroundWarmTasksBySelectionID[id] = nil
        }
        guard let itemToLoad = selectedSidebarItem else { return }

        // Avoid touching protected locations on app launch; compute counts only after explicit selection.
        ensureSidebarImageCount(for: itemToLoad)

        // Show the loading skeleton immediately so the gallery's reloadData() flash is masked.
        // loadFiles is deferred to the next task so SwiftUI renders the skeleton before clearing state.
        isFolderContentLoading = true
        let kind = itemToLoad.kind
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadFiles(for: kind)
            self.isFolderContentLoading = false
        }
    }

    /// Explicit user-initiated sidebar selection path from the SwiftUI sidebar.
    /// This bypasses auto-selection suppression heuristics and treats the change
    /// as intentional click/keyboard navigation.
    func handleExplicitSidebarSelectionChange(to newID: String?) {
        let oldID = selectedSidebarID
        guard newID != oldID else { return }

        if hasUnsavedEdits {
            let shouldDiscard = confirmDiscardUnsavedChanges(for: "switching folders")
            guard shouldDiscard else {
                selectedSidebarID = oldID
                return
            }
            discardUnsavedEdits()
        }

        if let oldID, oldID != newID {
            scheduleBackgroundWarm(forSelectionID: oldID, files: browserItems.map(\.url))
        }
        selectSidebar(id: newID)
    }
}
