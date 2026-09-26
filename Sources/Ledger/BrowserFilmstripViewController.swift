@preconcurrency import AppKit
import LedgerCore
import SharedUI
import SwiftUI

/// Finder-style "Gallery View": a large preview pane on top, a horizontal scrolling filmstrip
/// of thumbnails along the bottom. Follows the same `init(model:items:)` / `update(model:items:)`
/// / `clearVisualSelection()` contract as `BrowserIconViewController`/`BrowserListViewController`,
/// and drives selection through the exact same `AppModel` entry points those two use — there is
/// no filmstrip-specific selection logic, only a filmstrip-specific presentation of it.
@MainActor
final class BrowserFilmstripViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewPrefetching {
    private var model: AppModel
    private var items: [AppModel.BrowserItem]

    private let previewHostingView: NSHostingView<LargePreviewPane>
    private let scrollView = NSScrollView()
    private let collectionView = SharedGalleryCollectionView()
    private let layout = SharedFilmstripLayout(rowHeight: BrowserFilmstripViewController.rowHeight)

    static let rowHeight: CGFloat = 96

    private var isApplyingProgrammaticSelection = false
    private var contextMenuTargetURLs: [URL] = []
    private var lastRenderedURLs: [URL] = []
    private var lastRenderedSelected: Set<URL> = []
    private var lastRenderedCloudStates: [CloudFileState] = []
    private var lastRenderedPending: Set<URL> = []
    private var lastRenderedPrimarySelectionURL: URL?
    private var lastThumbnailInvalidationToken = UUID()
    private var pendingThumbnailRefreshURLs: Set<URL> = []
    private var isRenderingState = false
    private var lastRenderedViewMode: AppModel.BrowserViewMode?
    private var viewModeObserver: NSObjectProtocol?
    private var selectionAppearanceObserver: GallerySelectionAppearanceObserver?

