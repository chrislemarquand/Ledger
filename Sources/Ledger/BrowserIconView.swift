@preconcurrency import AppKit
import ExifEditCore
import SharedUI

@MainActor
final class BrowserIconViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewPrefetching {
    private var model: AppModel
    private var items: [AppModel.BrowserItem]

    private let scrollView = NSScrollView()
    private let collectionView = SharedGalleryCollectionView()
    private var layout = SharedGalleryLayout(
        showsSupplementaryDetail: true,
        supplementaryDetailHeight: UIMetrics.Gallery.titleGap + 22
    )

    private var isApplyingProgrammaticSelection = false
    private var contextMenuTargetURLs: [URL] = []
    private var lastRenderedURLs: [URL] = []
    private var lastRenderedSelected: Set<URL> = []
    private var lastRenderedPending: Set<URL> = []
    private var lastRenderedCloudStates: [CloudFileState] = []
    private var lastRenderedPrimarySelectionURL: URL?
    private var lastStagedOpsDisplayToken: UInt64 = 0
    private var lastThumbnailInvalidationToken = UUID()
    private var pendingThumbnailRefreshURLs: Set<URL> = []
    private var isRenderingState = false
    private var zoomRestoreToken = 0
    private let pinchZoomAccumulator = PinchZoomAccumulator()
    private var viewModeObserver: NSObjectProtocol?
    private var selectionAppearanceObserver: GallerySelectionAppearanceObserver?
    private var lastRenderedViewMode: AppModel.BrowserViewMode?
    private var lastRenderedSubtitleColumnID: String?
    private var lastRenderedMetadataCount = 0
    private var lastRenderedItemsForSubtitle: [AppModel.BrowserItem] = []

    init(model: AppModel, items: [AppModel.BrowserItem]) {
        self.model = model
        self.items = items
        self.lastThumbnailInvalidationToken = model.browserThumbnailInvalidationToken
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureGallery()
        viewModeObserver = NotificationCenter.default.addObserver(
            forName: .browserDidSwitchViewMode,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleViewModeSwitch()
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if selectionAppearanceObserver == nil {
            selectionAppearanceObserver = GallerySelectionAppearanceObserver(hostView: view) { [weak self] in
                self?.refreshSelectionAppearanceForVisibleCells()
            }
        }
        selectionAppearanceObserver?.start()
        refreshSelectionAppearanceForVisibleCells()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        for indexPath in collectionView.indexPathsForVisibleItems() {
            (collectionView.item(at: indexPath) as? AppKitIconItem)?.cancelThumbnailRequest()
        }
        if let viewModeObserver {
            NotificationCenter.default.removeObserver(viewModeObserver)
            self.viewModeObserver = nil
        }
        selectionAppearanceObserver?.stop()
    }

    func update(model: AppModel, items: [AppModel.BrowserItem]) {
        self.model = model
        self.items = items
        guard model.browserViewMode == .icon else {
            // Keep transition state accurate while inactive so the next switch
            // back to gallery can trigger a deterministic refresh pass.
            lastRenderedViewMode = model.browserViewMode
            return
        }
        renderState()
    }

    private func handleViewModeSwitch() {
        guard model.browserViewMode == .icon else {
            lastRenderedViewMode = model.browserViewMode
            return
        }
        renderState()
    }

    private func refreshSelectionAppearanceForVisibleCells() {
        let visibleURLs = Set(items.map(\.url))
        let selectedURLs = model.selectedFileURLs.intersection(visibleURLs)
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard indexPath.item >= 0, indexPath.item < items.count else { continue }
            guard let cell = collectionView.item(at: indexPath) as? AppKitIconItem else { continue }
            let item = items[indexPath.item]
            cell.applySelection(isSelected: selectedURLs.contains(item.url))
        }
    }

    private func configureGallery() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        collectionView.translatesAutoresizingMaskIntoConstraints = true
        collectionView.frame = NSRect(origin: .zero, size: scrollView.contentView.bounds.size)
        collectionView.autoresizingMask = [.width]
        collectionView.backgroundColors = [.clear]
        collectionView.collectionViewLayout = layout.collectionViewLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(AppKitIconItem.self, forItemWithIdentifier: AppKitIconItem.reuseIdentifier)

