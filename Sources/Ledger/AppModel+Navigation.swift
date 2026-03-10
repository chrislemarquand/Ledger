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

    func refreshMetadata(for fileURLs: [URL]) {
        let files = Array(Set(fileURLs)).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }

        Task {
            do {
                let snapshots = try await engine.readMetadata(files: files)
                var map = metadataByFile
                for snapshot in snapshots {
                    map[snapshot.fileURL] = snapshot
                    staleMetadataFiles.remove(snapshot.fileURL)
                    pendingCommitsByFile.removeValue(forKey: snapshot.fileURL)
                }
                metadataByFile = map
                invalidateInspectorPreviews(for: files)
                ThumbnailPipeline.invalidateCachedImages(for: Set(files))
                for fileURL in files {
                    forceReloadInspectorPreview(for: fileURL)
                }
                invalidateBrowserThumbnails(for: files)
                recalculateInspectorState()
                if let selectedURL = primarySelectionURL, files.contains(selectedURL) {
                    ensureInspectorPreviewLoaded(for: selectedURL)
                }
                let refreshed = files.count == 1 ? "1 file" : "\(files.count) files"
                setStatusMessage("Refreshed metadata for \(refreshed).", autoClearAfterSuccess: true)
            } catch {
                statusMessage = error.localizedDescription
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
