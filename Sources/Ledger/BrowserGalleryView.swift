@preconcurrency import AppKit
import ExifEditCore
import SharedUI

@MainActor
final class BrowserGalleryViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewPrefetching {
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
    private var lastRenderedPrimarySelectionURL: URL?
    private var lastStagedOpsDisplayToken: UInt64 = 0
    private var lastThumbnailInvalidationToken = UUID()
    private var pendingThumbnailRefreshURLs: Set<URL> = []
    private var isRenderingState = false
    private var zoomRestoreToken = 0
    private let pinchZoomAccumulator = PinchZoomAccumulator()
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
        collectionView.collectionViewLayout = layout.collectionViewLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(AppKitGalleryItem.self, forItemWithIdentifier: AppKitGalleryItem.reuseIdentifier)

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

    var primaryKeyView: NSView { collectionView }

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
                    name: model.pendingRenameByFile[item.url] ?? item.name,
                    image: displayImage,
                    isSelected: selectedURLs.contains(item.url),
                    hasPendingEdits: pendingURLs.contains(item.url),
                    isPendingRename: model.pendingRenameByFile[item.url] != nil,
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

        let openState = model.fileActionState(for: .openInDefaultApp, targetURLs: contextMenuTargetURLs)
        let photosState = model.fileActionState(for: .sendToPhotos, targetURLs: contextMenuTargetURLs)
        let lightroomState = model.fileActionState(for: .sendToLightroom, targetURLs: contextMenuTargetURLs)
        let lightroomClassicState = model.fileActionState(for: .sendToLightroomClassic, targetURLs: contextMenuTargetURLs)
        let refreshState = model.fileActionState(for: .refreshMetadata, targetURLs: contextMenuTargetURLs)
        let applyState = model.fileActionState(for: .applyMetadataChanges, targetURLs: contextMenuTargetURLs)
        let clearState = model.fileActionState(for: .clearMetadataChanges, targetURLs: contextMenuTargetURLs)
        let restoreState = model.fileActionState(for: .restoreFromLastBackup, targetURLs: contextMenuTargetURLs)
        let applyTitle = model.applyMetadataSelectionTitle(for: contextMenuTargetURLs)

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ContextMenuSupport.makeMenuItem(
            title: openState.title,
            action: #selector(openFromContextMenu(_:)),
            target: self,
            symbolName: openState.symbolName,
            isEnabled: openState.isEnabled
        ))
        menu.addItem(ContextMenuSupport.makeMenuItem(
            title: photosState.title,
            action: #selector(sendToPhotosFromContextMenu(_:)),
            target: self,
            symbolName: photosState.symbolName,
            isEnabled: photosState.isEnabled
        ))
        menu.addItem(ContextMenuSupport.makeMenuItem(
            title: lightroomState.title,
            action: #selector(sendToLightroomFromContextMenu(_:)),
            target: self,
            symbolName: lightroomState.symbolName,
            isEnabled: lightroomState.isEnabled
        ))
        menu.addItem(ContextMenuSupport.makeMenuItem(
            title: lightroomClassicState.title,
            action: #selector(sendToLightroomClassicFromContextMenu(_:)),
            target: self,
            symbolName: lightroomClassicState.symbolName,
            isEnabled: lightroomClassicState.isEnabled
        ))
        menu.addItem(ContextMenuSupport.makeMenuItem(
            title: "Reveal in Finder",
            action: #selector(revealInFinderFromContextMenu(_:)),
            target: self,
            symbolName: "folder",
            isEnabled: !contextMenuTargetURLs.isEmpty
        ))
        menu.addItem(.separator())
        menu.addItem(ContextMenuSupport.makeMenuItem(
            title: applyTitle,
            action: #selector(applyFromContextMenu(_:)),
            target: self,
            symbolName: applyState.symbolName,
            isEnabled: applyState.isEnabled
        ))
        menu.addItem(ContextMenuSupport.makeMenuItem(
            title: refreshState.title,
            action: #selector(refreshFromContextMenu(_:)),
            target: self,
            symbolName: refreshState.symbolName,
            isEnabled: refreshState.isEnabled
        ))
        menu.addItem(ContextMenuSupport.makeMenuItem(
            title: clearState.title,
            action: #selector(clearFromContextMenu(_:)),
            target: self,
            symbolName: clearState.symbolName,
            isEnabled: clearState.isEnabled
        ))
        menu.addItem(ContextMenuSupport.makeMenuItem(
            title: restoreState.title,
            action: #selector(restoreFromContextMenu(_:)),
            target: self,
            symbolName: restoreState.symbolName,
            isEnabled: restoreState.isEnabled
        ))
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
    private func sendToLightroomFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.performFileAction(.sendToLightroom, targetURLs: contextMenuTargetURLs)
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
        guard let cell = collectionView.makeItem(withIdentifier: AppKitGalleryItem.reuseIdentifier, for: indexPath) as? AppKitGalleryItem else {
            return NSCollectionViewItem()
        }

        let item = items[indexPath.item]
        let baseImage = ThumbnailPipeline.cachedImage(for: item.url, minRenderedSide: 1)
            ?? ThumbnailPipeline.fallbackIcon(for: item.url, side: 128)
        let displayImage = model.displayImageForCurrentStagedState(baseImage, fileURL: item.url)

        cell.configure(
            name: model.pendingRenameByFile[item.url] ?? item.name,
            image: displayImage,
            isSelected: model.selectedFileURLs.contains(item.url),
            hasPendingEdits: model.hasPendingEdits(for: item.url),
            isPendingRename: model.pendingRenameByFile[item.url] != nil,
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

extension BrowserGalleryViewController {
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

private final class AppKitGalleryItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AppKitGalleryItem")
    private let imageInset: CGFloat = GalleryMetrics.default.imageInset
    private let thumbnailCornerRadius: CGFloat = GalleryMetrics.default.thumbnailCornerRadius

    private let selectionBackgroundView = NSView(frame: .zero)
    let thumbnailImageView = NSImageView(frame: .zero)
    private let thumbnailContainer = NSView(frame: .zero)
    private var pendingDot: NSImageView?
    private let titleField = NSTextField(labelWithString: "")
    private var preferredAspectRatio: CGFloat?
    private var currentTileSide: CGFloat = 40
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?
    private var representedURL: URL?
    private var thumbnailRequestToken = UUID()
    private var thumbnailTask: Task<Void, Never>?
    private var hasPendingRename = false

    override func loadView() {
        view = NSView(frame: .zero)
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

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        titleField.textColor = .secondaryLabelColor
        titleField.wantsLayer = true
        titleField.setContentHuggingPriority(.required, for: .horizontal)
        view.addSubview(titleField)
        self.textField = titleField

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
        isPendingRename: Bool = false,
        tileSide: CGFloat,
        preferredAspectRatio: CGFloat?
    ) {
        titleField.stringValue = name
        self.hasPendingRename = isPendingRename
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

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { applySelection(isSelected: isSelected) }
    }

    func applySelection(isSelected: Bool) {
        let highlighted = highlightState == .forSelection
        let active = isSelected || highlighted
        selectionBackgroundView.layer?.backgroundColor = active
            ? AppTheme.accentNSColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        titleField.layer?.backgroundColor = active
            ? AppTheme.accentNSColor.cgColor
            : NSColor.clear.cgColor
        titleField.textColor = active ? .white : (hasPendingRename ? .systemOrange : .secondaryLabelColor)
    }

    func applyPending(hasPendingEdits: Bool) {
        pendingDot?.isHidden = !hasPendingEdits
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