        collectionView.onBackgroundClick = { [weak self] in
            self?.model.clearSelection()
        }
        collectionView.allowsShiftExtendedMovement = false
        collectionView.handlesActivateOnReturn = true
        collectionView.onMoveSelection = { [weak self] direction, extendingSelection in
            self?.model.moveSelectionInIconGrid(direction: direction, extendingSelection: extendingSelection)
        }
        collectionView.onDoubleClick = { [weak self] indexPath in
            guard let self, indexPath.item >= 0, indexPath.item < self.items.count else { return }
            let url = self.items[indexPath.item].url
            self.model.setSelectionFromList([url], focusedURL: url)
            self.model.openInDefaultApp(url)
        }
        collectionView.onModifiedItemClick = { [weak self] indexPath, modifiers in
            self?.handleModifiedItemClick(indexPath: indexPath, modifiers: modifiers)
        }
        collectionView.onActivateSelection = { [weak self] in
            self?.focusInspectorFromBrowser()
        }
        collectionView.contextMenuProvider = { [weak self] indexPath in
            self?.menuForItem(at: indexPath)
        }
        collectionView.onFirstResponderStatusChanged = { [weak self] in
            self?.refreshSelectionAppearanceForVisibleCells()
        }
        collectionView.addGestureRecognizer(
            NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnification(_:)))
        )

        scrollView.documentView = collectionView
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func focusInspectorFromBrowser() {
        guard model.browserViewMode == .icon else { return }
        guard !model.selectedFileURLs.isEmpty else { return }
        _ = NSApp.sendAction(
            #selector(NativeThreePaneSplitViewController.focusInspectorEntryAction(_:)),
            to: nil,
            from: self
        )
    }

    private func handleModifiedItemClick(indexPath: IndexPath, modifiers: NSEvent.ModifierFlags) {
        guard indexPath.item >= 0, indexPath.item < items.count else { return }
        model.selectFile(items[indexPath.item].url, modifiers: modifiers, in: items)
        let selectedIndexPaths = Set(
            items.enumerated().compactMap { index, item -> IndexPath? in
                model.selectedFileURLs.contains(item.url) ? IndexPath(item: index, section: 0) : nil
            }
        )
        isApplyingProgrammaticSelection = true
        collectionView.selectionIndexPaths = selectedIndexPaths
        isApplyingProgrammaticSelection = false
        updateQuickLookArtifacts()
    }

    func focusGalleryForKeyboardNavigation() {
        guard model.browserViewMode == .icon else { return }
        guard let window = view.window else { return }
        window.makeFirstResponder(collectionView)
    }

    func clearVisualSelection() {
        isApplyingProgrammaticSelection = true
        collectionView.selectionIndexPaths = []
        isApplyingProgrammaticSelection = false
    }

    private func scrollSelectionIntoView() {
        guard model.browserViewMode == .icon else { return }
        guard let primary = model.primarySelectionURL,
              let row = items.firstIndex(where: { $0.url == primary }) else { return }
        let indexPath = IndexPath(item: row, section: 0)
        // Defer one run loop so layout is committed after the view becomes visible.
        // Call layoutSubtreeIfNeeded on the scrollView (not the collectionView) so
        // the clip view is sized before item frames are queried — necessary on the
        // list→gallery switch where the collection view's bounds come from its parent.
        // Use scrollRectToVisible rather than scrollToItems (the latter silently
        // no-ops if the layout pass has not been committed yet).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.browserViewMode == .icon else { return }
            self.scrollView.layoutSubtreeIfNeeded()
            guard let attrs = self.collectionView.collectionViewLayout?.layoutAttributesForItem(at: indexPath) else { return }
            self.collectionView.scrollToVisible(attrs.frame)
        }
    }

    private func renderState() {
        guard !isRenderingState else { return }
        isRenderingState = true
        defer { isRenderingState = false }

        let currentURLs = items.map(\.url)
        let selectedURLs = model.selectedFileURLs.intersection(Set(currentURLs))
        let pendingURLs = Set(currentURLs.filter { model.hasPendingEdits(for: $0) })

        let listChanged = currentURLs != lastRenderedURLs
        let targetColumnCount = max(model.galleryColumnCount, 1)
        let columnsChanged = layout.columnCount != targetColumnCount
        let selectionChanged = selectedURLs != lastRenderedSelected
        let pendingChanged = pendingURLs != lastRenderedPending
        let cloudStates = items.map(\.cloudState)
        let cloudStatesChanged = cloudStates != lastRenderedCloudStates
        let primaryChanged = model.primarySelectionURL != lastRenderedPrimarySelectionURL
        let stagedOpsChanged = lastStagedOpsDisplayToken != model.stagedOpsDisplayToken
        if stagedOpsChanged { lastStagedOpsDisplayToken = model.stagedOpsDisplayToken }
        let subtitleColumnID = model.iconSubtitleColumnID
        // Subtitle text depends on data that loads lazily and asynchronously after the items
        // list is first published: exiftool fields arrive via the deferred batch prefetch
        // (tracked by metadataByFile's count), while file-system fields — size, created/modified
        // dates, kind — arrive via BrowserItem hydration, which republishes `items` with the
        // same URLs (so `listChanged` never fires) but different attribute values. Neither is
        // covered by the other change flags above, so without this a cell stuck showing "—"
        // only ever refreshes if some unrelated flag (selection, pending, etc.) also happens to
        // change. Only relevant while a subtitle is actually shown; still keep trackers current
        // either way.
        let metadataCount = model.metadataByFile.count
        let itemsContentChanged = items != lastRenderedItemsForSubtitle
        let metadataChanged = subtitleColumnID != nil && (metadataCount != lastRenderedMetadataCount || itemsContentChanged)
        lastRenderedMetadataCount = metadataCount
        lastRenderedItemsForSubtitle = items
        let subtitleChanged = subtitleColumnID != lastRenderedSubtitleColumnID
        if subtitleChanged {
            lastRenderedSubtitleColumnID = subtitleColumnID
            let hasSubtitle = subtitleColumnID != nil
            layout.supplementaryDetailHeight = UIMetrics.Gallery.titleGap + 22
                + (hasSubtitle ? UIMetrics.Gallery.subtitleGap + UIMetrics.Gallery.subtitleHeight : 0)
            layout.invalidateLayout()
        }

        if columnsChanged {
            applyColumnCount(targetColumnCount, animated: true)
        }

        // Must run before the thumbnail-invalidation block below: reloadData() is what
        // tells the collection view about a new item count. Computing index paths for a
        // targeted reloadItems(at:) against the already-updated `items` array while the
        // collection view still holds the old count hands AppKit out-of-range index paths,
        // which aborts inside _NSCollectionViewCore's item-animation bookkeeping.
        if listChanged {
            collectionView.reloadData()
            lastRenderedURLs = currentURLs
            Signposts.browserReload.emitEvent(
                "IconReload",
                "trigger=list kind=full count=\(currentURLs.count, privacy: .public)"
            )
        }

        if lastThumbnailInvalidationToken != model.browserThumbnailInvalidationToken {
            lastThumbnailInvalidationToken = model.browserThumbnailInvalidationToken
            let invalidated = model.browserThumbnailInvalidatedURLs
            if invalidated.isEmpty {
                ThumbnailPipeline.invalidateAllCachedImages()
                pendingThumbnailRefreshURLs.removeAll()
                if !listChanged {
                    collectionView.reloadData()
                    Signposts.browserReload.emitEvent(
                        "IconReload",
                        "trigger=thumbnailAll kind=full count=\(currentURLs.count, privacy: .public)"
                    )
                }
            } else if !listChanged {
                // If the list also changed this pass, reloadData() above already
                // picked up the latest thumbnails; a targeted reload is redundant.
                pendingThumbnailRefreshURLs.formUnion(invalidated)
                let indexPaths = Set(items.enumerated().compactMap { index, item -> IndexPath? in
                    invalidated.contains(item.url) ? IndexPath(item: index, section: 0) : nil
                })
                if !indexPaths.isEmpty {
                    collectionView.reloadItems(at: indexPaths)
                    Signposts.browserReload.emitEvent(
                        "IconReload",
                        "trigger=thumbnailTargeted kind=targeted count=\(indexPaths.count, privacy: .public)"
                    )
                }
            } else {
                pendingThumbnailRefreshURLs.formUnion(invalidated)
            }
        }

        // Compute before syncSelection so we can suppress the synchronous scrollToItems
        // call inside syncSelection when the gallery is just becoming visible — the
        // deferred scrollSelectionIntoView() handles that case more reliably.
        let justBecameActive = model.browserViewMode == .icon && lastRenderedViewMode != .icon
        lastRenderedViewMode = model.browserViewMode

        if listChanged || columnsChanged || selectionChanged {
            syncSelection(selectedURLs: selectedURLs, scrollPrimaryIntoView: primaryChanged && !justBecameActive)
            lastRenderedSelected = selectedURLs
            lastRenderedPrimarySelectionURL = model.primarySelectionURL
        }

        if listChanged || columnsChanged || selectionChanged || pendingChanged || cloudStatesChanged || stagedOpsChanged || subtitleChanged || metadataChanged || justBecameActive {
            var reasons: [String] = []
            if listChanged { reasons.append("list") }
            if columnsChanged { reasons.append("columns") }
            if selectionChanged { reasons.append("selection") }
            if pendingChanged { reasons.append("pending") }
            if cloudStatesChanged { reasons.append("cloud") }
            if stagedOpsChanged { reasons.append("stagedOps") }
            if subtitleChanged { reasons.append("subtitle") }
            if metadataChanged { reasons.append("metadata") }
            if justBecameActive { reasons.append("becameActive") }
            refreshVisibleCellState(
                pendingURLs: pendingURLs,
                selectedURLs: selectedURLs,
                needsFullReconfigure: listChanged || columnsChanged || pendingChanged || stagedOpsChanged || subtitleChanged || metadataChanged || justBecameActive,
                trigger: reasons.joined(separator: "+")
            )
            lastRenderedPending = pendingURLs
            lastRenderedCloudStates = cloudStates
        }

        // When switching from list → gallery the view just became visible.
        // scrollSelectionIntoView defers via DispatchQueue.main.async so the
        // collection view's layout is fully committed before the scroll fires.
        if justBecameActive {
            scrollSelectionIntoView()
        }
    }

    private func syncSelection(selectedURLs: Set<URL>, scrollPrimaryIntoView: Bool) {
        let selectedIndexPaths = Set(items.enumerated().compactMap { index, item -> IndexPath? in
            selectedURLs.contains(item.url) ? IndexPath(item: index, section: 0) : nil
        })
        if collectionView.selectionIndexPaths != selectedIndexPaths {
            isApplyingProgrammaticSelection = true
            collectionView.selectionIndexPaths = selectedIndexPaths
            isApplyingProgrammaticSelection = false
        }

        if scrollPrimaryIntoView,
           let primary = model.primarySelectionURL,
           let row = items.firstIndex(where: { $0.url == primary }) {
            collectionView.scrollToItems(at: [IndexPath(item: row, section: 0)], scrollPosition: .nearestVerticalEdge)
        }

        updateQuickLookArtifacts()
    }

    private func applyColumnCount(_ targetColumnCount: Int, animated: Bool) {
        guard targetColumnCount > 0 else { return }
        guard layout.columnCount != targetColumnCount else { return }

        zoomRestoreToken += 1
        let restoreToken = zoomRestoreToken
        let selectedItemIndex: Int? = {
            guard let primary = model.primarySelectionURL else { return nil }
            return items.firstIndex(where: { $0.url == primary })
        }()
        let anchor = GalleryZoomTransitionSupport.captureAnchor(
            selectedItemIndex: selectedItemIndex,
            collectionView: collectionView
        )
        let canAnimate = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && view.window != nil
            && collectionView.numberOfItems(inSection: 0) > 0

        if canAnimate {
            applyFadeTransition(to: collectionView)
        }

        layout.columnCount = targetColumnCount
        layout.invalidateLayout()
        GalleryZoomTransitionSupport.restoreAnchor(
            anchor,
            token: restoreToken,
            currentToken: { [weak self] in self?.zoomRestoreToken ?? -1 },
            collectionView: collectionView
        )
        updateQuickLookArtifacts()
    }

    private func applyFadeTransition(to view: NSView) {
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: "galleryZoomFade")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = Motion.duration
        transition.timingFunction = Motion.timingFunction
        layer.add(transition, forKey: "galleryZoomFade")
    }

    private func refreshVisibleCellState(
        pendingURLs: Set<URL>,
        selectedURLs: Set<URL>,
        needsFullReconfigure: Bool,
        trigger: String
    ) {
        var fullCount = 0
        var lightCount = 0
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard indexPath.item >= 0, indexPath.item < items.count else { continue }
            guard let cell = collectionView.item(at: indexPath) as? AppKitIconItem else { continue }
            let item = items[indexPath.item]
            // Skip full reconfigure for items whose thumbnail is already being refreshed via
            // reloadItems — reconfiguring here would show the fallback icon since the pipeline
            // cache has already been cleared, causing a visible flash.
            let awaitingRefresh = pendingThumbnailRefreshURLs.contains(item.url)
            if needsFullReconfigure && !awaitingRefresh {
                let baseImage = ThumbnailPipeline.cachedImage(for: item.url, minRenderedSide: 1)
                    ?? ThumbnailPipeline.fallbackIcon(for: item.url, side: 128)
                let displayImage = model.displayImageForCurrentStagedState(baseImage, fileURL: item.url)
                cell.configure(
                    name: model.pendingRenameByFile[item.url] ?? item.name,
                    subtitle: subtitle(for: item.url),
                    image: displayImage,
                    isSelected: selectedURLs.contains(item.url),
                    hasPendingEdits: pendingURLs.contains(item.url),
                    isPendingRename: model.pendingRenameByFile[item.url] != nil,
                    tileSide: max(layout.tileSide, 40),
                    preferredAspectRatio: preferredAspectRatio(for: item.url),
                    cloudState: item.cloudState
                )
                cell.onCloudBadgeTapped = { [weak model] in model?.requestCloudDownload(for: item.url) }
                requestThumbnail(for: item, in: cell, tileSide: max(layout.tileSide, 40))
                fullCount += 1
            } else {
                cell.applySelection(isSelected: selectedURLs.contains(item.url))
                cell.applyPending(hasPendingEdits: pendingURLs.contains(item.url))
                cell.applyCloudState(item.cloudState)
                cell.onCloudBadgeTapped = { [weak model] in model?.requestCloudDownload(for: item.url) }
                if awaitingRefresh {
                    requestThumbnail(for: item, in: cell, tileSide: max(layout.tileSide, 40))
                }
                lightCount += 1
            }
        }
        Signposts.browserReload.emitEvent(
            "IconCellConfigure",
            "trigger=\(trigger, privacy: .public) full=\(fullCount, privacy: .public) light=\(lightCount, privacy: .public)"
        )
        updateQuickLookArtifacts()
    }

    private func updateQuickLookArtifacts() {
        guard model.browserViewMode == .icon else { return }
        guard let primaryURL = model.primarySelectionURL,
              let index = items.firstIndex(where: { $0.url == primaryURL }),
              let cell = collectionView.item(at: IndexPath(item: index, section: 0)) as? AppKitIconItem,
              let window = collectionView.window
        else {
            return
        }

        let imageView = cell.thumbnailImageView
        let rectInCollection = imageView.convert(imageView.bounds, to: collectionView)
        let rectInWindow = collectionView.convert(rectInCollection, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)
        model.setQuickLookSourceFrame(for: primaryURL, rectOnScreen: rectOnScreen)
    }

    private func menuForItem(at indexPath: IndexPath) -> NSMenu? {
        guard indexPath.item >= 0, indexPath.item < items.count else { return nil }
        let clickedURL = items[indexPath.item].url
        let selectedURLs = model.selectedFileURLs
        let orderedURLs = items.map(\.url)

        if !selectedURLs.contains(clickedURL) {
            isApplyingProgrammaticSelection = true
            collectionView.selectionIndexPaths = [indexPath]
            isApplyingProgrammaticSelection = false
            model.setSelectionFromList([clickedURL], focusedURL: clickedURL)
        }
        contextMenuTargetURLs = ContextMenuSupport.targetSelection(
            clicked: clickedURL,
            selected: selectedURLs,
            orderedItems: orderedURLs
        )
        return BrowserContextMenuBuilder.makeMenu(
            target: self,
            model: model,
            targetURLs: contextMenuTargetURLs,
            actions: .init(
                open: #selector(openFromContextMenu(_:)),
                revealInFinder: #selector(revealInFinderFromContextMenu(_:)),
                cloudDownload: #selector(cloudDownloadFromContextMenu(_:)),
                apply: #selector(applyFromContextMenu(_:)),
                refresh: #selector(refreshFromContextMenu(_:)),
                clear: #selector(clearFromContextMenu(_:)),
                restore: #selector(restoreFromContextMenu(_:)),
                pasteField: #selector(pasteFieldFromContextMenu(_:)),
                copyAllMetadata: #selector(copyAllMetadataFromContextMenu(_:)),
                pasteAllMetadata: #selector(pasteAllMetadataFromContextMenu(_:))
            )
        )
    }

    @objc
    private func openFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.performFileAction(.openInDefaultApp, targetURLs: contextMenuTargetURLs)
    }

    @objc
    private func pasteFieldFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty, let tag = model.pasteboardSingleFieldPreview()?.tag else { return }
        model.pasteField(tag, fileURLs: contextMenuTargetURLs)
    }

    @objc
    private func copyAllMetadataFromContextMenu(_: Any?) {
        model.copyAllMetadataToPasteboard()
    }

    @objc
    private func pasteAllMetadataFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.pasteAllMetadata(fileURLs: contextMenuTargetURLs)
    }

    @objc
    private func cloudDownloadFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.performCloudContextMenuAction(for: contextMenuTargetURLs)
    }

    @objc
    private func revealInFinderFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.revealInFinder(contextMenuTargetURLs)
    }

    @objc
    private func applyFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.performFileAction(.applyMetadataChanges, targetURLs: contextMenuTargetURLs)
    }

    @objc
    private func refreshFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.performFileAction(.refreshMetadata, targetURLs: contextMenuTargetURLs)
    }

    @objc
    private func clearFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.performFileAction(.clearMetadataChanges, targetURLs: contextMenuTargetURLs)
    }

    @objc
    private func restoreFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.performFileAction(.restoreFromLastBackup, targetURLs: contextMenuTargetURLs)
    }

    @objc
    private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        pinchZoomAccumulator.handle(gesture) { [weak self] step in
            guard let self else { return }
            switch step {
            case .zoomIn:
                self.model.adjustGalleryGridLevel(by: -1)
            case .zoomOut:
                self.model.adjustGalleryGridLevel(by: 1)
            }
        }
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard indexPath.item >= 0, indexPath.item < items.count else { return NSCollectionViewItem() }
        guard let cell = collectionView.makeItem(withIdentifier: AppKitIconItem.reuseIdentifier, for: indexPath) as? AppKitIconItem else {
            return NSCollectionViewItem()
        }

        let item = items[indexPath.item]
        let baseImage = ThumbnailPipeline.cachedImage(for: item.url, minRenderedSide: 1)
            ?? ThumbnailPipeline.fallbackIcon(for: item.url, side: 128)
        let displayImage = model.displayImageForCurrentStagedState(baseImage, fileURL: item.url)

        cell.configure(
            name: model.pendingRenameByFile[item.url] ?? item.name,
            subtitle: subtitle(for: item.url),
            image: displayImage,
            isSelected: model.selectedFileURLs.contains(item.url),
            hasPendingEdits: model.hasPendingEdits(for: item.url),
            isPendingRename: model.pendingRenameByFile[item.url] != nil,
            tileSide: max(layout.tileSide, 40),
            preferredAspectRatio: preferredAspectRatio(for: item.url),
            cloudState: item.cloudState
        )
        cell.onCloudBadgeTapped = { [weak model] in model?.requestCloudDownload(for: item.url) }
        requestThumbnail(for: item, in: cell, tileSide: max(layout.tileSide, 40))
        return cell
    }

    private func requestThumbnail(for item: AppModel.BrowserItem, in cell: AppKitIconItem, tileSide: CGFloat) {
        let requiredSide = max(tileSide, 120)
        let forceRefresh = pendingThumbnailRefreshURLs.contains(item.url)
        cell.requestThumbnail(
            for: item.url,
            requiredSide: requiredSide * 1.5,
            forceRefresh: forceRefresh
        ) { [weak self] image, url in
            guard let self else { return image }
            return self.model.displayImageForCurrentStagedState(image, fileURL: url)
        } onImageApplied: { [weak self] url in
            guard let self else { return }
            self.pendingThumbnailRefreshURLs.remove(url)
            self.updateQuickLookArtifacts()
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        handleSelectionChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        handleSelectionChange()
    }

    private func handleSelectionChange() {
        guard !isApplyingProgrammaticSelection else { return }
        let sorted = collectionView.selectionIndexPaths.sorted { $0.item < $1.item }
        let urls = Set(sorted.compactMap { indexPath -> URL? in
            guard indexPath.item >= 0, indexPath.item < items.count else { return nil }
            return items[indexPath.item].url
        })
        let focusedURL = sorted.last.flatMap { indexPath -> URL? in
            guard indexPath.item >= 0, indexPath.item < items.count else { return nil }
            return items[indexPath.item].url
        }
        model.setSelectionFromList(urls, focusedURL: focusedURL)
        updateQuickLookArtifacts()
    }

    private static let imageWidthKeys: Set<String> = ["ImageWidth", "ExifImageWidth", "PixelXDimension"]
    private static let imageHeightKeys: Set<String> = ["ImageHeight", "ExifImageHeight", "PixelYDimension"]

    /// Reuses List view's own field formatting (`listColumnValue`) so Icon view's subtitle can
    /// never disagree with List about how a field is displayed. Metadata loads lazily via the
    /// deferred batch prefetch, same as `preferredAspectRatio` below — a cell may briefly read
    /// "—" until its batch lands, then update.
    private func subtitle(for fileURL: URL) -> String? {
        guard let columnID = model.iconSubtitleColumnID else { return nil }
        let fallbackItem = items.first(where: { $0.url == fileURL })
        return model.listColumnValue(for: fileURL, columnID: columnID, fallbackItem: fallbackItem)
    }

    private func preferredAspectRatio(for fileURL: URL) -> CGFloat? {
        if let snapshot = model.metadataByFile[fileURL] {
            let widthValue = snapshot.fields.first(where: { Self.imageWidthKeys.contains($0.key) })?.value
            let heightValue = snapshot.fields.first(where: { Self.imageHeightKeys.contains($0.key) })?.value
            if let width = parsePositiveNumber(widthValue),
               let height = parsePositiveNumber(heightValue),
               height > 0 {
                let baseAspectRatio = width / height
                return model.displayAspectRatioForCurrentStagedState(baseAspectRatio, fileURL: fileURL)
            }
        }

        // Fallback: derive from cached thumbnail dimensions so rapid staged rotations
        // can update ring geometry immediately even before fresh metadata/thumbnail lands.
        if let cached = ThumbnailPipeline.cachedImage(for: fileURL, minRenderedSide: 1),
           let size = GalleryThumbnailSizing.resolvedImageSize(cached),
           size.height > 0 {
            let baseAspectRatio = size.width / size.height
            return model.displayAspectRatioForCurrentStagedState(baseAspectRatio, fileURL: fileURL)
        }

        return nil
    }

    private func parsePositiveNumber(_ raw: String?) -> CGFloat? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Double(trimmed), direct > 0 {
            return CGFloat(direct)
        }
        let pattern = #"[0-9]+(?:\.[0-9]+)?"#
        guard let match = trimmed.range(of: pattern, options: .regularExpression) else { return nil }
        guard let parsed = Double(trimmed[match]), parsed > 0 else { return nil }
        return CGFloat(parsed)
    }

}