    init(model: AppModel, items: [AppModel.BrowserItem]) {
        self.model = model
        self.items = items
        self.lastThumbnailInvalidationToken = model.browserThumbnailInvalidationToken
        previewHostingView = NSHostingView(rootView: LargePreviewPane(model: model))
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
        configureLayout()
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
            (collectionView.item(at: indexPath) as? AppKitFilmstripItem)?.cancelThumbnailRequest()
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
        previewHostingView.rootView = LargePreviewPane(model: model)
        guard model.browserViewMode == .gallery else {
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

    func clearVisualSelection() {
        isApplyingProgrammaticSelection = true
        collectionView.selectionIndexPaths = []
        isApplyingProgrammaticSelection = false
    }

    private func refreshSelectionAppearanceForVisibleCells() {
        let visibleURLs = Set(items.map(\.url))
        let selectedURLs = model.selectedFileURLs.intersection(visibleURLs)
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard indexPath.item >= 0, indexPath.item < items.count else { continue }
            guard let cell = collectionView.item(at: indexPath) as? AppKitFilmstripItem else { continue }
            let item = items[indexPath.item]
            cell.applySelection(isSelected: selectedURLs.contains(item.url))
        }
    }

    private func configureLayout() {
        previewHostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewHostingView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        collectionView.translatesAutoresizingMaskIntoConstraints = true
        collectionView.frame = NSRect(origin: .zero, size: scrollView.contentView.bounds.size)
        collectionView.autoresizingMask = [.height]
        collectionView.backgroundColors = [.clear]
        collectionView.collectionViewLayout = layout.collectionViewLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(AppKitFilmstripItem.self, forItemWithIdentifier: AppKitFilmstripItem.reuseIdentifier)

        collectionView.onBackgroundClick = { [weak self] in
            self?.model.clearSelection()
        }
        collectionView.allowsShiftExtendedMovement = false
        collectionView.handlesActivateOnReturn = true
        collectionView.onMoveSelection = { [weak self] direction, extendingSelection in
            self?.model.moveSelectionInFilmstrip(direction: direction, extendingSelection: extendingSelection)
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

        scrollView.documentView = collectionView
        view.addSubview(scrollView)

        let filmstripHeightWithChrome = Self.rowHeight + 2 * GalleryMetrics.default.gridInsets.top
        NSLayoutConstraint.activate([
            previewHostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewHostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewHostingView.topAnchor.constraint(equalTo: view.topAnchor),
            previewHostingView.bottomAnchor.constraint(equalTo: scrollView.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: filmstripHeightWithChrome)
        ])
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
    }

    func focusFilmstripForKeyboardNavigation() {
        guard model.browserViewMode == .gallery else { return }
        guard let window = view.window else { return }
        window.makeFirstResponder(collectionView)
    }

    private func scrollSelectionIntoView() {
        guard model.browserViewMode == .gallery else { return }
        guard let primary = model.primarySelectionURL,
              let row = items.firstIndex(where: { $0.url == primary }) else { return }
        let indexPath = IndexPath(item: row, section: 0)
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

        let currentURLs = items.map(\.url)

        // Matches Finder's own Gallery/Column View: unlike Icon/List (which start with nothing
        // selected), those two modes always land on the first item so there's an anchor to
        // arrow-key from and something in the large preview. Covers both switching into Gallery
        // mode and switching folders while already in it.
        if model.browserViewMode == .gallery,
           model.selectedFileURLs.intersection(Set(currentURLs)).isEmpty,
           let firstURL = currentURLs.first {
            model.setSelectionFromList([firstURL], focusedURL: firstURL)
        }

        let selectedURLs = model.selectedFileURLs.intersection(Set(currentURLs))
        let pendingURLs = Set(currentURLs.filter { model.hasPendingEdits(for: $0) })

        let listChanged = currentURLs != lastRenderedURLs
        let selectionChanged = selectedURLs != lastRenderedSelected
        let pendingChanged = pendingURLs != lastRenderedPending
        let cloudStates = items.map(\.cloudState)
        let cloudStatesChanged = cloudStates != lastRenderedCloudStates
        let primaryChanged = model.primarySelectionURL != lastRenderedPrimarySelectionURL

        if listChanged {
            collectionView.reloadData()
            lastRenderedURLs = currentURLs
            Signposts.browserReload.emitEvent(
                "FilmstripReload",
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
                        "FilmstripReload",
                        "trigger=thumbnailAll kind=full count=\(currentURLs.count, privacy: .public)"
                    )
                }
            } else if !listChanged {
                pendingThumbnailRefreshURLs.formUnion(invalidated)
                let indexPaths = Set(items.enumerated().compactMap { index, item -> IndexPath? in
                    invalidated.contains(item.url) ? IndexPath(item: index, section: 0) : nil
                })
                if !indexPaths.isEmpty {
                    collectionView.reloadItems(at: indexPaths)
                    Signposts.browserReload.emitEvent(
                        "FilmstripReload",
                        "trigger=thumbnailTargeted kind=targeted count=\(indexPaths.count, privacy: .public)"
                    )
                }
            } else {
                pendingThumbnailRefreshURLs.formUnion(invalidated)
            }
        }

        let justBecameActive = model.browserViewMode == .gallery && lastRenderedViewMode != .gallery
        lastRenderedViewMode = model.browserViewMode

        if listChanged || selectionChanged {
            syncSelection(selectedURLs: selectedURLs, scrollPrimaryIntoView: primaryChanged && !justBecameActive)
            lastRenderedSelected = selectedURLs
            lastRenderedPrimarySelectionURL = model.primarySelectionURL
        }

        if listChanged || selectionChanged || pendingChanged || cloudStatesChanged || justBecameActive {
            var reasons: [String] = []
            if listChanged { reasons.append("list") }
            if selectionChanged { reasons.append("selection") }
            if pendingChanged { reasons.append("pending") }
            if cloudStatesChanged { reasons.append("cloud") }
            if justBecameActive { reasons.append("becameActive") }
            refreshVisibleCellState(
                pendingURLs: pendingURLs,
                selectedURLs: selectedURLs,
                needsFullReconfigure: listChanged || pendingChanged || justBecameActive,
                trigger: reasons.joined(separator: "+")
            )
            lastRenderedPending = pendingURLs
            lastRenderedCloudStates = cloudStates
        }

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
            collectionView.scrollToItems(at: [IndexPath(item: row, section: 0)], scrollPosition: .nearestHorizontalEdge)
        }
    }

    private func refreshVisibleCellState(pendingURLs: Set<URL>, selectedURLs: Set<URL>, needsFullReconfigure: Bool, trigger: String) {
        var fullCount = 0
        var lightCount = 0
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard indexPath.item >= 0, indexPath.item < items.count else { continue }
            guard let cell = collectionView.item(at: indexPath) as? AppKitFilmstripItem else { continue }
            let item = items[indexPath.item]
            let awaitingRefresh = pendingThumbnailRefreshURLs.contains(item.url)
            if needsFullReconfigure && !awaitingRefresh {
                let baseImage = ThumbnailPipeline.cachedImage(for: item.url, minRenderedSide: 1)
                    ?? ThumbnailPipeline.fallbackIcon(for: item.url, side: 128)
                let displayImage = model.displayImageForCurrentStagedState(baseImage, fileURL: item.url)
                cell.configure(
                    image: displayImage,
                    isSelected: selectedURLs.contains(item.url),
                    hasPendingEdits: pendingURLs.contains(item.url),
                    preferredAspectRatio: preferredAspectRatio(for: item.url),
                    cloudState: item.cloudState
                )
                cell.onCloudBadgeTapped = { [weak model] in model?.requestCloudDownload(for: item.url) }
                requestThumbnail(for: item, in: cell)
                fullCount += 1
            } else {
                cell.applySelection(isSelected: selectedURLs.contains(item.url))
                cell.applyPending(hasPendingEdits: pendingURLs.contains(item.url))
                cell.applyCloudState(item.cloudState)
                cell.onCloudBadgeTapped = { [weak model] in model?.requestCloudDownload(for: item.url) }
                if awaitingRefresh {
                    requestThumbnail(for: item, in: cell)
                }
                lightCount += 1
            }
        }
        Signposts.browserReload.emitEvent(
            "FilmstripCellConfigure",
            "trigger=\(trigger, privacy: .public) full=\(fullCount, privacy: .public) light=\(lightCount, privacy: .public)"
        )
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

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard indexPath.item >= 0, indexPath.item < items.count else { return NSCollectionViewItem() }
        guard let cell = collectionView.makeItem(withIdentifier: AppKitFilmstripItem.reuseIdentifier, for: indexPath) as? AppKitFilmstripItem else {
            return NSCollectionViewItem()
        }

        let item = items[indexPath.item]
        let baseImage = ThumbnailPipeline.cachedImage(for: item.url, minRenderedSide: 1)
            ?? ThumbnailPipeline.fallbackIcon(for: item.url, side: 128)
        let displayImage = model.displayImageForCurrentStagedState(baseImage, fileURL: item.url)

        cell.configure(
            image: displayImage,
            isSelected: model.selectedFileURLs.contains(item.url),
            hasPendingEdits: model.hasPendingEdits(for: item.url),
            preferredAspectRatio: preferredAspectRatio(for: item.url),
            cloudState: item.cloudState
        )
        cell.onCloudBadgeTapped = { [weak model] in model?.requestCloudDownload(for: item.url) }
        requestThumbnail(for: item, in: cell)
        return cell
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
        // can update geometry immediately even before fresh metadata/thumbnail lands.
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

    private func requestThumbnail(for item: AppModel.BrowserItem, in cell: AppKitFilmstripItem) {
        let requiredSide = Self.rowHeight * 1.5
        let forceRefresh = pendingThumbnailRefreshURLs.contains(item.url)
        cell.requestThumbnail(
            for: item.url,
            requiredSide: requiredSide,
            forceRefresh: forceRefresh
        ) { [weak self] image, url in
            guard let self else { return image }
            return self.model.displayImageForCurrentStagedState(image, fileURL: url)
        } onImageApplied: { [weak self] url in
            self?.pendingThumbnailRefreshURLs.remove(url)
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
    }
}

