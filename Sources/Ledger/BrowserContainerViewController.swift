import AppKit
import Combine
import SharedUI
import SwiftUI

@MainActor
final class BrowserContainerViewController: NSViewController {
    private enum OverlayState: Equatable {
        case none
        case noSelection
        case loading
        case enumerationError(String)
        case emptyFolder
        case noResults
    }

    private let model: AppModel
    private let iconController: BrowserIconViewController
    private let listController: BrowserListViewController
    private let filmstripController: BrowserFilmstripViewController
    private var overlayView: NSView?
    private var renderObservers: [AnyCancellable] = []
    private var lastOverlayState: OverlayState = .none
    private var lastRenderedMode: AppModel.BrowserViewMode?
    /// Tracks whether `FirstStablePaint` has fired for the folder currently
    /// selected. Reset on `selectedSidebarID` change, not on observing
    /// `.loading` — a load fast enough to complete before the coalescer's
    /// next `render()` pass never surfaces `.loading` as an intermediate
    /// state at all, which silently starved the old "transitioned away from
    /// .loading" check (verified directly: a benchmark run against a
    /// 1000+ file corpus produced zero FirstStablePaint events because
    /// enumeration alone — before per-item attribute hydration — is fast
    /// enough to coalesce away).
    private var hasPaintedCurrentLoad = false
    /// `selectedSidebarID` changes synchronously, but the actual `loadFiles()`
    /// call runs on a separately-scheduled `Task` — so the *first* `render()`
    /// pass after a selection change can observe stale "nothing loading yet,
    /// nothing loaded yet" state (`.emptyFolder`) before loading has even
    /// started, which would otherwise satisfy the "settled state" check for
    /// FirstStablePaint immediately and incorrectly. Verified directly: a
    /// benchmark run showed FirstStablePaint firing for a `-openFolderPath`
    /// launch before that folder's `FolderLoad` signpost had even begun.
    /// Requiring more than one render pass since the selection changed skips
    /// that premature first read.
    private var renderPassesSinceSelection = 0
    private let renderCoalescer = MainActorCoalescer()

    // Path bar
    private var pathBarVC: PathBarViewController?
    private var iconBottomConstraint: NSLayoutConstraint?
    private var listBottomConstraint: NSLayoutConstraint?
    private var filmstripBottomConstraint: NSLayoutConstraint?
    private let pathBarDefaultsKey = "\(AppBrand.identifierPrefix).pathBarVisible"

    var isPathBarVisible: Bool {
        UserDefaults.standard.bool(forKey: pathBarDefaultsKey)
    }

    init(model: AppModel) {
        self.model = model
        iconController = BrowserIconViewController(model: model, items: model.filteredBrowserItems)
        listController = BrowserListViewController(model: model, items: model.filteredBrowserItems)
        filmstripController = BrowserFilmstripViewController(model: model, items: model.filteredBrowserItems)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        iconBottomConstraint = installChild(iconController)
        listBottomConstraint = installChild(listController)
        filmstripBottomConstraint = installChild(filmstripController)
        if isPathBarVisible {
            installPathBarIfNeeded()
            adjustContentBottomConstraints(toPathBar: true)
        }
        applyBrowserModeIfNeeded(force: true)
        installRenderObservers()
        render()
    }

    func setPathBarVisible(_ visible: Bool) {
        guard visible != isPathBarVisible else { return }
        UserDefaults.standard.set(visible, forKey: pathBarDefaultsKey)
        if visible {
            installPathBarIfNeeded()
        }
        pathBarVC?.view.isHidden = !visible
        adjustContentBottomConstraints(toPathBar: visible)
        updatePathBarURL()
    }