extension BrowserIconViewController {
    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let requiredSide = max(layout.tileSide, 120) * 1.5
        for indexPath in indexPaths {
            guard indexPath.item < items.count else { continue }
            let url = items[indexPath.item].url
            guard ThumbnailPipeline.cachedImage(for: url, minRenderedSide: requiredSide * 0.9) == nil else { continue }
            Task(priority: .utility) {
                _ = await ThumbnailService.request(url: url, requiredSide: requiredSide, forceRefresh: false)
            }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        // Deliberate no-op. Cancelling individual prefetch tasks risks cancelling a task that a
        // now-visible cell is also awaiting (same dedup key). The broker's 4-slot concurrency
        // limit and 200-waiter cap bound queue growth without per-task cancellation.
    }
}

private final class AppKitIconItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AppKitIconItem")
    private let imageInset: CGFloat = GalleryMetrics.default.imageInset
    private let thumbnailCornerRadius: CGFloat = GalleryMetrics.default.thumbnailCornerRadius

    private let selectionBackgroundView = NSView(frame: .zero)
    let thumbnailImageView = NSImageView(frame: .zero)
    private let thumbnailContainer = NSView(frame: .zero)
    private var pendingDot: NSImageView?
    private let cloudBadge = CloudBadgeControl(frame: .zero)
    var onCloudBadgeTapped: (() -> Void)?
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private var preferredAspectRatio: CGFloat?
    private var currentTileSide: CGFloat = 40
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?
    private var titleFieldBottomConstraint: NSLayoutConstraint!
    private var subtitleTopConstraint: NSLayoutConstraint!
    private var subtitleBottomConstraint: NSLayoutConstraint!
    private var representedURL: URL?
    private var thumbnailRequestToken = UUID()
    private var thumbnailTask: Task<Void, Never>?
    private var hasPendingRename = false

    override func loadView() {
        let rootView = AppearanceAwareView(frame: .zero)
        rootView.onEffectiveAppearanceChange = { [weak self] in
            guard let self else { return }
            self.applySelection(isSelected: self.isSelected)
        }
        view = rootView
        configureViewHierarchy()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let liveSide = max(1, floor(min(thumbnailContainer.bounds.width, thumbnailContainer.bounds.height)))
        updateTileSide(liveSide, animated: false)
        titleField.layer?.cornerRadius = 4
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnailRequest()
        representedURL = nil
        onCloudBadgeTapped = nil
        cloudBadge.configure(state: .local)
    }

    private func configureViewHierarchy() {
        view.wantsLayer = true

        selectionBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        selectionBackgroundView.wantsLayer = true
        selectionBackgroundView.layer?.cornerRadius = thumbnailCornerRadius
        selectionBackgroundView.layer?.masksToBounds = true
        selectionBackgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        thumbnailContainer.addSubview(selectionBackgroundView, positioned: .below, relativeTo: thumbnailImageView)

        thumbnailContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.wantsLayer = true
        view.addSubview(thumbnailContainer)

        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = thumbnailCornerRadius
        thumbnailImageView.layer?.masksToBounds = true
        thumbnailContainer.addSubview(thumbnailImageView)

        pendingDot = makeGalleryOverlaySymbol(
            in: thumbnailImageView,
            symbolName: "circle.fill",
            tintColor: .systemOrange,
            position: .topLeading,
            size: UIMetrics.Gallery.pendingDotSize,
            inset: UIMetrics.Gallery.pendingDotInset
        )
        pendingDot?.isHidden = true

        cloudBadge.translatesAutoresizingMaskIntoConstraints = false
        cloudBadge.setIconTintColor(.white)
        cloudBadge.wantsLayer = true
        cloudBadge.layer?.shadowColor = NSColor.black.cgColor
        cloudBadge.layer?.shadowOpacity = 0.5
        cloudBadge.layer?.shadowRadius = 1.5
        cloudBadge.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        cloudBadge.onTap = { [weak self] in self?.onCloudBadgeTapped?() }
        thumbnailImageView.addSubview(cloudBadge)
        NSLayoutConstraint.activate([
            cloudBadge.trailingAnchor.constraint(equalTo: thumbnailImageView.trailingAnchor, constant: -UIMetrics.Gallery.cloudBadgeInset),
            cloudBadge.topAnchor.constraint(equalTo: thumbnailImageView.topAnchor, constant: UIMetrics.Gallery.cloudBadgeInset),
            cloudBadge.widthAnchor.constraint(equalToConstant: UIMetrics.Gallery.cloudBadgeSize),
            cloudBadge.heightAnchor.constraint(equalToConstant: UIMetrics.Gallery.cloudBadgeSize)
        ])

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        titleField.textColor = .labelColor
        titleField.wantsLayer = true
        titleField.setContentHuggingPriority(.required, for: .horizontal)
        view.addSubview(titleField)
        self.textField = titleField

        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.alignment = .center
        subtitleField.lineBreakMode = .byTruncatingMiddle
        subtitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.setContentHuggingPriority(.required, for: .horizontal)
        subtitleField.isHidden = true
        view.addSubview(subtitleField)

        // A hidden NSTextField still participates in Auto Layout sizing (unlike a hidden view
        // inside a stack view), so the subtitle row's own top/bottom constraints are created
        // here but only activated in `applySubtitle` when there's actually a subtitle to show —
        // otherwise the cell would reserve space for it even when off. `titleFieldBottomConstraint`
        // is the always-active fallback that lets the title alone satisfy layout when they're not.
        titleFieldBottomConstraint = titleField.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        subtitleTopConstraint = subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: UIMetrics.Gallery.subtitleGap)
        subtitleBottomConstraint = subtitleField.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)

        NSLayoutConstraint.activate([
            thumbnailContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumbnailContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnailContainer.topAnchor.constraint(equalTo: view.topAnchor),
            thumbnailContainer.heightAnchor.constraint(equalTo: thumbnailContainer.widthAnchor),

            selectionBackgroundView.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor),
            selectionBackgroundView.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor),
            selectionBackgroundView.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor),
            selectionBackgroundView.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor),

            thumbnailImageView.centerXAnchor.constraint(equalTo: thumbnailContainer.centerXAnchor),
            thumbnailImageView.centerYAnchor.constraint(equalTo: thumbnailContainer.centerYAnchor),

            titleField.topAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: UIMetrics.Gallery.titleGap),
            titleField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleField.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            titleFieldBottomConstraint,

            subtitleField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            subtitleField.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
        ])

        imageWidthConstraint = thumbnailImageView.widthAnchor.constraint(equalToConstant: 20)
        imageHeightConstraint = thumbnailImageView.heightAnchor.constraint(equalToConstant: 20)
        imageWidthConstraint?.isActive = true
        imageHeightConstraint?.isActive = true
    }

    func configure(
        name: String,
        subtitle: String? = nil,
        image: NSImage?,
        isSelected: Bool,
        hasPendingEdits: Bool,
        isPendingRename: Bool = false,
        tileSide: CGFloat,
        preferredAspectRatio: CGFloat?,
        cloudState: CloudFileState = .local
    ) {
        titleField.stringValue = name
        applySubtitle(subtitle)
        self.hasPendingRename = isPendingRename
        self.preferredAspectRatio = preferredAspectRatio
        setImage(image, animated: false)
        applySelection(isSelected: isSelected)
        applyPending(hasPendingEdits: hasPendingEdits)
        applyCloudState(cloudState)
        updateTileSide(tileSide, animated: false)
    }

    func updateTileSide(_ tileSide: CGFloat, animated: Bool) {
        currentTileSide = tileSide
        let fitted = GalleryThumbnailSizing.fittedSize(
            preferredAspectRatio: preferredAspectRatio,
            fallbackImageSize: GalleryThumbnailSizing.resolvedImageSize(thumbnailImageView.image),
            in: tileSide,
            imageInset: imageInset
        )
        guard animated else {
            imageWidthConstraint?.constant = fitted.width
            imageHeightConstraint?.constant = fitted.height
            return
        }

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            imageWidthConstraint?.constant = fitted.width
            imageHeightConstraint?.constant = fitted.height
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration
            context.timingFunction = Motion.timingFunction
            context.allowsImplicitAnimation = true
            imageWidthConstraint?.animator().constant = fitted.width
            imageHeightConstraint?.animator().constant = fitted.height
        }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { applySelection(isSelected: isSelected) }
    }

    func applySelection(isSelected: Bool) {
        let finderSelectionCGColor = GallerySelectionStyling.resolvedTileSelectionBackgroundCGColor(for: view)
        let finderSelectionColor = GallerySelectionStyling.tileSelectionBackgroundColor
        let isWindowKey = GallerySelectionStyling.isSelectionEmphasized(in: view)
        let highlighted = highlightState == .forSelection
        let active = isSelected || highlighted
        selectionBackgroundView.layer?.backgroundColor = active
            ? finderSelectionCGColor
            : NSColor.clear.cgColor
        if active && hasPendingRename {
            titleField.layer?.backgroundColor = isWindowKey
                ? NSColor.systemOrange.cgColor
                : finderSelectionCGColor
            titleField.textColor = isWindowKey ? .white : .labelColor
        } else if active {
            titleField.layer?.backgroundColor = isWindowKey
                ? GallerySelectionStyling.resolvedAccentCGColor(for: view)
                : finderSelectionCGColor
            titleField.textColor = isWindowKey ? .white : .labelColor
        } else if hasPendingRename {
            titleField.layer?.backgroundColor = NSColor.clear.cgColor
            titleField.textColor = isWindowKey
                ? .systemOrange
                : finderSelectionColor
        } else {
            titleField.layer?.backgroundColor = NSColor.clear.cgColor
            titleField.textColor = .labelColor
        }
    }

    func applyPending(hasPendingEdits: Bool) {
        pendingDot?.isHidden = !hasPendingEdits
    }

    func applyCloudState(_ cloudState: CloudFileState) {
        cloudBadge.configure(state: cloudState)
    }

    private func applySubtitle(_ subtitle: String?) {
        if let subtitle, !subtitle.isEmpty {
            subtitleField.stringValue = subtitle
            subtitleField.isHidden = false
            if !subtitleTopConstraint.isActive {
                NSLayoutConstraint.activate([subtitleTopConstraint, subtitleBottomConstraint])
            }
        } else {
            subtitleField.stringValue = ""
            subtitleField.isHidden = true
            if subtitleTopConstraint.isActive {
                NSLayoutConstraint.deactivate([subtitleTopConstraint, subtitleBottomConstraint])
            }
        }
    }

    func setImage(_ image: NSImage?, animated: Bool = true) {
        guard thumbnailImageView.image !== image else { return }
        let shouldFadeTransition = animated
            && thumbnailImageView.image != nil
            && image != nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if shouldFadeTransition {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = Motion.duration
            transition.timingFunction = Motion.timingFunction
            thumbnailImageView.layer?.add(transition, forKey: "thumbnailSwapFade")
            thumbnailImageView.alphaValue = 1
            thumbnailImageView.image = image
        } else {
            thumbnailImageView.layer?.removeAnimation(forKey: "thumbnailSwapFade")
            thumbnailImageView.alphaValue = 1
            thumbnailImageView.image = image
        }
        // Keep geometry in sync with the actual rendered image as async thumbnails arrive.
        updateTileSide(currentTileSide, animated: false)
    }

    func cancelThumbnailRequest() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnailRequestToken = UUID()
    }

    func requestThumbnail(
        for url: URL,
        requiredSide: CGFloat,
        forceRefresh: Bool,
        displayTransform: @escaping @MainActor (NSImage, URL) -> NSImage,
        onImageApplied: @escaping @MainActor (URL) -> Void
    ) {
        representedURL = url
        if !forceRefresh,
           ThumbnailPipeline.cachedImage(for: url, minRenderedSide: requiredSide * 0.9) != nil {
            return
        }

        cancelThumbnailRequest()
        let requestToken = UUID()
        thumbnailRequestToken = requestToken

        thumbnailTask = Task { [weak self] in
            guard let self else { return }
            let image = await ThumbnailService.request(
                url: url,
                requiredSide: requiredSide,
                forceRefresh: forceRefresh
            )
            guard let image else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.thumbnailRequestToken == requestToken else { return }
                guard self.representedURL == url else { return }
                self.setImage(displayTransform(image, url))
                onImageApplied(url)
            }
        }
    }


}
