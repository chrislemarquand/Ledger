import AppKit
import LedgerCore
import Foundation

@MainActor
extension AppModel {
    func loadMetadataForSelection() async {
        let files = Array(selectedFileURLs)
        let selectionAtStart = Set(files)
        guard !files.isEmpty else {
            return
        }

        let filesToLoad = files.filter { fileURL in
            staleMetadataFiles.contains(fileURL) || metadataByFile[fileURL] == nil
        }
        guard !filesToLoad.isEmpty else {
            return
        }

        let signpostID = Signposts.metadata.makeSignpostID()
        let state = Signposts.metadata.beginInterval("SelectionMetadataLoad", id: signpostID)
        defer { Signposts.metadata.endInterval("SelectionMetadataLoad", state) }

        var map = metadataByFile

        for batchStart in stride(from: 0, to: filesToLoad.count, by: Self.selectionMetadataBatchSize) {
            let batchEnd = min(batchStart + Self.selectionMetadataBatchSize, filesToLoad.count)
            let batch = Array(filesToLoad[batchStart..<batchEnd])
            let snapshots = await readMetadataBatchResilient(batch)

            // Ignore stale async results after selection has changed.
            guard selectionAtStart == selectedFileURLs else { return }
            mergeMetadataSnapshots(snapshots, into: &map)
        }

        guard selectionAtStart == selectedFileURLs else { return }
        metadataByFile = map
        trimMetadataCacheIfNeeded()
        recalculateInspectorState()
    }

