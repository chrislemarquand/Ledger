import AppKit
import ExifEditCore
import Foundation

private enum ExternalPhotoAppTarget {
    case lightroom
    case lightroomClassic

    var actionTitle: String {
        switch self {
        case .lightroom:
            return "Send to Lightroom"
        case .lightroomClassic:
            return "Send to Lightroom Classic"
        }
    }

    var unavailableMessage: String {
        switch self {
        case .lightroom:
            return "Lightroom isn’t available on this Mac."
        case .lightroomClassic:
            return "Lightroom Classic isn’t available on this Mac."
        }
    }

    var destinationName: String {
        switch self {
        case .lightroom:
            return "Lightroom"
        case .lightroomClassic:
            return "Lightroom Classic"
        }
    }

    var preferredBundleIdentifiers: [String] {
        switch self {
        case .lightroom:
            return [
                "com.adobe.lightroomcc",
            ]
        case .lightroomClassic:
            return [
                "com.adobe.lightroomclassiccc7",
            ]
        }
    }

    func matches(_ appURL: URL) -> Bool {
        let displayName = FileManager.default.displayName(atPath: appURL.path).lowercased()
        let bundle = Bundle(url: appURL)
        let bundleName = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)?.lowercased()
        let bundleID = bundle?.bundleIdentifier?.lowercased()

        func containsLightroom(_ value: String?) -> Bool {
            value?.contains("lightroom") == true
        }

        func containsClassic(_ value: String?) -> Bool {
            value?.contains("lightroom classic") == true || value?.contains("lightroomclassic") == true
        }

        switch self {
        case .lightroom:
            if let bundleID, preferredBundleIdentifiers.contains(bundleID) {
                return true
            }
            let hasLightroom = containsLightroom(displayName) || containsLightroom(bundleName) || containsLightroom(bundleID)
            let hasClassic = containsClassic(displayName) || containsClassic(bundleName) || containsClassic(bundleID)
            let looksAdobe = displayName.contains("adobe") || bundleName?.contains("adobe") == true || bundleID?.contains("com.adobe") == true
            return hasLightroom && !hasClassic && looksAdobe
        case .lightroomClassic:
            if let bundleID, preferredBundleIdentifiers.contains(bundleID) {
                return true
            }
            return containsClassic(displayName) || containsClassic(bundleName) || containsClassic(bundleID)
        }
    }

    var commonInstallPaths: [String] {
        switch self {
        case .lightroom:
            return [
                "/Applications/Adobe Lightroom CC/Adobe Lightroom.app",
                "/Applications/Adobe Lightroom/Adobe Lightroom.app",
                "/Applications/Lightroom.app",
            ]
        case .lightroomClassic:
            return [
                "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app",
                "/Applications/Lightroom Classic.app",
            ]
        }
    }
}

@MainActor
extension AppModel {
    func increaseGalleryZoom() {
        galleryGridLevel = max(galleryGridLevel - 1, Self.galleryColumnRange.lowerBound)
    }

    func decreaseGalleryZoom() {
        galleryGridLevel = min(galleryGridLevel + 1, Self.galleryColumnRange.upperBound)
    }

    func adjustGalleryGridLevel(by delta: Int) {
        guard delta != 0 else { return }
        let next = galleryGridLevel + delta
        galleryGridLevel = min(max(next, Self.galleryColumnRange.lowerBound), Self.galleryColumnRange.upperBound)
    }

    func openInDefaultApp(_ fileURL: URL) {
        let didOpen = NSWorkspace.shared.open(fileURL)
        if !didOpen {
            statusMessage = "Couldn’t open “\(fileURL.lastPathComponent)” in the default app."
        }
    }

    func openInDefaultApp(_ fileURLs: [URL]) {
        let uniqueURLs = Array(Set(fileURLs)).sorted { $0.path < $1.path }
        guard !uniqueURLs.isEmpty else { return }
        var failedCount = 0
        for fileURL in uniqueURLs {
            if !NSWorkspace.shared.open(fileURL) {
                failedCount += 1
            }
        }
        if failedCount > 0 {
            statusMessage = "Couldn’t open \(failedCount) images in the default app."
        }
    }

    private func defaultAppDisplayName(for fileURL: URL?) -> String {
        guard let fileURL,
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: fileURL)
        else {
            return "Default App"
        }

        if let bundle = Bundle(url: appURL) {
            if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !display.isEmpty {
                return display
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.isEmpty {
                return name
            }
        }
        return appURL.deletingPathExtension().lastPathComponent
    }