extension BrowserFilmstripViewController {
    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let requiredSide = Self.rowHeight * 1.5
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
        // Deliberate no-op — see BrowserIconViewController's identical override for rationale.
    }
}

/// Slimmer sibling of `AppKitIconItem` for the filmstrip: fixed square tile, no title label,
/// but the same fitted-image sizing (so overlays anchor to the actual visible photo rather than
/// the tile's full square), cloud badge, pending-edit dot, and selection-ring treatment.
private final class AppKitFilmstripItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AppKitFilmstripItem")
    private let thumbnailCornerRadius: CGFloat = GalleryMetrics.default.thumbnailCornerRadius
    private let imageInset: CGFloat = GalleryMetrics.default.imageInset

    private let selectionBackgroundView = NSView(frame: .zero)
    let thumbnailImageView = NSImageView(frame: .zero)
    private var pendingDot: NSImageView?
    private let cloudBadge = CloudBadgeControl(frame: .zero)
    var onCloudBadgeTapped: (() -> Void)?
    private var preferredAspectRatio: CGFloat?
    private var currentTileSide: CGFloat = 40
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?
    private var representedURL: URL?
    private var thumbnailRequestToken = UUID()
    private var thumbnailTask: Task<Void, Never>?

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
        let liveSide = max(1, floor(min(view.bounds.width, view.bounds.height)))
        updateTileSide(liveSide)
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
        view.addSubview(selectionBackgroundView, positioned: .below, relativeTo: thumbnailImageView)

        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = thumbnailCornerRadius
        thumbnailImageView.layer?.masksToBounds = true
        view.addSubview(thumbnailImageView)

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
            selectionBackgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selectionBackgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            selectionBackgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            selectionBackgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            thumbnailImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            thumbnailImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            cloudBadge.trailingAnchor.constraint(equalTo: thumbnailImageView.trailingAnchor, constant: -UIMetrics.Gallery.cloudBadgeInset),
            cloudBadge.topAnchor.constraint(equalTo: thumbnailImageView.topAnchor, constant: UIMetrics.Gallery.cloudBadgeInset),
            cloudBadge.widthAnchor.constraint(equalToConstant: UIMetrics.Gallery.cloudBadgeSize),
            cloudBadge.heightAnchor.constraint(equalToConstant: UIMetrics.Gallery.cloudBadgeSize)
        ])

        imageWidthConstraint = thumbnailImageView.widthAnchor.constraint(equalToConstant: 20)
        imageHeightConstraint = thumbnailImageView.heightAnchor.constraint(equalToConstant: 20)
        imageWidthConstraint?.isActive = true
        imageHeightConstraint?.isActive = true
    }

    func configure(
        image: NSImage?,
        isSelected: Bool,
        hasPendingEdits: Bool,
        preferredAspectRatio: CGFloat?,
        cloudState: CloudFileState = .local
    ) {
        self.preferredAspectRatio = preferredAspectRatio
        setImage(image)
        applySelection(isSelected: isSelected)
        applyPending(hasPendingEdits: hasPendingEdits)
        applyCloudState(cloudState)
        updateTileSide(currentTileSide)
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { applySelection(isSelected: isSelected) }
    }

    func applySelection(isSelected: Bool) {
        let finderSelectionCGColor = GallerySelectionStyling.resolvedTileSelectionBackgroundCGColor(for: view)
        let highlighted = highlightState == .forSelection
        let active = isSelected || highlighted
        selectionBackgroundView.layer?.backgroundColor = active ? finderSelectionCGColor : NSColor.clear.cgColor
    }

    func applyPending(hasPendingEdits: Bool) {
        pendingDot?.isHidden = !hasPendingEdits
    }

    func applyCloudState(_ cloudState: CloudFileState) {
        cloudBadge.configure(state: cloudState)
    }

    func updateTileSide(_ tileSide: CGFloat) {
        currentTileSide = tileSide
        let fitted = GalleryThumbnailSizing.fittedSize(
            preferredAspectRatio: preferredAspectRatio,
            fallbackImageSize: GalleryThumbnailSizing.resolvedImageSize(thumbnailImageView.image),
            in: tileSide,
            imageInset: imageInset
        )
        imageWidthConstraint?.constant = fitted.width
        imageHeightConstraint?.constant = fitted.height
    }

    func setImage(_ image: NSImage?) {
        thumbnailImageView.image = image
        // Keep geometry in sync with the actual rendered image as async thumbnails arrive.
        updateTileSide(currentTileSide)
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