    func startFolderMetadataPrefetch(for files: [URL], batchSize: Int) {
        folderMetadataLoadTask?.cancel()
        folderMetadataLoadTask = nil

        let loadID = UUID()
        folderMetadataLoadID = loadID
        let effectiveBatchSize = max(1, batchSize)

        let filesToLoad = files.filter { fileURL in
            staleMetadataFiles.contains(fileURL) || metadataByFile[fileURL] == nil
        }

        guard !filesToLoad.isEmpty else {
            isFolderMetadataLoading = false
            folderMetadataLoadCompleted = 0
            folderMetadataLoadTotal = 0
            scheduleDeferredPreviewPreload(for: files)
            return
        }

        isFolderMetadataLoading = true
        folderMetadataLoadCompleted = 0
        folderMetadataLoadTotal = filesToLoad.count

        folderMetadataLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let signpostID = Signposts.metadata.makeSignpostID()
            let state = Signposts.metadata.beginInterval("FolderMetadataPrefetch", id: signpostID)
            defer { Signposts.metadata.endInterval("FolderMetadataPrefetch", state) }

            var map = self.metadataByFile

            for batchStart in stride(from: 0, to: filesToLoad.count, by: effectiveBatchSize) {
                if Task.isCancelled { return }
                guard self.folderMetadataLoadID == loadID else { return }
                await Task.yield()

                let batchEnd = min(batchStart + effectiveBatchSize, filesToLoad.count)
                let batch = Array(filesToLoad[batchStart..<batchEnd])
                let snapshots = await self.readMetadataBatchResilient(batch)

                if Task.isCancelled { return }
                guard self.folderMetadataLoadID == loadID else { return }

                self.mergeMetadataSnapshots(snapshots, into: &map)
                self.metadataByFile = map
                self.trimMetadataCacheIfNeeded()
                self.folderMetadataLoadCompleted = self.loadedMetadataCount(in: filesToLoad, from: map)
                let batchURLs = Set(batch)
                if !self.selectedFileURLs.isEmpty,
                   !self.selectedFileURLs.isDisjoint(with: batchURLs) {
                    self.recalculateInspectorState()
                }
            }

            guard !Task.isCancelled, self.folderMetadataLoadID == loadID else { return }
            self.isFolderMetadataLoading = false
            self.folderMetadataLoadTask = nil
            self.folderMetadataLoadCompleted = self.loadedMetadataCount(in: filesToLoad, from: map)
            if !self.selectedFileURLs.isEmpty {
                self.recalculateInspectorState()
            }
            self.scheduleDeferredPreviewPreload(for: files)
        }
    }

    private func loadedMetadataCount(in files: [URL], from map: [URL: FileMetadataSnapshot]) -> Int {
        files.reduce(into: 0) { count, fileURL in
            if map[fileURL] != nil {
                count += 1
            }
        }
    }

    /// v1.4 Phase 3.1: shared merge step for every site that folds freshly-read snapshots into
    /// `metadataByFile` — clears their stale/pending-commit markers and records a load
    /// timestamp for `trimMetadataCacheIfNeeded()`. Callers still own assigning the mutated
    /// `map` back to `metadataByFile` themselves (some accumulate across several batches
    /// before doing so, under a selection/load-ID guard) — this only prepares one batch.
    func mergeMetadataSnapshots(_ snapshots: [FileMetadataSnapshot], into map: inout [URL: FileMetadataSnapshot]) {
        let now = Date()
        for snapshot in snapshots {
            map[snapshot.fileURL] = snapshot
            staleMetadataFiles.remove(snapshot.fileURL)
            pendingCommitsByFile.removeValue(forKey: snapshot.fileURL)
            metadataLastLoadedAt[snapshot.fileURL] = now
        }
    }

    /// Evicts the oldest-loaded entries once `metadataByFile` exceeds
    /// `Self.maxMetadataCacheEntries`, protecting the current selection, the currently open
    /// folder's files, pending edits/image-ops/commits, and files mid-reload
    /// (`staleMetadataFiles`) — exactly the plan's "current selection, active folder, pending
    /// edits, undo/restore requirements, and in-flight operations" list. (Undo/redo itself
    /// doesn't need protecting here: `PendingEditState` is self-contained and doesn't read
    /// back through `metadataByFile`.)
    func trimMetadataCacheIfNeeded() {
        let excess = metadataByFile.count - Self.maxMetadataCacheEntries
        guard excess > 0 else { return }

        var protectedURLs = selectedFileURLs
        protectedURLs.formUnion(browserItems.map(\.url))
        protectedURLs.formUnion(pendingEditsByFile.keys)
        protectedURLs.formUnion(pendingImageOpsByFile.keys)
        protectedURLs.formUnion(pendingCommitsByFile.keys)
        protectedURLs.formUnion(staleMetadataFiles)

        let evictionCandidates = metadataByFile.keys.filter { !protectedURLs.contains($0) }
        guard !evictionCandidates.isEmpty else { return }

        let orderedByAge = evictionCandidates.sorted {
            (metadataLastLoadedAt[$0] ?? .distantPast) < (metadataLastLoadedAt[$1] ?? .distantPast)
        }
        for url in orderedByAge.prefix(excess) {
            metadataByFile.removeValue(forKey: url)
            metadataLastLoadedAt.removeValue(forKey: url)
        }
    }

    // v1.4 Phase 2.1: was `private`; now called from AppModel+FileLoading.swift's
    // loadFiles() too, when the whole-folder metadata prefetch is skipped
    // (hasVisibleMetadataColumnDemand is false) — that prefetch used to be the
    // only thing that chained into preview preload, including on its
    // "nothing to load" early-return path, so skipping it entirely would have
    // silently dropped preview preload for every folder with no metadata
    // column/subtitle enabled.
    func scheduleDeferredPreviewPreload(for files: [URL]) {
        deferredPreviewPreloadTask?.cancel()
        deferredPreviewPreloadTask = nil
        let filesSnapshot = files
        deferredPreviewPreloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: Self.previewBulkStartDelayNanoseconds) } catch { return }
            self.startPreviewPreload(for: filesSnapshot)
        }
    }

    private func startPreviewPreload(for files: [URL]) {
        previewPreloadTask?.cancel()
        previewPreloadTask = nil
        deferredPreviewPreloadTask?.cancel()
        deferredPreviewPreloadTask = nil
        let preloadID = UUID()
        previewPreloadID = preloadID
        let preloadCandidates = previewPreloadCandidates(from: files)

        var filesToPreload: [URL] = []
        for fileURL in preloadCandidates {
            if ThumbnailService.cachedImage(for: fileURL, minRenderedSide: Self.inspectorPreviewTargetSide) != nil {
                // Already have an adequate-quality image; ensure it's wired up as a preview.
                if let cached = ThumbnailPipeline.cachedImage(for: fileURL, minRenderedSide: Self.inspectorPreviewTargetSide) {
                    storeInspectorPreview(cached, for: fileURL, renderedSide: renderedSide(for: cached))
                }
                continue
            }
            // Show a low-res placeholder immediately if anything is cached.
            if inspectorPreviewImages[fileURL] == nil,
               let cachedLowRes = ThumbnailPipeline.cachedImage(for: fileURL, minRenderedSide: 1) {
                storeInspectorPreview(cachedLowRes, for: fileURL, renderedSide: renderedSide(for: cachedLowRes))
            }
            filesToPreload.append(fileURL)
        }

        guard !filesToPreload.isEmpty else {
            isPreviewPreloading = false
            checkQuiescenceIfNeeded()
            return
        }

        isPreviewPreloading = true

        previewPreloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for fileURL in filesToPreload {
                if Task.isCancelled { return }
                guard self.previewPreloadID == preloadID else { return }
                await Task.yield()

                self.inspectorPreviewInflight.insert(fileURL)
                let image = await Self.requestInspectorPreviewFromThumbnailService(
                    for: fileURL,
                    priority: .utility,
                    forceRefresh: false
                )
                // v1.4 architecture-outcome review (2026-09-27, R3): the fetch above runs on a
                // detached task that does not inherit this task's cancellation, so re-check here
                // before publishing — a preload superseded mid-fetch (a newer selection bumped
                // previewPreloadID) must not overwrite state a newer preload already owns.
                guard !Task.isCancelled, self.previewPreloadID == preloadID else { return }
                if let image {
                    self.storeInspectorPreview(
                        image,
                        for: fileURL,
                        renderedSide: max(Self.inspectorPreviewFullSide, self.renderedSide(for: image))
                    )
                }
                self.inspectorPreviewInflight.remove(fileURL)
                self.inspectorPreviewTasksByURL[fileURL] = nil
            }

            guard !Task.isCancelled, self.previewPreloadID == preloadID else { return }
            self.previewPreloadTask = nil
            self.isPreviewPreloading = false
            self.setStatusMessage("Metadata loaded", autoClearAfterSuccess: true)
            self.checkQuiescenceIfNeeded()
        }
    }

    private static func requestInspectorPreviewFromThumbnailService(
        for fileURL: URL,
        priority: TaskPriority,
        forceRefresh: Bool
    ) async -> NSImage? {
        await Task.detached(priority: priority) {
            await ThumbnailService.request(
                url: fileURL,
                requiredSide: Self.inspectorPreviewFullSide,
                forceRefresh: forceRefresh
            )
        }.value
    }

    struct MetadataReadTimeoutError: LocalizedError {
        let fileCount: Int

        var errorDescription: String? {
            "Timed out reading metadata for \(fileCount == 1 ? "1 file" : "\(fileCount) files")."
        }
    }

    private func readMetadataWithTimeout(_ files: [URL], timeoutNanoseconds: UInt64) async throws -> [FileMetadataSnapshot] {
        try await withThrowingTaskGroup(of: [FileMetadataSnapshot].self) { group in
            group.addTask {
                try await self.engine.readMetadata(files: files)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw MetadataReadTimeoutError(fileCount: files.count)
            }

            guard let first = try await group.next() else {
                group.cancelAll()
                return []
            }
            group.cancelAll()
            return first
        }
    }

    func readMetadataBatchResilient(_ files: [URL]) async -> [FileMetadataSnapshot] {
        // iCloud placeholders aren't on disk yet — running ExifTool against one forces
        // fileproviderd to materialise the whole file, which reads as a silent hang on large
        // scans. Skip them entirely; the inspector shows a "Not Downloaded" state instead.
        let readableFiles = files.filter { cloudStateByURL[$0]?.isPlaceholder != true }
        guard !readableFiles.isEmpty else { return [] }
        do {
            return try await readMetadataWithTimeout(
                readableFiles,
                timeoutNanoseconds: Self.metadataReadTimeoutNanoseconds
            )
        } catch is MetadataReadTimeoutError {
            // Do not immediately re-enter per-file reads after a timeout; that can queue behind
            // the same stuck operation path and stall progress updates.
            return []
        } catch {
            var partial: [FileMetadataSnapshot] = []
            for file in readableFiles {
                if Task.isCancelled { break }
                if let one = try? await readMetadataWithTimeout(
                    [file],
                    timeoutNanoseconds: Self.metadataReadTimeoutNanoseconds
                ).first {
                    partial.append(one)
                }
            }
            return partial
        }
    }

    func selectionChanged() {
        beginQuiescenceTracking(reason: "SelectionSweep")
        let selection = selectedFileURLs
        cancelStaleInspectorPreviewTasks(keeping: selection)

        previewPreloadTask?.cancel()
        previewPreloadTask = nil
        previewPreloadID = UUID()
        isPreviewPreloading = false

        if let primary = primarySelectionURL {
            inspectorPreviewTasksByURL[primary]?.cancel()
            inspectorPreviewTasksByURL[primary] = nil
            inspectorPreviewInflight.remove(primary)
            loadInspectorPreview(for: primary, force: false, priority: .userInitiated)
        }

        scheduleDeferredPreviewPreload(for: browserItems.map(\.url))

        // Recompute immediately so UI doesn't show stale single-file values while async load runs.
        // Force a refresh even when canonical values happen to be unchanged, so selection/header state updates.
        recalculateInspectorState(forceNotify: true)
        let needsMetadataLoad = selection.contains { staleMetadataFiles.contains($0) || metadataByFile[$0] == nil }
        guard needsMetadataLoad else {
            checkQuiescenceIfNeeded()
            return
        }
        selectionMetadataLoadTask?.cancel()
        let generationID = UUID()
        selectionMetadataLoadGenerationID = generationID
        selectionMetadataLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // Only the still-current generation may clear the property — an old,
                // superseded task's cleanup running after a newer one has already
                // started must not clobber the newer task's reference.
                if self.selectionMetadataLoadGenerationID == generationID {
                    self.selectionMetadataLoadTask = nil
                }
                self.checkQuiescenceIfNeeded()
            }
            do { try await Task.sleep(nanoseconds: Self.selectionMetadataDebounceNanoseconds) } catch { return }
            await self.loadMetadataForSelection()
        }
    }

    func invalidateAllBrowserThumbnails() {
        browserThumbnailInvalidatedURLs = []
        browserThumbnailInvalidationToken = UUID()
    }

    func invalidateBrowserThumbnails(for fileURLs: [URL]) {
        browserThumbnailInvalidatedURLs = Set(fileURLs)
        browserThumbnailInvalidationToken = UUID()
    }

    func loadInspectorPreview(for fileURL: URL, force: Bool, priority: TaskPriority? = nil) {
        let requestPriority = priority ?? (selectedFileURLs.contains(fileURL) ? .userInitiated : .utility)
        // Already have a high-quality image — nothing to do.
        if !force, ThumbnailService.cachedImage(for: fileURL, minRenderedSide: Self.inspectorPreviewTargetSide) != nil,
           inspectorPreviewImages[fileURL] != nil {
            markInspectorPreviewAsRecentlyUsed(fileURL)
            return
        }
        // Adequate-quality image is in the cache — wire it up and return.
        if !force,
           let cached = ThumbnailPipeline.cachedImage(for: fileURL, minRenderedSide: Self.inspectorPreviewTargetSide) {
            storeInspectorPreview(cached, for: fileURL, renderedSide: renderedSide(for: cached))
            return
        }
        // Show a low-res placeholder immediately while the full-size request runs.
        if !force, inspectorPreviewImages[fileURL] == nil,
           let cachedLowRes = ThumbnailPipeline.cachedImage(for: fileURL, minRenderedSide: 1) {
            storeInspectorPreview(cachedLowRes, for: fileURL, renderedSide: renderedSide(for: cachedLowRes))
        }

        if force {
            inspectorPreviewTasksByURL[fileURL]?.cancel()
            inspectorPreviewTasksByURL[fileURL] = nil
            inspectorPreviewInflight.remove(fileURL)
            inspectorPreviewImages[fileURL] = nil
        }
        guard !inspectorPreviewInflight.contains(fileURL) else { return }
        inspectorPreviewInflight.insert(fileURL)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let image = await Self.requestInspectorPreviewFromThumbnailService(
                for: fileURL,
                priority: requestPriority,
                forceRefresh: force
            )
            // v1.4 architecture-outcome review (2026-09-27, R3): the fetch above runs on a
            // detached task that does not inherit this task's cancellation, so a force-refresh
            // that cancelled this task (line above, on supersession) can still resume here after
            // the underlying fetch completes. Bail out without touching inflight/tasksByURL —
            // the newer request that cancelled us already re-initialised both for this URL.
            guard !Task.isCancelled else { return }
            if let image {
                self.storeInspectorPreview(
                    image,
                    for: fileURL,
                    renderedSide: max(Self.inspectorPreviewFullSide, self.renderedSide(for: image))
                )
            }
            self.inspectorPreviewInflight.remove(fileURL)
            self.inspectorPreviewTasksByURL[fileURL] = nil
        }
        inspectorPreviewTasksByURL[fileURL] = task
    }

    func invalidateInspectorPreviews(for fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        let targets = Set(fileURLs)
        for fileURL in targets {
            inspectorPreviewTasksByURL[fileURL]?.cancel()
            inspectorPreviewTasksByURL[fileURL] = nil
            inspectorPreviewInflight.remove(fileURL)
            inspectorPreviewImages[fileURL] = nil
        }
        inspectorPreviewRecency.removeAll(where: { targets.contains($0) })
    }

    private func makeStagedQuickLookPreviewFile(for sourceURL: URL) throws -> URL {
        let previewsDirectory = AppBrand.currentSupportDirectoryURL()
            .appendingPathComponent("QuickLookPreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: previewsDirectory, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        let name = "\(UUID().uuidString).\(ext)"
        return previewsDirectory.appendingPathComponent(name, isDirectory: false)
    }

    func removeStagedQuickLookPreviewFile(for sourceURL: URL) {
        stagedQuickLookPreviewGenerationInFlight.remove(sourceURL)
        guard let previewURL = stagedQuickLookPreviewFiles.removeValue(forKey: sourceURL) else { return }
        try? FileManager.default.removeItem(at: previewURL)
    }

    func removeAllStagedQuickLookPreviewFiles() {
        stagedQuickLookPreviewGenerationInFlight.removeAll()
        for sourceURL in Array(stagedQuickLookPreviewFiles.keys) {
            removeStagedQuickLookPreviewFile(for: sourceURL)
        }
    }

    private func storeInspectorPreview(_ image: NSImage, for fileURL: URL, renderedSide: CGFloat) {
        inspectorPreviewImages[fileURL] = image
        ThumbnailService.storeCachedImage(image, for: fileURL, renderedSide: max(1, renderedSide))
        markInspectorPreviewAsRecentlyUsed(fileURL)
        trimInspectorPreviewCacheIfNeeded()
    }

    func renderedSide(for image: NSImage) -> CGFloat {
        max(image.size.width, image.size.height)
    }

    static func performBrandMigrationsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppBrand.migrationSentinelKey) else { return }
        migrateLegacySupportDirectoryIfNeeded()
        defaults.set(true, forKey: AppBrand.migrationSentinelKey)
    }

    private static func userDefaultsKeyCandidates(for key: String) -> [String] {
        [key] + legacyUserDefaultsPrefixes.map { "\($0).\(key)" }
    }

    static func firstUserDefaultsValue<T>(for key: String, defaults: UserDefaults, as type: T.Type) -> T? {
        for candidate in userDefaultsKeyCandidates(for: key) {
            if let value = defaults.object(forKey: candidate) as? T {
                return value
            }
        }
        return nil
    }

    private static func migrateLegacySupportDirectoryIfNeeded() {
        let fileManager = FileManager.default
        let current = AppBrand.currentSupportDirectoryURL(fileManager: fileManager)

        guard !fileManager.fileExists(atPath: current.path) else {
            logger.info("Brand migration: support directory already exists at \(current.path, privacy: .public)")
            return
        }
        for legacy in AppBrand.legacySupportDirectoryURLs(fileManager: fileManager) {
            guard fileManager.fileExists(atPath: legacy.path) else { continue }
            do {
                try fileManager.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: legacy, to: current)
                logger.info("Brand migration: moved support directory from \(legacy.path, privacy: .public) to \(current.path, privacy: .public)")
            } catch {
                // Preserve backward compatibility by leaving legacy data in place if move fails.
                logger.error("Brand migration: failed to move support directory from \(legacy.path, privacy: .public) to \(current.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            break
        }
    }

    func markInspectorPreviewAsRecentlyUsed(_ fileURL: URL) {
        if let index = inspectorPreviewRecency.firstIndex(of: fileURL) {
            inspectorPreviewRecency.remove(at: index)
        }
        inspectorPreviewRecency.append(fileURL)
    }

    private func trimInspectorPreviewCacheIfNeeded() {
        let excessCount = inspectorPreviewRecency.count - Self.maxInspectorPreviewCacheEntries
        guard excessCount > 0 else { return }
        let evicted = inspectorPreviewRecency.prefix(excessCount)
        for fileURL in evicted {
            inspectorPreviewImages[fileURL] = nil
            inspectorPreviewInflight.remove(fileURL)
        }
        inspectorPreviewRecency.removeFirst(excessCount)
    }

    func scheduleBackgroundWarm(forSelectionID id: String, files: [URL]) {
        guard backgroundWarmTasksBySelectionID[id] == nil else { return }
        let uniqueFiles = Array(Set(files))
        guard !uniqueFiles.isEmpty else { return }

        // v1.4 Phase 2.2: only the most-recently-left folder's warm work is worth
        // keeping. Without this, a quick A -> B -> C navigation left A's warm task
        // running for its full duration with no further guard against it — competing
        // with C's now-foreground metadata/preview work for ExifTool and decode
        // capacity even though A was obsolete the moment B was left too.
        for (staleID, task) in backgroundWarmTasksBySelectionID {
            task.cancel()
            backgroundWarmTasksBySelectionID[staleID] = nil
        }

        backgroundWarmTasksBySelectionID[id] = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.backgroundWarmTasksBySelectionID[id] = nil
                self.checkQuiescenceIfNeeded()
            }
            await self.warmCachesInBackground(files: uniqueFiles)
        }
    }

    private func warmCachesInBackground(files: [URL]) async {
        let signpostID = Signposts.metadata.makeSignpostID()
        let state = Signposts.metadata.beginInterval("BackgroundWarm", id: signpostID)
        defer { Signposts.metadata.endInterval("BackgroundWarm", state) }

        // Never contend with active foreground work.
        guard !isFolderMetadataLoading, !isPreviewPreloading else { return }
        do { try await Task.sleep(nanoseconds: Self.previewBulkStartDelayNanoseconds) } catch { return }
        guard !isFolderMetadataLoading, !isPreviewPreloading else { return }
        let warmCandidates = previewPreloadCandidates(from: files)
        guard !warmCandidates.isEmpty else { return }

        let filesNeedingMetadata = warmCandidates.filter { fileURL in
            staleMetadataFiles.contains(fileURL) || metadataByFile[fileURL] == nil
        }
        if !filesNeedingMetadata.isEmpty {
            var map = metadataByFile
            for fileURL in filesNeedingMetadata {
                if Task.isCancelled { return }
                // Foreground work starting mid-run (e.g. the user landed back on this
                // folder, or moved to another one that now needs its own prefetch)
                // takes priority — yield the rest of this speculative pass.
                if isFolderMetadataLoading || isPreviewPreloading { return }
                await Task.yield()

                let snapshots = await readMetadataBatchResilient([fileURL])
                if Task.isCancelled { return }

                mergeMetadataSnapshots(snapshots, into: &map)
            }
            metadataByFile = map
            trimMetadataCacheIfNeeded()
        }

        let filesNeedingPreview = warmCandidates.filter {
            ThumbnailService.cachedImage(for: $0, minRenderedSide: Self.inspectorPreviewTargetSide) == nil
        }
        for fileURL in filesNeedingPreview {
            if Task.isCancelled { return }
            if isFolderMetadataLoading || isPreviewPreloading { return }
            await Task.yield()

            if ThumbnailService.cachedImage(for: fileURL, minRenderedSide: Self.inspectorPreviewTargetSide) != nil { continue }
            if let cached = ThumbnailPipeline.cachedImage(for: fileURL, minRenderedSide: Self.inspectorPreviewTargetSide) {
                storeInspectorPreview(
                    cached,
                    for: fileURL,
                    renderedSide: max(Self.inspectorPreviewTargetSide, renderedSide(for: cached))
                )
                continue
            }
            inspectorPreviewInflight.insert(fileURL)
            let image = await Self.requestInspectorPreviewFromThumbnailService(
                for: fileURL,
                priority: .utility,
                forceRefresh: false
            )
            // v1.4 architecture-outcome review (2026-09-27, R3): re-check after the detached
            // fetch (which does not inherit this task's cancellation) before publishing, so a
            // supersession that happened mid-fetch isn't silently overwritten.
            guard !Task.isCancelled, !isFolderMetadataLoading, !isPreviewPreloading else { return }
            if let image {
                storeInspectorPreview(
                    image,
                    for: fileURL,
                    renderedSide: max(Self.inspectorPreviewFullSide, renderedSide(for: image))
                )
            }
            inspectorPreviewInflight.remove(fileURL)
        }
    }

    private func previewPreloadCandidates(from files: [URL]) -> [URL] {
        guard !files.isEmpty else { return [] }
        guard !selectedFileURLs.isEmpty else { return [] }

        let browserOrder = browserItems.map(\.url)
        let orderedUniverse = browserOrder.isEmpty ? files : browserOrder
        guard !orderedUniverse.isEmpty else { return [] }

        let indexByURL = Dictionary(uniqueKeysWithValues: orderedUniverse.enumerated().map { ($1, $0) })
        var candidateIndices: Set<Int> = []
        let radius = Self.previewPreloadNeighborRadius

        for selectedURL in selectedFileURLs {
            guard let center = indexByURL[selectedURL] else { continue }
            let lower = max(0, center - radius)
            let upper = min(orderedUniverse.count - 1, center + radius)
            for i in lower...upper {
                candidateIndices.insert(i)
            }
        }

        guard !candidateIndices.isEmpty else { return [] }

        let selectedCountCap = max(Self.maxPreviewPreloadCandidates, selectedFileURLs.count)
        let orderedByDistance: [Int]
        if let primary = primarySelectionURL, let primaryIndex = indexByURL[primary] {
            orderedByDistance = candidateIndices.sorted { lhs, rhs in
                let leftDistance = abs(lhs - primaryIndex)
                let rightDistance = abs(rhs - primaryIndex)
                if leftDistance != rightDistance { return leftDistance < rightDistance }
                return lhs < rhs
            }
        } else {
            orderedByDistance = candidateIndices.sorted()
        }

        let capped = Array(orderedByDistance.prefix(selectedCountCap)).sorted()
        return capped.map { orderedUniverse[$0] }
    }

    private func cancelStaleInspectorPreviewTasks(keeping keepURLs: Set<URL>) {
        let staleURLs = inspectorPreviewTasksByURL.keys.filter { !keepURLs.contains($0) }
        guard !staleURLs.isEmpty else { return }
        for fileURL in staleURLs {
            inspectorPreviewTasksByURL[fileURL]?.cancel()
            inspectorPreviewTasksByURL[fileURL] = nil
            inspectorPreviewInflight.remove(fileURL)
        }
    }
}