    private func openSelectedInDefaultApp() {
        guard let url = selectedFileURLs.sorted(by: { $0.path < $1.path }).first else {
            statusMessage = "Select an image to open in the default app."
            return
        }
        openInDefaultApp(url)
    }

    func sendToPhotos(_ fileURLs: [URL]) {
        let uniqueURLs = Array(Set(fileURLs)).sorted { $0.path < $1.path }
        guard !uniqueURLs.isEmpty else {
            statusMessage = "Select images to send to Photos."
            return
        }
        guard let photosAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") else {
            statusMessage = "Photos isn’t available on this Mac."
            return
        }

        let stagingDirectory: URL
        do {
            stagingDirectory = try makePhotosImportStagingDirectory(for: uniqueURLs)
        } catch {
            statusMessage = "Couldn’t prepare files for Photos import. \(error.localizedDescription)"
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(
            [stagingDirectory],
            withApplicationAt: photosAppURL,
            configuration: config
        ) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    if let staging = self.photosImportStagingDirectory {
                        try? FileManager.default.removeItem(at: staging)
                        self.photosImportStagingDirectory = nil
                    }
                    self.statusMessage = "Couldn’t open Photos import. \(error.localizedDescription)"
                    return
                }
                let suffix = uniqueURLs.count == 1 ? "" : "s"
                self.setStatusMessage("Opened Photos import review for \(uniqueURLs.count) image\(suffix).", autoClearAfterSuccess: true)
            }
        }
    }

    func sendToLightroom(_ fileURLs: [URL]) {
        sendToExternalPhotoApp(.lightroom, fileURLs: fileURLs)
    }

    func sendToLightroomClassic(_ fileURLs: [URL]) {
        sendToExternalPhotoApp(.lightroomClassic, fileURLs: fileURLs)
    }

    private func sendToExternalPhotoApp(_ target: ExternalPhotoAppTarget, fileURLs: [URL]) {
        let uniqueURLs = Array(Set(fileURLs)).sorted { $0.path < $1.path }
        guard !uniqueURLs.isEmpty else {
            statusMessage = "Select images to send to \(target.destinationName)."
            return
        }
        guard let appURL = resolveExternalPhotoAppURL(target, for: uniqueURLs) else {
            statusMessage = target.unavailableMessage
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(
            uniqueURLs,
            withApplicationAt: appURL,
            configuration: config
        ) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    let n = uniqueURLs.count
                    let images = n == 1 ? "1 image" : "\(n) images"
                    self.statusMessage = "Couldn’t send \(images) to \(target.destinationName). \(error.localizedDescription)"
                    return
                }
                let suffix = uniqueURLs.count == 1 ? "" : "s"
                self.setStatusMessage("Sent \(uniqueURLs.count) image\(suffix) to \(target.destinationName).", autoClearAfterSuccess: true)
            }
        }
    }

    private func makePhotosImportStagingDirectory(for fileURLs: [URL]) throws -> URL {
        if let existing = photosImportStagingDirectory {
            try? FileManager.default.removeItem(at: existing)
            photosImportStagingDirectory = nil
        }

        let stagingRootDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Ledger-Photos-Import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRootDirectory, withIntermediateDirectories: true)

        // Track immediately so cleanup works even if the copy loop throws.
        photosImportStagingDirectory = stagingRootDirectory

        let displayName = photosImportDisplayFolderName(for: fileURLs)
        let stagingDirectory = stagingRootDirectory.appendingPathComponent(displayName, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        var usedNames = Set<String>()
        for (index, sourceURL) in fileURLs.enumerated() {
            let fallback = "image-\(index + 1)\(sourceURL.pathExtension.isEmpty ? "" : ".\(sourceURL.pathExtension)")"
            let preferred = sourceURL.lastPathComponent.isEmpty ? fallback : sourceURL.lastPathComponent
            let uniqueName = uniqueImportFilename(preferred, usedNames: &usedNames)
            let destinationURL = stagingDirectory.appendingPathComponent(uniqueName, isDirectory: false)

            do {
                // Prefer hard links so Photos sees real files while avoiding full data copies
                // when source and staging paths share a filesystem.
                try FileManager.default.linkItem(at: sourceURL, to: destinationURL)
            } catch {
                // Fallback for cross-volume sources or link-restricted environments.
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
        }

        return stagingDirectory
    }

    private func uniqueImportFilename(_ preferred: String, usedNames: inout Set<String>) -> String {
        let base = (preferred as NSString).deletingPathExtension
        let ext = (preferred as NSString).pathExtension

        var candidate = preferred
        var index = 2
        while usedNames.contains(candidate) {
            let suffix = "-\(index)"
            candidate = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            index += 1
        }
        usedNames.insert(candidate)
        return candidate
    }

    private func photosImportDisplayFolderName(for fileURLs: [URL]) -> String {
        let parentFolders = Set(fileURLs.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        let rawName: String
        if parentFolders.count == 1, let path = parentFolders.first {
            let parentName = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
            rawName = parentName.isEmpty ? "Imported Images" : parentName
        } else {
            rawName = "Selected Images"
        }
        return sanitizedImportFolderName(rawName)
    }

    private func sanitizedImportFolderName(_ name: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\u{0}")
        let cleanedScalars = name.unicodeScalars.map { disallowed.contains($0) ? "-" : Character($0) }
        let cleaned = String(cleanedScalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Imported Images" : cleaned
    }

    func lightroomApplicationURL(for fileURLs: [URL]) -> URL? {
        resolveExternalPhotoAppURL(.lightroom, for: fileURLs)
    }

    func lightroomClassicApplicationURL(for fileURLs: [URL]) -> URL? {
        resolveExternalPhotoAppURL(.lightroomClassic, for: fileURLs)
    }

    private func resolveExternalPhotoAppURL(_ target: ExternalPhotoAppTarget, for fileURLs: [URL]) -> URL? {
        for path in target.commonInstallPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path), target.matches(url) {
                return url
            }
        }

        if let firstURL = fileURLs.first {
            let compatibleApps = NSWorkspace.shared.urlsForApplications(toOpen: firstURL)
            if let matched = compatibleApps.first(where: { appURL in
                let bundleID = Bundle(url: appURL)?.bundleIdentifier?.lowercased()
                return bundleID.map(target.preferredBundleIdentifiers.contains) == true
            }) {
                return matched
            }
            if let matched = compatibleApps.first(where: target.matches(_:)) {
                return matched
            }
        }
        return nil
    }

    func applyMetadataSelectionTitle(for targetURLs: [URL]) -> String {
        let normalized = Array(Set(targetURLs))
        guard !normalized.isEmpty else {
            return "Apply Changes to Selection"
        }
        let count = normalized.filter { hasAnyPendingChanges(for: $0) }.count
        guard count > 0 else { return "Apply Changes to Selection" }
        let suffix = count == 1 ? "" : "s"
        return "Apply Changes to \(count) File\(suffix)"
    }

    func fileActionState(for id: FileActionID, targetURLs: [URL]) -> FileActionState {
        let normalized = Array(Set(targetURLs)).sorted { $0.path < $1.path }
        let hasSelection = !normalized.isEmpty
        let hasPendingAny = normalized.contains { hasAnyPendingChanges(for: $0) }
        let hasRestorable = normalized.contains { hasRestorableBackup(for: $0) }
        let openAppName = defaultAppDisplayName(for: normalized.first)
        let hasLightroom: Bool = {
            guard hasSelection else { return false }
            return resolveExternalPhotoAppURL(.lightroom, for: normalized) != nil
        }()
        let hasLightroomClassic: Bool = {
            guard hasSelection else { return false }
            return resolveExternalPhotoAppURL(.lightroomClassic, for: normalized) != nil
        }()

        switch id {
        case .openInDefaultApp:
            return FileActionState(
                id: id,
                title: "Open in \(openAppName)",
                symbolName: "arrow.up.forward.app",
                isEnabled: hasSelection
            )
        case .sendToPhotos:
            return FileActionState(
                id: id,
                title: "Import in Photos…",
                symbolName: "photo.on.rectangle",
                isEnabled: hasSelection
            )
        case .sendToLightroom:
            return FileActionState(
                id: id,
                title: "Send to Lightroom…",
                symbolName: "square.and.arrow.up",
                isEnabled: hasLightroom
            )
        case .sendToLightroomClassic:
            return FileActionState(
                id: id,
                title: "Send to Lightroom Classic…",
                symbolName: "square.and.arrow.up",
                isEnabled: hasLightroomClassic
            )
        case .refreshMetadata:
            return FileActionState(
                id: id,
                title: "Refresh Metadata",
                symbolName: "arrow.clockwise",
                isEnabled: hasSelection
            )
        case .applyMetadataChanges:
            return FileActionState(
                id: id,
                title: "Apply Changes",
                symbolName: "square.and.arrow.down",
                isEnabled: hasPendingAny
            )
        case .clearMetadataChanges:
            return FileActionState(
                id: id,
                title: "Clear Changes",
                symbolName: "xmark.circle",
                isEnabled: hasPendingAny
            )
        case .restoreFromLastBackup:
            return FileActionState(
                id: id,
                title: "Restore from Backup",
                symbolName: "arrow.uturn.backward.circle",
                isEnabled: keepBackups && hasRestorable
            )
        case .batchRenameSelection:
            return FileActionState(
                id: id,
                title: "Batch Rename Selection…",
                symbolName: "pencil.and.list.clipboard",
                isEnabled: hasSelection
            )
        case .batchRenameFolder:
            return FileActionState(
                id: id,
                title: "Batch Rename Folder…",
                symbolName: "pencil.and.list.clipboard",
                isEnabled: !browserItems.isEmpty
            )
        }
    }

    func performFileAction(_ id: FileActionID, targetURLs: [URL]) {
        let normalized = Array(Set(targetURLs)).sorted { $0.path < $1.path }
        guard !normalized.isEmpty else { return }
        switch id {
        case .openInDefaultApp:
            openInDefaultApp(normalized)
        case .sendToPhotos:
            sendToPhotos(normalized)
        case .sendToLightroom:
            sendToLightroom(normalized)
        case .sendToLightroomClassic:
            sendToLightroomClassic(normalized)
        case .refreshMetadata:
            refreshMetadata(for: normalized)
        case .applyMetadataChanges:
            applyChanges(for: normalized)
        case .clearMetadataChanges:
            clearPendingEdits(for: normalized)
        case .restoreFromLastBackup:
            restoreLastOperation(for: normalized)
        case .batchRenameSelection:
            beginBatchRename(scope: .selection)
        case .batchRenameFolder:
            beginBatchRename(scope: .folder)
        }
    }

    func rotateLeft(fileURL: URL) {
        stageImageOperation(.rotateLeft90, for: fileURL)
    }

    func rotateRight(fileURL: URL) {
        stageImageOperation(.rotateLeft90, for: fileURL)
        stageImageOperation(.rotateLeft90, for: fileURL)
        stageImageOperation(.rotateLeft90, for: fileURL)
    }

    func flipHorizontal(fileURL: URL) {
        stageImageOperation(.flipHorizontal, for: fileURL)
    }

    func flipVertical(fileURL: URL) {
        stageImageOperation(.flipHorizontal, for: fileURL)
        stageImageOperation(.rotateLeft90, for: fileURL)
        stageImageOperation(.rotateLeft90, for: fileURL)
    }

    func quickLookSelection() {
        let visibleItems = filteredBrowserItems
        let orderedItems = visibleItems.map(\.url)

        guard !orderedItems.isEmpty else {
            statusMessage = "No images to preview."
            return
        }

        let focusedURL: URL?
        if let index = currentSelectionIndex(in: visibleItems), visibleItems.indices.contains(index) {
            focusedURL = visibleItems[index].url
        } else {
            focusedURL = orderedItems.first
        }
        QuickLookPreviewController.shared.present(urls: orderedItems, focusedURL: focusedURL, model: self)
    }

    func quickLookDisplayURL(for sourceURL: URL) -> URL {
        // Keep Quick Look on original file URLs for immediate, stable native behavior.
        removeStagedQuickLookPreviewFile(for: sourceURL)
        return sourceURL
    }

    func setQuickLookSourceFrame(for fileURL: URL, rectOnScreen: NSRect) {
        quickLookSourceFrames[fileURL] = rectOnScreen
    }

    func quickLookSourceFrame(for fileURL: URL) -> NSRect? {
        return quickLookSourceFrames[fileURL]
    }

    func setSelectionFromQuickLook(_ fileURL: URL) {
        let selection: Set<URL> = [fileURL]
        guard selectedFileURLs != selection else { return }
        selectedFileURLs = selection
        selectionAnchorURL = fileURL
        selectionFocusURL = fileURL
        selectionChanged()
    }

    func inspectorPreviewImage(for fileURL: URL) -> NSImage? {
        guard let image = inspectorPreviewImages[fileURL] else { return nil }
        markInspectorPreviewAsRecentlyUsed(fileURL)
        return displayImageForCurrentStagedState(image, fileURL: fileURL)
    }

    func isInspectorPreviewLoading(for fileURL: URL) -> Bool {
        inspectorPreviewInflight.contains(fileURL)
    }

    func ensureInspectorPreviewLoaded(for fileURL: URL) {
        loadInspectorPreview(for: fileURL, force: false)
    }

    func forceReloadInspectorPreview(for fileURL: URL) {
        loadInspectorPreview(for: fileURL, force: true)
    }

    func revealSelectionInFinder() {
        let urls = selectedFileURLs.sorted(by: { $0.path < $1.path })
        guard !urls.isEmpty else {
            statusMessage = "Select images to reveal in Finder."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func revealInFinder(_ fileURLs: [URL]) {
        let urls = Array(Set(fileURLs)).sorted(by: { $0.path < $1.path })
        guard !urls.isEmpty else {
            statusMessage = "Select images to reveal in Finder."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func canOpenSidebarItemInFinder(_ item: SidebarItem) -> Bool {
        sidebarOpenURL(for: item.kind) != nil
    }

    func openSidebarItemInFinder(_ item: SidebarItem) {
        guard let url = sidebarOpenURL(for: item.kind) else { return }
        if !NSWorkspace.shared.open(url) {
            statusMessage = "Couldn\u{2019}t open \u{201C}\(item.title)\u{201D} in Finder."
        }
    }

    func beginBatchRename(scope: BatchRenameScope) {
        let files: [URL]
        switch scope {
        case .selection:
            files = Array(selectedFileURLs)
        case .folder:
            files = browserItems.map(\.url)
        }
        guard !files.isEmpty else { return }

        guard !isFolderMetadataLoading else {
            statusMessage = "Metadata is still loading — try again in a moment."
            return
        }

        pendingBatchRenameMetadata = metadataByFile.filter { files.contains($0.key) }
        pendingBatchRenameScope = scope
    }

    func dismissBatchRenameSheet() {
        pendingBatchRenameScope = nil
        pendingBatchRenameMetadata = [:]
    }

    func previewBatchRename(pattern: RenamePattern, scope: BatchRenameScope) async -> [RenamePlanEntry] {
        let files = renameFilesForBatchRename(scope)
        let service = BatchRenameService()
        return await service.buildPlan(files: files, pattern: pattern, assumeSorted: true)
    }

    func previewBatchRenameAssessment(
        pattern: RenamePattern,
        scope: BatchRenameScope,
        metadata: [URL: FileMetadataSnapshot]
    ) async -> RenamePlanAssessment {
        let files = renameFilesForBatchRename(scope)
        let service = BatchRenameService()
        return await service.assessPlan(files: files, pattern: pattern, metadata: metadata, assumeSorted: true)
    }

    func stageBatchRename(operation: RenameOperation) async {
        guard !operation.files.isEmpty else { return }
        let files = operation.files.sorted {
            let cmp = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return $0.path < $1.path
        }
        let service = BatchRenameService()
        let assessment = await service.assessPlan(
            files: files,
            pattern: operation.pattern,
            metadata: metadataByFile,
            assumeSorted: true
        )
        guard assessment.issues.isEmpty else {
            let firstMessage = assessment.issues.first?.message ?? "Rename pattern is invalid."
            statusMessage = "Couldn’t prepare name changes. \(firstMessage)"
            return
        }
        let plan = assessment.entries
        let previousState = currentPendingEditState()
        var didChangePendingRenames = false
        for entry in plan {
            let proposed = entry.finalTargetURL.lastPathComponent
            if pendingRenameByFile[entry.sourceURL] != proposed {
                pendingRenameByFile[entry.sourceURL] = proposed
                didChangePendingRenames = true
            }
        }
        if didChangePendingRenames {
            // Reuse the existing browser invalidation signal so staged rename names/colors
            // appear immediately without waiting for unrelated metadata edits.
            stagedOpsDisplayToken &+= 1
            registerMetadataUndoIfNeeded(previous: previousState)
        }
        let n = plan.count
        let filesLabel = n == 1 ? "1 file" : "\(n) files"
        setStatusMessage("Prepared name changes for \(filesLabel). Ready to apply.", autoClearAfterSuccess: true)
        pendingBatchRenameScope = nil
    }

    func discardStagedRenames() {
        guard !pendingRenameByFile.isEmpty else { return }
        pendingRenameByFile.removeAll()
        stagedOpsDisplayToken &+= 1
        setStatusMessage("Cleared prepared name changes.", autoClearAfterSuccess: true)
    }

    func discardStagedRenames(for urls: [URL]) {
        var didChangePendingRenames = false
        for url in urls {
            if pendingRenameByFile.removeValue(forKey: url) != nil {
                didChangePendingRenames = true
            }
        }
        if didChangePendingRenames {
            stagedOpsDisplayToken &+= 1
        }
    }

    func renameFilesForBatchRename(_ scope: BatchRenameScope) -> [URL] {
        switch scope {
        case .selection:
            return Array(selectedFileURLs).sorted {
                let cmp = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.path < $1.path
            }
        case .folder:
            return browserItems.map(\.url).sorted {
                let cmp = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.path < $1.path
            }
        }
    }
}
