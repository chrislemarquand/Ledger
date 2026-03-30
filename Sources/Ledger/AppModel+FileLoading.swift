import AppKit
import ExifEditCore
import Foundation
import SharedUI

@MainActor
extension AppModel {
    var selectedSidebarItem: SidebarItem? {
        guard let selectedSidebarID else { return nil }
        return sidebarItems.first { $0.id == selectedSidebarID }
    }

    private func sidebarImageCount(for item: SidebarItem) -> Int {
        sidebarImageCounts[item.id] ?? 0
    }

    func sidebarImageCountText(for item: SidebarItem) -> String? {
        guard let count = sidebarImageCounts[item.id] else { return nil }
        return "\(count)"
    }

    func shouldEagerlyLoadSidebarImageCount(for item: SidebarItem) -> Bool {
        !isPrivacySensitiveSidebarKind(item.kind)
    }

    func ensureSidebarImageCount(for item: SidebarItem) {
        guard sidebarImageCounts[item.id] == nil else { return }
        guard sidebarImageCountTasks[item.id] == nil else { return }
        if isPrivacySensitiveSidebarKind(item.kind) {
            // Never touch privacy-sensitive locations in background.
            // Only load counts after an explicit selection of the exact item.
            guard hasHadExplicitSidebarSelection, selectedSidebarID == item.id else { return }
        }
        guard let sourceURL = sidebarCountURL(for: item.kind) else {
            var counts = sidebarImageCounts
            counts[item.id] = 0
            sidebarImageCounts = counts
            return
        }

        let id = item.id
        sidebarImageCountTasks[id] = Task.detached(priority: .utility) { [id, sourceURL] in
            let count = Self.countSupportedImages(in: sourceURL)
            await MainActor.run {
                var counts = self.sidebarImageCounts
                counts[id] = count
                self.sidebarImageCounts = counts
                self.sidebarImageCountTasks[id] = nil
            }
        }
    }