    private func installPathBarIfNeeded() {
        guard pathBarVC == nil else { return }
        let vc = PathBarViewController()
        vc.placeholderString = "No Folder Selected"
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            vc.view.heightAnchor.constraint(equalToConstant: PathBarViewController.preferredHeight),
        ])
        pathBarVC = vc
    }

    private func adjustContentBottomConstraints(toPathBar: Bool) {
        guard let iconBottomConstraint, let listBottomConstraint, let filmstripBottomConstraint else { return }
        NSLayoutConstraint.deactivate([iconBottomConstraint, listBottomConstraint, filmstripBottomConstraint])
        if toPathBar, let pathBarVC {
            self.iconBottomConstraint = iconController.view.bottomAnchor.constraint(equalTo: pathBarVC.view.topAnchor)
            self.listBottomConstraint = listController.view.bottomAnchor.constraint(equalTo: pathBarVC.view.topAnchor)
            self.filmstripBottomConstraint = filmstripController.view.bottomAnchor.constraint(equalTo: pathBarVC.view.topAnchor)
        } else {
            self.iconBottomConstraint = iconController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            self.listBottomConstraint = listController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            self.filmstripBottomConstraint = filmstripController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        }
        NSLayoutConstraint.activate([self.iconBottomConstraint!, self.listBottomConstraint!, self.filmstripBottomConstraint!])
    }

    private func updatePathBarURL() {
        guard let pathBarVC, !pathBarVC.view.isHidden else { return }
        pathBarVC.url = model.selectedSidebarItem.flatMap { model.sidebarOpenURL(for: $0.kind) }
    }

    private func installRenderObservers() {
        func observe<P: Publisher>(_ publisher: P) where P.Output: Equatable, P.Failure == Never {
            observeEquatable(publisher, storeIn: &renderObservers) { [weak self] in
                self?.scheduleRender()
            }
        }

        observe(model.$browserViewMode)
        observe(model.$filteredBrowserItems)
        observe(model.$browserItems)
        observe(model.$selectedFileURLs)
        observe(model.$selectedSidebarID)
        // Separate subscription purely to reset the FirstStablePaint tracker
        // for the new folder — see hasPaintedCurrentLoad's doc comment.
        observeEquatable(model.$selectedSidebarID, storeIn: &renderObservers) { [weak self] in
            self?.hasPaintedCurrentLoad = false
            self?.renderPassesSinceSelection = 0
        }
        observe(model.$browserEnumerationError.map { $0?.localizedDescription ?? "" }.eraseToAnyPublisher())
        observe(model.$isFolderContentLoading)
        observe(model.$isFolderMetadataLoading)
        observe(model.$browserThumbnailInvalidationToken)
        observe(model.$stagedOpsDisplayToken)
        observe(model.$metadataByFile)
        observe(model.$pendingRenameByFile)
        observe(model.$pendingEditsByFile)
        observe(model.$pendingImageOpsByFile)
        observe(model.$browserSort)
        observe(model.$browserSortAscending)
        observe(model.$galleryGridLevel)
        observe(model.$iconSubtitleColumnID)
    }

    private func scheduleRender() {
        renderCoalescer.schedule { [weak self] in
            guard let self else { return }
            self.render()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        renderObservers.removeAll()
    }

    @discardableResult
    private func installChild(_ child: NSViewController) -> NSLayoutConstraint {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        let bottom = child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            bottom,
        ])
        return bottom
    }

    private func currentOverlayState() -> OverlayState {
        if model.selectedSidebarID == nil {
            return .noSelection
        }
        if let error = model.browserEnumerationError {
            return .enumerationError(error.localizedDescription)
        }
        if model.browserItems.isEmpty && (model.isFolderContentLoading || model.isFolderMetadataLoading) {
            return .loading
        }
        if model.browserItems.isEmpty {
            return .emptyFolder
        }
        if model.filteredBrowserItems.isEmpty {
            return .noResults
        }
        return .none
    }

    private func render() {
        updatePathBarURL()
        applyBrowserModeIfNeeded(force: false)
        let items = model.filteredBrowserItems
        iconController.update(model: model, items: items)
        listController.update(model: model, items: items)
        filmstripController.update(model: model, items: items)

        renderPassesSinceSelection += 1
        let nextOverlayState = currentOverlayState()
        if !hasPaintedCurrentLoad, renderPassesSinceSelection > 1,
           nextOverlayState != .loading, nextOverlayState != .noSelection {
            hasPaintedCurrentLoad = true
            Signposts.folderLoad.emitEvent("FirstStablePaint")
        }
        if nextOverlayState == lastOverlayState, nextOverlayState != .loading {
            return
        }
        lastOverlayState = nextOverlayState
        applyOverlay(nextOverlayState)
    }

    func clearActiveBrowserSelectionUI() {
        switch model.browserViewMode {
        case .icon:
            iconController.clearVisualSelection()
        case .list:
            listController.clearVisualSelection()
        case .gallery:
            filmstripController.clearVisualSelection()
        }
    }

    private func applyBrowserModeIfNeeded(force: Bool) {
        let mode = model.browserViewMode
        if !force, mode == lastRenderedMode { return }
        let state = Signposts.browserTransition.beginInterval("ViewModeSwitch")
        defer { Signposts.browserTransition.endInterval("ViewModeSwitch", state) }
        lastRenderedMode = mode

        switch mode {
        case .icon:
            iconController.view.isHidden = false
            listController.view.isHidden = true
            filmstripController.view.isHidden = true
        case .list:
            iconController.view.isHidden = true
            listController.view.isHidden = false
            filmstripController.view.isHidden = true
        case .gallery:
            iconController.view.isHidden = true
            listController.view.isHidden = true
            filmstripController.view.isHidden = false
        }
    }

    private func applyOverlay(_ state: OverlayState) {
        overlayView?.removeFromSuperview()
        overlayView = nil

        guard state != .none else { return }

        let nextOverlay = makeOverlayView(for: state)
        nextOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nextOverlay)
        NSLayoutConstraint.activate([
            nextOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nextOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nextOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            nextOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        overlayView = nextOverlay
    }

    private func makeOverlayView(for state: OverlayState) -> NSView {
        // AppKit decides when and which overlay to show; SwiftUI handles rendering.
        // NSHostingView is constrained to fill the container in applyOverlay — it
        // does not drive its own sizing.
        let content: BrowserPlaceholderView.Content
        switch state {
        case .none:
            return NSView(frame: .zero)
        case .loading:
            content = .loading
        case .noSelection:
            content = .unavailable(
                title: "No Folder Selected",
                symbolName: "folder",
                message: "Open a folder from the toolbar to browse and edit image metadata."
            )
        case let .enumerationError(message):
            content = .unavailable(title: "Folder Unavailable", symbolName: "lock.fill", message: message)
        case .emptyFolder:
            content = .unavailable(
                title: "No Supported Images",
                symbolName: "photo.on.rectangle.angled",
                message: "This folder contains no image files supported by \(AppBrand.displayName)."
            )
        case .noResults:
            content = .unavailable(title: "No Results", symbolName: "magnifyingglass", message: "Try a different search term.")
        }
        return NSHostingView(rootView: BrowserPlaceholderView(content: content))
    }
}

// MARK: - Browser placeholder (SwiftUI island)
// Purely presentational. Receives plain values from BrowserContainerViewController —
// no AppModel observation, no boundary-crossing state. AppKit owns all geometry
// (the hosting view is constrained to fill its container in applyOverlay).

private struct BrowserPlaceholderView: View {
    enum Content {
        case loading
        case unavailable(title: String, symbolName: String, message: String)
    }

    let content: Content

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            switch content {
            case .loading:
                PlaceholderView(symbolName: "folder", title: "Loading", isLoading: true)
            case let .unavailable(title, symbolName, message):
                PlaceholderView(symbolName: symbolName, title: title, description: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
