@preconcurrency import AppKit
import ExifEditCore

@MainActor
final class BrowserGalleryViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private var model: AppModel
    private var items: [AppModel.BrowserItem]

    private let scrollView = NSScrollView()
    private let collectionView = AppKitGalleryCollectionView()
    private var layout = AppKitGalleryLayout()

    private var isApplyingProgrammaticSelection = false
    private var contextMenuTargetURLs: [URL] = []
    private var lastRenderedURLs: [URL] = []
    private var lastRenderedSelected: Set<URL> = []
    private var lastRenderedPending: Set<URL> = []
    private var lastRenderedPrimarySelectionURL: URL?
    private var lastStagedOpsDisplayToken: UInt64 = 0
    private var lastThumbnailInvalidationToken = UUID()
    private var pendingThumbnailRefreshURLs: Set<URL> = []
    private var isRenderingState = false
    private var zoomRestoreToken = 0
    private var pinchAccumulator: CGFloat = 0
    private var lastMagnification: CGFloat = 0
    private let pinchThreshold: CGFloat = 0.14
    private var browserFocusObserver: NSObjectProtocol?
    private var viewModeObserver: NSObjectProtocol?
    private var lastRenderedViewMode: AppModel.BrowserViewMode?

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
        browserFocusObserver = NotificationCenter.default.addObserver(
            forName: .browserDidRequestFocus,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.focusGalleryForKeyboardNavigation()
            }
        }
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

    override func viewWillDisappear() {
        super.viewWillDisappear()
        for indexPath in collectionView.indexPathsForVisibleItems() {
            (collectionView.item(at: indexPath) as? AppKitGalleryItem)?.cancelThumbnailRequest()
        }
        if let browserFocusObserver {
            NotificationCenter.default.removeObserver(browserFocusObserver)
            self.browserFocusObserver = nil
        }
        if let viewModeObserver {
            NotificationCenter.default.removeObserver(viewModeObserver)
            self.viewModeObserver = nil
        }
    }

    func update(model: AppModel, items: [AppModel.BrowserItem]) {
        self.model = model
        self.items = items
        guard model.browserViewMode == .gallery else {
            // Keep transition state accurate while inactive so the next switch
            // back to gallery can trigger a deterministic refresh pass.
            lastRenderedViewMode = model.browserViewMode
            return
        }
        renderState()
    }

    private func handleViewModeSwitch() {
        guard model.browserViewMode == .gallery else {
            lastRenderedViewMode = model.browserViewMode
            return
        }
        renderState()
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
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.focusRingType = .none
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(AppKitGalleryItem.self, forItemWithIdentifier: AppKitGalleryItem.reuseIdentifier)

        collectionView.onBackgroundClick = { [weak self] in
            self?.model.clearSelection()
        }
        collectionView.onMoveSelection = { [weak self] direction in
            self?.model.moveSelectionInGallery(direction: direction, extendingSelection: false)
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

    private func focusGalleryForKeyboardNavigation() {
        guard model.browserViewMode == .gallery else { return }
        guard let window = view.window else { return }
        window.makeFirstResponder(collectionView)
    }

    private func scrollSelectionIntoView() {
        guard model.browserViewMode == .gallery else { return }
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
            guard let self, self.model.browserViewMode == .gallery else { return }
            self.scrollView.layoutSubtreeIfNeeded()
            guard let attrs = self.collectionView.collectionViewLayout?.layoutAttributesForItem(at: indexPath) else { return }
            self.collectionView.scrollToVisible(attrs.frame)
        }
    }

    private func focusInspectorFromBrowser() {
        guard model.browserViewMode == .gallery else { return }
        guard !model.selectedFileURLs.isEmpty else { return }
        _ = NSApp.sendAction(
            #selector(NativeThreePaneSplitViewController.focusInspectorEntryAction(_:)),
            to: nil,
            from: self
        )
    }

    private func renderState() {
        guard !isRenderingState else { return }
        isRenderingState = true
        defer { isRenderingState = false }

        if lastThumbnailInvalidationToken != model.browserThumbnailInvalidationToken {
            lastThumbnailInvalidationToken = model.browserThumbnailInvalidationToken
            let invalidated = model.browserThumbnailInvalidatedURLs
            if invalidated.isEmpty {
                ThumbnailPipeline.invalidateAllCachedImages()
                pendingThumbnailRefreshURLs.removeAll()
                collectionView.reloadData()
            } else {
                pendingThumbnailRefreshURLs.formUnion(invalidated)
                let indexPaths = Set(items.enumerated().compactMap { index, item -> IndexPath? in
                    invalidated.contains(item.url) ? IndexPath(item: index, section: 0) : nil
                })
                if !indexPaths.isEmpty {
                    collectionView.reloadItems(at: indexPaths)
                }
            }
        }

        let currentURLs = items.map(\.url)
        let selectedURLs = model.selectedFileURLs.intersection(Set(currentURLs))
        let pendingURLs = Set(currentURLs.filter { model.hasPendingEdits(for: $0) })

        let listChanged = currentURLs != lastRenderedURLs
        let targetColumnCount = max(model.galleryColumnCount, 1)
        let columnsChanged = layout.columnCount != targetColumnCount
        let selectionChanged = selectedURLs != lastRenderedSelected
        let pendingChanged = pendingURLs != lastRenderedPending
        let primaryChanged = model.primarySelectionURL != lastRenderedPrimarySelectionURL
        let stagedOpsChanged = lastStagedOpsDisplayToken != model.stagedOpsDisplayToken
        if stagedOpsChanged { lastStagedOpsDisplayToken = model.stagedOpsDisplayToken }

        if columnsChanged {
            applyColumnCount(targetColumnCount, animated: true)
        }

        if listChanged {
            collectionView.reloadData()
            lastRenderedURLs = currentURLs
        }

        // Compute before syncSelection so we can suppress the synchronous scrollToItems
        // call inside syncSelection when the gallery is just becoming visible — the
        // deferred scrollSelectionIntoView() handles that case more reliably.
        let justBecameActive = model.browserViewMode == .gallery && lastRenderedViewMode != .gallery
        lastRenderedViewMode = model.browserViewMode

        if listChanged || columnsChanged || selectionChanged {
            syncSelection(selectedURLs: selectedURLs, scrollPrimaryIntoView: primaryChanged && !justBecameActive)
            lastRenderedSelected = selectedURLs
            lastRenderedPrimarySelectionURL = model.primarySelectionURL
        }

        if listChanged || columnsChanged || selectionChanged || pendingChanged || stagedOpsChanged || justBecameActive {
            refreshVisibleCellState(
                pendingURLs: pendingURLs,
                selectedURLs: selectedURLs,
                needsFullReconfigure: listChanged || columnsChanged || pendingChanged || stagedOpsChanged || justBecameActive
            )
            lastRenderedPending = pendingURLs
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
        let anchor = captureZoomTransitionAnchor()
        let canAnimate = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && view.window != nil
            && collectionView.numberOfItems(inSection: 0) > 0

        if canAnimate {
            applyFadeTransition(to: collectionView)
        }

        layout.columnCount = targetColumnCount
        layout.invalidateLayout()
        restoreZoomTransitionAnchor(anchor, token: restoreToken)
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

    private struct ZoomTransitionAnchor {
        let itemIndex: Int
    }

    private func captureZoomTransitionAnchor() -> ZoomTransitionAnchor? {
        if let primary = model.primarySelectionURL,
           let index = items.firstIndex(where: { $0.url == primary }) {
            return ZoomTransitionAnchor(itemIndex: index)
        }

        let visible = collectionView.indexPathsForVisibleItems()
        guard !visible.isEmpty else { return nil }
        let visibleRect = collectionView.visibleRect
        let center = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        guard let currentLayout = collectionView.collectionViewLayout else { return nil }

        let best = visible.min { lhs, rhs in
            let lhsFrame = currentLayout.layoutAttributesForItem(at: lhs)?.frame ?? .zero
            let rhsFrame = currentLayout.layoutAttributesForItem(at: rhs)?.frame ?? .zero
            let lhsCenter = CGPoint(x: lhsFrame.midX, y: lhsFrame.midY)
            let rhsCenter = CGPoint(x: rhsFrame.midX, y: rhsFrame.midY)
            let lhsDistance = hypot(lhsCenter.x - center.x, lhsCenter.y - center.y)
            let rhsDistance = hypot(rhsCenter.x - center.x, rhsCenter.y - center.y)
            return lhsDistance < rhsDistance
        }

        guard let index = best?.item else { return nil }
        return ZoomTransitionAnchor(itemIndex: index)
    }

    private func restoreZoomTransitionAnchor(_ anchor: ZoomTransitionAnchor?, token: Int) {
        guard let anchor else { return }
        guard anchor.itemIndex >= 0, anchor.itemIndex < items.count else { return }
        guard collectionView.numberOfSections > 0 else { return }
        let currentCount = collectionView.numberOfItems(inSection: 0)
        guard anchor.itemIndex < currentCount else { return }

        let indexPath = IndexPath(item: anchor.itemIndex, section: 0)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard token == self.zoomRestoreToken else { return }
            guard self.collectionView.numberOfSections > 0 else { return }
            let liveCount = self.collectionView.numberOfItems(inSection: 0)
            guard anchor.itemIndex < liveCount else { return }
            self.collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestVerticalEdge)
        }
    }

    private func refreshVisibleCellState(
        pendingURLs: Set<URL>,
        selectedURLs: Set<URL>,
        needsFullReconfigure: Bool
    ) {
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard indexPath.item >= 0, indexPath.item < items.count else { continue }
            guard let cell = collectionView.item(at: indexPath) as? AppKitGalleryItem else { continue }
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
                    name: item.name,
                    image: displayImage,
                    isSelected: selectedURLs.contains(item.url),
                    hasPendingEdits: pendingURLs.contains(item.url),
                    tileSide: max(layout.tileSide, 40),
                    preferredAspectRatio: preferredAspectRatio(for: item.url)
                )
                requestThumbnail(for: item, in: cell, tileSide: max(layout.tileSide, 40))
            } else {
                cell.applySelection(isSelected: selectedURLs.contains(item.url))
                cell.applyPending(hasPendingEdits: pendingURLs.contains(item.url))
                if awaitingRefresh {
                    requestThumbnail(for: item, in: cell, tileSide: max(layout.tileSide, 40))
                }
            }
        }
        updateQuickLookArtifacts()
    }

    private func updateQuickLookArtifacts() {
        guard model.browserViewMode == .gallery else { return }
        guard let primaryURL = model.primarySelectionURL,
              let index = items.firstIndex(where: { $0.url == primaryURL }),
              let cell = collectionView.item(at: IndexPath(item: index, section: 0)) as? AppKitGalleryItem,
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

        if !model.selectedFileURLs.contains(clickedURL) {
            isApplyingProgrammaticSelection = true
            collectionView.selectionIndexPaths = [indexPath]
            isApplyingProgrammaticSelection = false
            model.setSelectionFromList([clickedURL], focusedURL: clickedURL)
            contextMenuTargetURLs = [clickedURL]
        } else {
            contextMenuTargetURLs = items.compactMap { item in
                model.selectedFileURLs.contains(item.url) ? item.url : nil
            }
        }

        let openState = model.fileActionState(for: .openInDefaultApp, targetURLs: contextMenuTargetURLs)
        let photosState = model.fileActionState(for: .sendToPhotos, targetURLs: contextMenuTargetURLs)
        let lightroomState = model.fileActionState(for: .sendToLightroomClassic, targetURLs: contextMenuTargetURLs)
        let refreshState = model.fileActionState(for: .refreshMetadata, targetURLs: contextMenuTargetURLs)
        let applyState = model.fileActionState(for: .applyMetadataChanges, targetURLs: contextMenuTargetURLs)
        let clearState = model.fileActionState(for: .clearMetadataChanges, targetURLs: contextMenuTargetURLs)
        let restoreState = model.fileActionState(for: .restoreFromLastBackup, targetURLs: contextMenuTargetURLs)
        let applyTitle = model.applyMetadataSelectionTitle(for: contextMenuTargetURLs)

        func makeItem(_ title: String, action: Selector, symbolName: String, enabled: Bool) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            return item
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(makeItem(openState.title, action: #selector(openFromContextMenu(_:)), symbolName: openState.symbolName, enabled: openState.isEnabled))
        menu.addItem(makeItem(photosState.title, action: #selector(sendToPhotosFromContextMenu(_:)), symbolName: photosState.symbolName, enabled: photosState.isEnabled))
        menu.addItem(makeItem(lightroomState.title, action: #selector(sendToLightroomClassicFromContextMenu(_:)), symbolName: lightroomState.symbolName, enabled: lightroomState.isEnabled))
        menu.addItem(makeItem("Reveal in Finder", action: #selector(revealInFinderFromContextMenu(_:)), symbolName: "folder", enabled: !contextMenuTargetURLs.isEmpty))
        menu.addItem(.separator())
        menu.addItem(makeItem(applyTitle, action: #selector(applyFromContextMenu(_:)), symbolName: applyState.symbolName, enabled: applyState.isEnabled))
        menu.addItem(makeItem(refreshState.title, action: #selector(refreshFromContextMenu(_:)), symbolName: refreshState.symbolName, enabled: refreshState.isEnabled))
        menu.addItem(makeItem(clearState.title, action: #selector(clearFromContextMenu(_:)), symbolName: clearState.symbolName, enabled: clearState.isEnabled))
        menu.addItem(makeItem(restoreState.title, action: #selector(restoreFromContextMenu(_:)), symbolName: restoreState.symbolName, enabled: restoreState.isEnabled))
        return menu
    }

    @objc
    private func openFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.performFileAction(.openInDefaultApp, targetURLs: contextMenuTargetURLs)
    }

    @objc
    private func revealInFinderFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.revealInFinder(contextMenuTargetURLs)
    }

    @objc
    private func sendToPhotosFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.performFileAction(.sendToPhotos, targetURLs: contextMenuTargetURLs)
    }

    @objc
    private func sendToLightroomClassicFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.performFileAction(.sendToLightroomClassic, targetURLs: contextMenuTargetURLs)
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
        switch gesture.state {
        case .began:
            pinchAccumulator = 0
            lastMagnification = 0
        case .changed:
            let delta = gesture.magnification - lastMagnification
            lastMagnification = gesture.magnification
            pinchAccumulator += delta

            while pinchAccumulator >= pinchThreshold {
                model.adjustGalleryGridLevel(by: -1)
                pinchAccumulator -= pinchThreshold
            }
            while pinchAccumulator <= -pinchThreshold {
                model.adjustGalleryGridLevel(by: 1)
                pinchAccumulator += pinchThreshold
            }
        default:
            pinchAccumulator = 0
            lastMagnification = 0
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
        guard let cell = collectionView.makeItem(withIdentifier: AppKitGalleryItem.reuseIdentifier, for: indexPath) as? AppKitGalleryItem else {
            return NSCollectionViewItem()
        }

        let item = items[indexPath.item]
        let baseImage = ThumbnailPipeline.cachedImage(for: item.url, minRenderedSide: 1)
            ?? ThumbnailPipeline.fallbackIcon(for: item.url, side: 128)
        let displayImage = model.displayImageForCurrentStagedState(baseImage, fileURL: item.url)

        cell.configure(
            name: item.name,
            image: displayImage,
            isSelected: model.selectedFileURLs.contains(item.url),
            hasPendingEdits: model.hasPendingEdits(for: item.url),
            tileSide: max(layout.tileSide, 40),
            preferredAspectRatio: preferredAspectRatio(for: item.url)
        )
        requestThumbnail(for: item, in: cell, tileSide: max(layout.tileSide, 40))
        return cell
    }

    private func requestThumbnail(for item: AppModel.BrowserItem, in cell: AppKitGalleryItem, tileSide: CGFloat) {
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

    private static let imageWidthKeys: Set<String> = ["ImageWidth", "ExifImageWidth", "PixelXDimension"]
    private static let imageHeightKeys: Set<String> = ["ImageHeight", "ExifImageHeight", "PixelYDimension"]

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
           let size = resolvedImageSize(cached),
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

    private func resolvedImageSize(_ image: NSImage) -> CGSize? {
        if image.size.width > 0, image.size.height > 0 {
            return image.size
        }
        if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           bitmap.pixelsWide > 0,
           bitmap.pixelsHigh > 0 {
            return CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        }
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           cgImage.width > 0,
           cgImage.height > 0 {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return nil
    }
}

private final class AppKitGalleryCollectionView: NSCollectionView {
    var onBackgroundClick: (() -> Void)?
    var onMoveSelection: ((MoveCommandDirection) -> Void)?
    var onModifiedItemClick: ((IndexPath, NSEvent.ModifierFlags) -> Void)?
    var contextMenuProvider: ((IndexPath) -> NSMenu?)?
    var onDoubleClick: ((IndexPath) -> Void)?
    var onActivateSelection: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else {
            deselectAll(nil)
            onBackgroundClick?()
            return
        }
        let selectionModifiers = event.modifierFlags.intersection([.command, .shift])
        if !selectionModifiers.isEmpty {
            onModifiedItemClick?(indexPath, selectionModifiers)
            return
        }
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            onDoubleClick?(indexPath)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift, .function]).isEmpty else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == KeyCode.escape {
            deselectAll(nil)
            onBackgroundClick?()
            return
        }

        if event.keyCode == KeyCode.return || event.keyCode == KeyCode.numpadReturn {
            onActivateSelection?()
            return
        }

        let direction: MoveCommandDirection?
        switch event.keyCode {
        case KeyCode.leftArrow: direction = .left
        case KeyCode.rightArrow: direction = .right
        case KeyCode.downArrow: direction = .down
        case KeyCode.upArrow: direction = .up
        default: direction = nil
        }

        if let direction {
            onMoveSelection?(direction)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return contextMenuProvider?(indexPath)
    }
}

private final class AppKitGalleryLayout: NSCollectionViewFlowLayout {
    var columnCount: Int = 4 {
        didSet {
            if oldValue != columnCount {
                invalidateLayout()
            }
        }
    }

    private let defaultInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
    private let horizontalSpacing: CGFloat = 14
    private let verticalSpacing: CGFloat = 16
    private let titleHeight: CGFloat = 22
    private let titleGap: CGFloat = 6

    var tileSide: CGFloat {
        max(40, floor(itemSize.width))
    }

    override init() {
        super.init()
        sectionInset = defaultInsets
        minimumInteritemSpacing = horizontalSpacing
        minimumLineSpacing = verticalSpacing
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }

        let columns = max(columnCount, 1)
        let usableWidth = max(
            collectionView.bounds.width - sectionInset.left - sectionInset.right - CGFloat(columns - 1) * minimumInteritemSpacing,
            1
        )
        let side = max(1, floor(usableWidth / CGFloat(columns)))
        itemSize = NSSize(width: side, height: side + titleGap + titleHeight)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        true
    }
}

private final class AppKitGalleryItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AppKitGalleryItem")
    private let imageInset: CGFloat = 4

    private let selectionBackgroundView = NSView(frame: .zero)
    let thumbnailImageView = NSImageView(frame: .zero)
    private let thumbnailContainer = NSView(frame: .zero)
    private let pendingDot = NSImageView(frame: .zero)
    private let titleField = NSTextField(labelWithString: "")
    private var preferredAspectRatio: CGFloat?
    private var currentTileSide: CGFloat = 40
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?
    private var representedURL: URL?
    private var thumbnailRequestToken = UUID()
    private var thumbnailTask: Task<Void, Never>?

    override func loadView() {
        view = NSView(frame: .zero)
        configureViewHierarchy()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let liveSide = max(1, floor(min(thumbnailContainer.bounds.width, thumbnailContainer.bounds.height)))
        updateTileSide(liveSide, animated: false)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnailRequest()
        representedURL = nil
    }

    private func configureViewHierarchy() {
        view.wantsLayer = true

        selectionBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        selectionBackgroundView.wantsLayer = true
        selectionBackgroundView.layer?.cornerRadius = UIMetrics.Gallery.thumbnailCornerRadius
        selectionBackgroundView.layer?.masksToBounds = true
        selectionBackgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        thumbnailContainer.addSubview(selectionBackgroundView, positioned: .below, relativeTo: thumbnailImageView)

        thumbnailContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.wantsLayer = true
        view.addSubview(thumbnailContainer)

        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = UIMetrics.Gallery.thumbnailCornerRadius
        thumbnailImageView.layer?.masksToBounds = true
        thumbnailContainer.addSubview(thumbnailImageView)

        pendingDot.translatesAutoresizingMaskIntoConstraints = false
        pendingDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        pendingDot.contentTintColor = .systemOrange
        pendingDot.isHidden = true
        thumbnailContainer.addSubview(pendingDot)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        titleField.textColor = .secondaryLabelColor
        view.addSubview(titleField)

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

            pendingDot.widthAnchor.constraint(equalToConstant: UIMetrics.Gallery.pendingDotSize),
            pendingDot.heightAnchor.constraint(equalToConstant: UIMetrics.Gallery.pendingDotSize),
            pendingDot.leadingAnchor.constraint(equalTo: thumbnailImageView.leadingAnchor, constant: UIMetrics.Gallery.pendingDotInset),
            pendingDot.topAnchor.constraint(equalTo: thumbnailImageView.topAnchor, constant: UIMetrics.Gallery.pendingDotInset),

            titleField.topAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: UIMetrics.Gallery.titleGap),
            titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleField.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titleField.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])

        imageWidthConstraint = thumbnailImageView.widthAnchor.constraint(equalToConstant: 20)
        imageHeightConstraint = thumbnailImageView.heightAnchor.constraint(equalToConstant: 20)
        imageWidthConstraint?.isActive = true
        imageHeightConstraint?.isActive = true
    }

    func configure(
        name: String,
        image: NSImage?,
        isSelected: Bool,
        hasPendingEdits: Bool,
        tileSide: CGFloat,
        preferredAspectRatio: CGFloat?
    ) {
        titleField.stringValue = name
        self.preferredAspectRatio = preferredAspectRatio
        setImage(image, animated: false)
        applySelection(isSelected: isSelected)
        applyPending(hasPendingEdits: hasPendingEdits)
        updateTileSide(tileSide, animated: false)
    }

    func updateTileSide(_ tileSide: CGFloat, animated: Bool) {
        currentTileSide = tileSide
        let fitted = fittedThumbnailSize(
            preferredAspectRatio: preferredAspectRatio,
            fallbackImageSize: resolvedImageSize(thumbnailImageView.image),
            in: tileSide
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

    func applySelection(isSelected: Bool) {
        selectionBackgroundView.layer?.backgroundColor = isSelected
            ? AppTheme.accentStrongNSColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
    }

    func applyPending(hasPendingEdits: Bool) {
        pendingDot.isHidden = !hasPendingEdits
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
            let image = await SharedThumbnailRequestBroker.shared.request(
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

    private func resolvedImageSize(_ image: NSImage?) -> CGSize? {
        guard let image else { return nil }
        if image.size.width > 0, image.size.height > 0 {
            return image.size
        }
        if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           bitmap.pixelsWide > 0,
           bitmap.pixelsHigh > 0 {
            return CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        }
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           cgImage.width > 0,
           cgImage.height > 0 {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return nil
    }

    private func fittedThumbnailSize(
        preferredAspectRatio: CGFloat?,
        fallbackImageSize: CGSize?,
        in side: CGFloat
    ) -> CGSize {
        let availableSide = max(1, floor(side - imageInset * 2))
        let aspect: CGFloat
        // Prefer rendered image dimensions so layout tracks displayed content.
        if let fallbackImageSize, fallbackImageSize.width > 0, fallbackImageSize.height > 0 {
            aspect = fallbackImageSize.width / fallbackImageSize.height
        } else if let preferredAspectRatio, preferredAspectRatio > 0 {
            aspect = preferredAspectRatio
        } else {
            aspect = 1
        }

        if aspect >= 1 {
            let width = max(1, floor(availableSide))
            let height = max(1, floor(availableSide / aspect))
            return CGSize(width: width, height: height)
        } else {
            let width = max(1, floor(availableSide * aspect))
            let height = max(1, floor(availableSide))
            return CGSize(width: width, height: height)
        }
    }
}