    func didChooseFolder(_ folderURL: URL) {
        if let item = noteRecentLocation(folderURL, promoteToTopIfExisting: false) {
            if selectedSidebarID != item.id {
                selectedSidebarID = item.id
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.loadFiles(for: item.kind)
            }
        } else {
            // If the folder is invalid/unreadable, still route through loadFiles so
            // browserEnumerationError is populated for error-state rendering/tests.
            let fallbackURL = folderURL.standardizedFileURL
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.loadFiles(for: .folder(fallbackURL))
            }
        }
        NotificationCenter.default.post(
            name: Notification.Name("\(AppBrand.identifierPrefix).SidebarShouldResignFocus"),
            object: nil
        )
    }

    func loadFiles(for kind: SidebarKind) async {
        deferredFolderMetadataPrefetchTask?.cancel()
        deferredFolderMetadataPrefetchTask = nil
        folderMetadataLoadTask?.cancel()
        folderMetadataLoadTask = nil
        folderMetadataLoadID = UUID()
        browserItemHydrationTask?.cancel()
        browserItemHydrationTask = nil
        browserItemHydrationID = UUID()
        selectionMetadataLoadTask?.cancel()
        selectionMetadataLoadTask = nil
        previewPreloadTask?.cancel()
        previewPreloadTask = nil
        deferredPreviewPreloadTask?.cancel()
        deferredPreviewPreloadTask = nil
        previewPreloadID = UUID()

        let urls: [URL]
        var enumerationError: Error?

        do {
            switch kind {
            case .pictures:
                urls = try enumerateImages(in: picturesDirectoryURL())
            case .desktop:
                urls = try enumerateImages(in: desktopDirectoryURL())
            case .downloads:
                urls = try enumerateImages(in: downloadsDirectoryURL())
            case let .mountedVolume(volumeURL):
                urls = try enumerateImages(in: volumeURL)
            case let .favorite(favoriteURL):
                urls = try enumerateImages(in: favoriteURL)
            case let .folder(folder):
                urls = try enumerateImages(in: folder)
            }
        } catch {
            enumerationError = error
            urls = []
        }

        // If enumeration failed because the folder no longer exists, remove the sidebar entry now
        // so stale entries don't persist after relaunch. Permission errors are NOT pruned —
        // a temporarily inaccessible drive or Desktop/Downloads without TCC should remain.
        if let enumerationError, isFolderNotFoundError(enumerationError) {
            let folderName: String
            let sectionLabel: String
            switch kind {
            case let .favorite(url):
                folderName = url.lastPathComponent
                sectionLabel = "Pinned"
                favoriteItems.removeAll { item in
                    guard case let .favorite(u) = item.kind else { return false }
                    return u == url
                }
                persistFavorites()
                refreshSidebarItems(selectFirstWhenMissing: false, preferredSelectionID: nil)
            case let .folder(url):
                folderName = url.lastPathComponent
                sectionLabel = "Recents"
                locationItems.removeAll { item in
                    guard case let .folder(u) = item.kind else { return false }
                    return u == url
                }
                recentLocationLastOpenedAtByID.removeValue(forKey: "folder::\(url.path)")
                persistRecentLocations()
                refreshSidebarItems(selectFirstWhenMissing: false, preferredSelectionID: nil)
            default:
                folderName = ""
                sectionLabel = ""
            }
            selectedSidebarID = nil

            if !folderName.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "\u{201c}\(folderName)\u{201d} No Longer Available"
                alert.informativeText = "This folder could not be found — it may have been deleted or moved. It has been removed from \(sectionLabel) in \(AppBrand.displayName)."
                alert.addButton(withTitle: "OK")
                alert.runSheetOrModal(for: NSApp.keyWindow) { _ in }
            }
        }

        let loadID = UUID()
        activeFolderLoadID = loadID
        let hydrationID = UUID()

        let shouldPublishHydratedOnly = browserSort != .name
        let prehydratedItems: [BrowserItem]?
        if shouldPublishHydratedOnly {
            let attributesByURL = await readBrowserFileAttributes(for: urls)
            guard !Task.isCancelled, activeFolderLoadID == loadID else { return }
            prehydratedItems = urls.map { url in
                let attrs = attributesByURL[url]
                return BrowserItem(
                    url: url,
                    name: url.lastPathComponent,
                    modifiedAt: attrs?.modifiedAt,
                    createdAt: attrs?.createdAt,
                    sizeBytes: attrs?.sizeBytes,
                    kind: attrs?.kind
                )
            }
        } else {
            prehydratedItems = nil
        }

        // clearLoadedContentState resets browserEnumerationError to nil;
        // re-apply it afterwards so the error state is actually visible to the view.
        clearLoadedContentState(
            preserveSessionCaches: true,
            preserveBrowserItemsDuringSwitch: true
        )
        browserEnumerationError = enumerationError
        browserItemHydrationID = hydrationID

        if let prehydratedItems {
            browserItems = prehydratedItems
        } else {
            browserItems = urls.map {
                BrowserItem(
                    url: $0,
                    name: $0.lastPathComponent,
                    modifiedAt: nil,
                    createdAt: nil,
                    sizeBytes: nil,
                    kind: nil
                )
            }
            startBrowserItemHydration(for: urls, hydrationID: hydrationID)
        }

        startInitialThumbnailWarmup(for: urls, loadID: loadID)
        scheduleDeferredFolderMetadataPrefetch(
            for: urls,
            batchSize: metadataBatchSize(for: kind),
            loadID: loadID
        )
    }

    func clearLoadedContentState(
        preserveSessionCaches: Bool = false,
        preserveBrowserItemsDuringSwitch: Bool = false
    ) {
        // Folder switches should prioritize the newly selected folder; cancel stale
        // shared thumbnail work that would otherwise keep occupying the broker queue.
        Task { await ThumbnailService.cancelAllRequests() }

        folderMetadataLoadTask?.cancel()
        folderMetadataLoadTask = nil
        folderMetadataLoadID = UUID()
        deferredFolderMetadataPrefetchTask?.cancel()
        deferredFolderMetadataPrefetchTask = nil
        browserItemHydrationTask?.cancel()
        browserItemHydrationTask = nil
        browserItemHydrationID = UUID()
        selectionMetadataLoadTask?.cancel()
        selectionMetadataLoadTask = nil
        isFolderMetadataLoading = false
        folderMetadataLoadCompleted = 0
        folderMetadataLoadTotal = 0
        browserEnumerationError = nil

        previewPreloadTask?.cancel()
        previewPreloadTask = nil
        deferredPreviewPreloadTask?.cancel()
        deferredPreviewPreloadTask = nil
        previewPreloadID = UUID()
        isPreviewPreloading = false

        if !preserveBrowserItemsDuringSwitch {
            browserItems = []
        }
        selectedFileURLs = []
        draftValues = [:]
        baselineValues = [:]
        if !preserveSessionCaches {
            metadataByFile = [:]
            staleMetadataFiles = []
        }
        pendingEditsByFile = [:]
        pendingImageOpsByFile = [:]
        removeAllStagedQuickLookPreviewFiles()
        if !preserveSessionCaches {
            inspectorPreviewImages = [:]
            inspectorPreviewRecency = []
        }
        inspectorPreviewInflight = []
        for task in inspectorPreviewTasksByURL.values {
            task.cancel()
        }
        inspectorPreviewTasksByURL = [:]
        clearMetadataUndoHistory()
        recalculateInspectorState(forceNotify: true)
    }

    private func startInitialThumbnailWarmup(for files: [URL], loadID: UUID) {
        let warmupTargets = Array(files.prefix(Self.initialThumbnailWarmupCount))
        guard !warmupTargets.isEmpty else { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for fileURL in warmupTargets {
                if Task.isCancelled { return }
                if await MainActor.run(body: { self.activeFolderLoadID != loadID }) {
                    return
                }
                _ = await ThumbnailService.request(
                    url: fileURL,
                    requiredSide: Self.initialThumbnailWarmupSide,
                    forceRefresh: false
                )
            }
        }
    }

    private func scheduleDeferredFolderMetadataPrefetch(for files: [URL], batchSize: Int, loadID: UUID) {
        deferredFolderMetadataPrefetchTask?.cancel()
        deferredFolderMetadataPrefetchTask = nil
        deferredFolderMetadataPrefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: Self.metadataPrefetchStartDelayNanoseconds) } catch { return }
            guard self.activeFolderLoadID == loadID else { return }
            self.startFolderMetadataPrefetch(for: files, batchSize: batchSize)
        }
    }

    private func startBrowserItemHydration(for files: [URL], hydrationID: UUID) {
        browserItemHydrationTask?.cancel()
        browserItemHydrationTask = nil
        guard !files.isEmpty else { return }

        browserItemHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let attributesByURL = await self.readBrowserFileAttributes(for: files)

            guard !Task.isCancelled, self.browserItemHydrationID == hydrationID else { return }
            if !self.browserItems.isEmpty {
                // Apply hydrated attributes in one pass to avoid repeated resort/reload
                // churn while folder loads under non-name sort modes.
                self.browserItems = self.browserItems.map { item in
                    guard let attrs = attributesByURL[item.url] else { return item }
                    return BrowserItem(
                        url: item.url,
                        name: item.name,
                        modifiedAt: attrs.modifiedAt,
                        createdAt: attrs.createdAt,
                        sizeBytes: attrs.sizeBytes,
                        kind: attrs.kind
                    )
                }
            }
            self.browserItemHydrationTask = nil
        }
    }

    typealias BrowserFileAttributes = (modifiedAt: Date?, createdAt: Date?, sizeBytes: Int?, kind: String?)

    private func readBrowserFileAttributes(for files: [URL]) async -> [URL: BrowserFileAttributes] {
        await Task.detached(priority: .utility) { () -> [URL: BrowserFileAttributes] in
            var result: [URL: BrowserFileAttributes] = [:]
            result.reserveCapacity(files.count)
            let batchSize = 96
            for batchStart in stride(from: 0, to: files.count, by: batchSize) {
                if Task.isCancelled { return result }
                let batchEnd = min(batchStart + batchSize, files.count)
                let batch = files[batchStart..<batchEnd]
                for fileURL in batch {
                    let resourceValues = try? fileURL.resourceValues(
                        forKeys: [
                            .contentModificationDateKey,
                            .creationDateKey,
                            .fileSizeKey,
                            .localizedTypeDescriptionKey
                        ]
                    )
                    result[fileURL] = (
                        resourceValues?.contentModificationDate,
                        resourceValues?.creationDate,
                        resourceValues?.fileSize,
                        resourceValues?.localizedTypeDescription
                    )
                }
            }
            return result
        }.value
    }

    func sortBrowserItems(_ items: [BrowserItem]) -> [BrowserItem] {
        let asc = browserSortAscending
        // cmp(before) returns true when lhs should precede rhs, flipping for descending.
        // Nil values are always sorted last regardless of direction.
        return items.sorted { lhs, rhs in
            func cmp(_ before: Bool) -> Bool { asc ? before : !before }
            switch browserSort {
            case .name:
                let c = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if c != .orderedSame { return cmp(c == .orderedAscending) }
                return cmp(lhs.url.path < rhs.url.path)
            case .created:
                switch (lhs.createdAt, rhs.createdAt) {
                case let (l?, r?):
                    if l != r { return cmp(l < r) }
                case (nil, nil): break
                case (nil, _?): return false  // nil always last
                case (_?, nil): return true   // nil always last
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .modified:
                switch (lhs.modifiedAt, rhs.modifiedAt) {
                case let (l?, r?):
                    if l != r { return cmp(l < r) }
                case (nil, nil): break
                case (nil, _?): return false  // nil always last
                case (_?, nil): return true   // nil always last
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .size:
                switch (lhs.sizeBytes, rhs.sizeBytes) {
                case let (l?, r?):
                    if l != r { return cmp(l < r) }
                case (nil, nil): break
                case (nil, _?): return false  // nil always last
                case (_?, nil): return true   // nil always last
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .kind:
                let lKind = lhs.kind ?? ""
                let rKind = rhs.kind ?? ""
                let c = lKind.localizedCaseInsensitiveCompare(rKind)
                if c != .orderedSame { return cmp(c == .orderedAscending) }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }



    private func metadataBatchSize(for kind: SidebarKind) -> Int {
        switch kind {
        case .mountedVolume:
            return 1
        case let .favorite(url), let .folder(url):
            return isLikelyExternalLocation(url) ? 1 : Self.folderMetadataBatchSize
        case .pictures, .desktop, .downloads:
            return Self.folderMetadataBatchSize
        }
    }

    private func isLikelyExternalLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/Volumes/")
    }

    private func isReachableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    func installWorkspaceVolumeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]

        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    self?.handleWorkspaceVolumeChange()
                }
            }
            workspaceObserverTokens.append(token)
        }
    }

    private func handleWorkspaceVolumeChange() {
        let previousSelectionID = selectedSidebarID
        let previousSelection = selectedSidebarItem
        refreshSidebarItems(selectFirstWhenMissing: false)

        if let previousSelection,
           let sourceURL = sidebarSourceURL(for: previousSelection.kind),
           !isReachableDirectory(sourceURL) {
            clearToEmptyStateAfterSourceLoss()
            return
        }

        guard selectedSidebarID != previousSelectionID, let replacement = selectedSidebarItem else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadFiles(for: replacement.kind)
        }
    }

    private func clearToEmptyStateAfterSourceLoss() {
        selectedSidebarID = nil
        clearLoadedContentState(preserveSessionCaches: true)
        setStatusMessage(
            "External source was disconnected.",
            autoClearAfterSuccess: false
        )
    }

    private func sidebarSourceURL(for kind: SidebarKind) -> URL? {
        switch kind {
        case let .mountedVolume(url):
            return url
        case let .favorite(url):
            return url
        case let .folder(url):
            return url
        case .pictures, .desktop, .downloads:
            return nil
        }
    }

    func sidebarOpenURL(for kind: SidebarKind) -> URL? {
        switch kind {
        case .pictures:
            return picturesDirectoryURL()
        case .desktop:
            return desktopDirectoryURL()
        case .downloads:
            return downloadsDirectoryURL()
        case let .mountedVolume(url), let .favorite(url), let .folder(url):
            return url
        }
    }

    func picturesDirectoryURL() -> URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    func desktopDirectoryURL() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    func downloadsDirectoryURL() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private func enumerateImages(in folder: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        return urls.filter { url in
            guard Self.supportedImageExtensions.contains(url.pathExtension.lowercased()) else { return false }
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            return isRegular
        }
    }

    private func enumerateImagesRecursively(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [URL] = []

        for case let url as URL in enumerator {
            // Skip symbolic links to prevent potential cycles.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard Self.supportedImageExtensions.contains(ext) else { continue }
            files.append(url)
        }

        return files
    }

    private nonisolated static func countSupportedImages(in folder: URL) -> Int {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        } catch {
            logger.error("countSupportedImages: failed to enumerate \(folder.path): \(error)")
            return 0
        }

        return urls.reduce(into: 0) { total, url in
            guard supportedImageExtensions.contains(url.pathExtension.lowercased()) else { return }
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isRegular {
                total += 1
            }
        }
    }

    private func sidebarCountURL(for kind: SidebarKind) -> URL? {
        switch kind {
        case .pictures:
            return picturesDirectoryURL()
        case .desktop:
            return desktopDirectoryURL()
        case .downloads:
            return downloadsDirectoryURL()
        case let .mountedVolume(url), let .favorite(url), let .folder(url):
            return url
        }
    }

    func reconcileSidebarImageCountState() {
        let validIDs = Set(sidebarItems.map(\.id))

        sidebarImageCounts = sidebarImageCounts.filter { validIDs.contains($0.key) }

        let staleTaskIDs = sidebarImageCountTasks.keys.filter { !validIDs.contains($0) }
        for id in staleTaskIDs {
            sidebarImageCountTasks[id]?.cancel()
            sidebarImageCountTasks[id] = nil
        }
    }
}
