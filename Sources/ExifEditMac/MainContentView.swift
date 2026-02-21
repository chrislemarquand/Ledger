import AppKit
import Combine
import ExifEditCore
import MapKit
import QuickLookThumbnailing
import SwiftUI

@MainActor
final class NativeThreePaneSplitViewController: NSSplitViewController {
    private var model: AppModel

    private let sidebarController: NSHostingController<NavigationSidebarView>
    private let browserController: NSHostingController<BrowserView>
    private let inspectorController: NSHostingController<InspectorView>
    private let contentSplitController: NSSplitViewController

    private let sidebarItem: NSSplitViewItem
    private let contentItem: NSSplitViewItem
    private let browserItem: NSSplitViewItem
    private let inspectorItem: NSSplitViewItem

    private var didApplyInitialLayout = false
    private var isApplyingProgrammaticResize = false
    private var didConfigureWindow = false
    private var didInstallTopChromeFade = false
    private var nativeToolbarDelegate: NativeToolbarDelegate?
    private var debugWindowController: NSWindowController?
    private var modelObserver: AnyCancellable?
    private var statusObserver: AnyCancellable?
    private var innerSplitResizeObserver: NSObjectProtocol?
    private weak var topChromeFadeView: NSVisualEffectView?
    private let topChromeFadeHeight: CGFloat = 72
    private var spacebarMonitor: Any?

    init(model: AppModel) {
        self.model = model

        sidebarController = NSHostingController(rootView: NavigationSidebarView(model: model))
        browserController = NSHostingController(rootView: BrowserView(model: model))
        inspectorController = NSHostingController(rootView: InspectorView(model: model))
        contentSplitController = NSSplitViewController()

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        contentItem = NSSplitViewItem(viewController: contentSplitController)
        browserItem = NSSplitViewItem(viewController: browserController)
        inspectorItem = NSSplitViewItem(viewController: inspectorController)

        super.init(nibName: nil, bundle: nil)

        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 430
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.holdingPriority = .defaultHigh

        browserItem.minimumThickness = 420
        browserItem.holdingPriority = .defaultLow

        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 900
        inspectorItem.canCollapse = false
        inspectorItem.holdingPriority = .defaultLow

        contentSplitController.addSplitViewItem(browserItem)
        contentSplitController.addSplitViewItem(inspectorItem)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)

        modelObserver = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.nativeToolbarDelegate?.syncFromModel()
                }
            }

        statusObserver = model.$statusMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.nativeToolbarDelegate?.syncFromModel()
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        contentSplitController.splitView.isVertical = true
        contentSplitController.splitView.dividerStyle = .thin
        installTopChromeFadeIfNeeded()

        innerSplitResizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: contentSplitController.splitView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.innerSplitDidResize()
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindowIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        if !didApplyInitialLayout {
            didApplyInitialLayout = true
            applySplitWidths(sidebarWidth: model.sidebarWidth, inspectorWidth: model.inspectorWidth)
        }
    }

    override func toggleSidebar(_ sender: Any?) {
        let panes = splitView.arrangedSubviews
        if panes.count == 2, !splitView.isSubviewCollapsed(panes[0]) {
            model.sidebarWidth = panes[0].frame.width
        }
        if contentSplitController.splitView.arrangedSubviews.count == 2 {
            model.inspectorWidth = contentSplitController.splitView.arrangedSubviews[1].frame.width
        }

        super.toggleSidebar(sender)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !isApplyingProgrammaticResize else { return }

        let panes = splitView.arrangedSubviews
        guard panes.count == 2 else { return }

        if !splitView.isSubviewCollapsed(panes[0]) {
            model.sidebarWidth = panes[0].frame.width
        }
    }

    private func applySplitWidths(sidebarWidth: CGFloat, inspectorWidth: CGFloat) {
        let totalWidth = splitView.bounds.width
        guard totalWidth > 0 else { return }
        let panes = splitView.arrangedSubviews
        guard panes.count == 2 else { return }
        let isSidebarCollapsed = splitView.isSubviewCollapsed(panes[0])

        let sidebarMin = sidebarItem.minimumThickness
        let sidebarMax = max(sidebarItem.maximumThickness, sidebarMin)
        let inspectorMin = inspectorItem.minimumThickness
        let inspectorMax = max(inspectorItem.maximumThickness, inspectorMin)
        let centerMin = max(browserItem.minimumThickness, 320)

        let targetSidebar = min(max(sidebarWidth, sidebarMin), sidebarMax)
        isApplyingProgrammaticResize = true
        if !isSidebarCollapsed {
            splitView.setPosition(targetSidebar, ofDividerAt: 0)
        }
        splitView.layoutSubtreeIfNeeded()

        let innerTotalWidth = contentSplitController.splitView.bounds.width
        if innerTotalWidth > 0 {
            var targetInspector = min(max(inspectorWidth, inspectorMin), inspectorMax)
            targetInspector = min(targetInspector, max(inspectorMin, innerTotalWidth - centerMin))
            contentSplitController.splitView.setPosition(max(centerMin, innerTotalWidth - targetInspector), ofDividerAt: 0)
            model.inspectorWidth = targetInspector
        }

        isApplyingProgrammaticResize = false
    }

    private func innerSplitDidResize() {
        guard !isApplyingProgrammaticResize else { return }
        let panes = contentSplitController.splitView.arrangedSubviews
        guard panes.count == 2 else { return }
        model.inspectorWidth = panes[1].frame.width
    }

    private func configureWindowIfNeeded() {
        guard !didConfigureWindow, let window = view.window else { return }
        didConfigureWindow = true

        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .automatic
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.title = toolbarTitleText()
        window.subtitle = toolbarSubtitleText()

        let delegate = NativeToolbarDelegate(controller: self)
        let toolbar = NSToolbar(identifier: "ExifEditMac.MainToolbar")
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar

        nativeToolbarDelegate = delegate
        delegate.syncFromModel()
        installSpacebarQuickLookMonitorIfNeeded()
    }

    private func installSpacebarQuickLookMonitorIfNeeded() {
        guard spacebarMonitor == nil else { return }
        spacebarMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 49 else { return event } // Space
            guard event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty else { return event }
            guard shouldHandleQuickLookSpacebar() else { return event }

            model.quickLookSelection()
            return nil
        }
    }

    private func shouldHandleQuickLookSpacebar() -> Bool {
        guard let window = view.window else { return false }

        // Never hijack space while editing text fields.
        if let textView = window.firstResponder as? NSTextView, textView.isEditable {
            return false
        }

        guard let responderView = window.firstResponder as? NSView else { return false }
        return responderView.isDescendant(of: browserController.view)
    }

    private func toolbarTitleText() -> String {
        guard let item = model.selectedSidebarItem else { return "ExifEditMac" }
        switch item.kind {
        case .recent:
            return "Recently Modified"
        case let .folder(url):
            return url.lastPathComponent
        }
    }

    private func toolbarSubtitleText() -> String {
        let status = model.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty, status != "Ready" {
            return status
        }
        let count = model.browserItems.count
        return count == 1 ? "1 file" : "\(count) files"
    }

    private func installTopChromeFadeIfNeeded() {
        guard !didInstallTopChromeFade else { return }
        didInstallTopChromeFade = true

        let fadeView = PassthroughVisualEffectView()
        fadeView.translatesAutoresizingMaskIntoConstraints = false
        fadeView.material = .headerView
        fadeView.blendingMode = .withinWindow
        fadeView.state = .active
        fadeView.maskImage = Self.topFadeMaskImage(height: Int(topChromeFadeHeight))
        fadeView.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        topChromeFadeView = fadeView
        view.addSubview(fadeView, positioned: .above, relativeTo: splitView)

        NSLayoutConstraint.activate([
            fadeView.topAnchor.constraint(equalTo: view.topAnchor),
            fadeView.leadingAnchor.constraint(equalTo: splitView.leadingAnchor),
            fadeView.trailingAnchor.constraint(equalTo: splitView.trailingAnchor),
            fadeView.heightAnchor.constraint(equalToConstant: topChromeFadeHeight)
        ])
    }

    private static func topFadeMaskImage(height: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 1, height: CGFloat(height)))
        image.lockFocus()
        let gradient = NSGradient(colors: [
            NSColor(calibratedWhite: 1, alpha: 1),
            NSColor(calibratedWhite: 1, alpha: 0.55),
            NSColor(calibratedWhite: 1, alpha: 0)
        ])!
        gradient.draw(
            in: NSRect(x: 0, y: 0, width: 1, height: CGFloat(height)),
            angle: -90
        )
        image.unlockFocus()
        return image
    }

    @objc
    func openFolderAction(_: Any?) {
        model.openFolder()
    }

    @objc
    func refreshAction(_: Any?) {
        model.refresh()
    }

    @objc
    func applyChangesAction(_: Any?) {
        model.applyChanges()
    }

    @objc
    func restoreAction(_: Any?) {
        model.restoreLastOperation()
    }

    @objc
    func debugAction(_: Any?) {
        showDebugPanel()
    }

    @objc
    func zoomOutAction(_: Any?) {
        guard model.browserViewMode == .gallery else { return }
        model.decreaseGalleryZoom()
        nativeToolbarDelegate?.syncFromModel()
    }

    @objc
    func zoomInAction(_: Any?) {
        guard model.browserViewMode == .gallery else { return }
        model.increaseGalleryZoom()
        nativeToolbarDelegate?.syncFromModel()
    }

    @objc
    func sortByNameAction(_: Any?) {
        model.browserSort = .name
        nativeToolbarDelegate?.syncFromModel()
    }

    @objc
    func sortByCreatedAction(_: Any?) {
        model.browserSort = .created
        nativeToolbarDelegate?.syncFromModel()
    }

    @objc
    func sortBySizeAction(_: Any?) {
        model.browserSort = .size
        nativeToolbarDelegate?.syncFromModel()
    }

    @objc
    func sortByKindAction(_: Any?) {
        model.browserSort = .kind
        nativeToolbarDelegate?.syncFromModel()
    }

    @objc
    private func viewModeChanged(_ sender: NSSegmentedControl) {
        model.browserViewMode = sender.selectedSegment == 1 ? .list : .gallery
        nativeToolbarDelegate?.syncFromModel()
    }

    @objc
    private func searchChanged(_ sender: NSSearchField) {
        model.searchQuery = sender.stringValue
    }

    private func showDebugPanel() {
        if let debugWindow = debugWindowController?.window {
            debugWindow.makeKeyAndOrderFront(nil)
            return
        }

        let content = MetadataDebugSheet(model: model) { [weak self] in
            self?.debugWindowController?.close()
        }
        let hostingController = NSHostingController(rootView: content)
        let infoPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        infoPanel.contentViewController = hostingController
        infoPanel.title = "Info"
        infoPanel.minSize = NSSize(width: 700, height: 420)
        infoPanel.isReleasedWhenClosed = false
        infoPanel.hidesOnDeactivate = false
        infoPanel.isFloatingPanel = true
        infoPanel.level = .floating
        infoPanel.animationBehavior = .utilityWindow
        infoPanel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        infoPanel.becomesKeyOnlyIfNeeded = false

        let controller = NSWindowController(window: infoPanel)
        debugWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private final class NativeToolbarDelegate: NSObject, NSToolbarDelegate {
        private weak var controller: NativeThreePaneSplitViewController?

        private var viewModeControl: NSSegmentedControl?
        private var zoomOutItem: NSToolbarItem?
        private var zoomInItem: NSToolbarItem?
        private var sortItem: NSMenuToolbarItem?
        private var searchItem: NSSearchToolbarItem?

        init(controller: NativeThreePaneSplitViewController) {
            self.controller = controller
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [
                .toggleSidebar,
                .viewMode,
                .sort,
                .zoomOut,
                .zoomIn,
                .flexibleSpace,
                .openFolder,
                .refresh,
                .applyChanges,
                .restoreChanges,
                .debugMetadata,
                .search
            ]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            guard let controller else { return nil }

            switch itemIdentifier {
            case .toggleSidebar:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Sidebar"
                item.paletteLabel = "Sidebar"
                item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Toggle sidebar")
                item.target = controller
                item.action = #selector(NSSplitViewController.toggleSidebar(_:))
                item.toolTip = "Show or hide sidebar"
                return item
            case .viewMode:
                let control = NSSegmentedControl(
                    labels: ["", ""],
                    trackingMode: .selectOne,
                    target: controller,
                    action: #selector(NativeThreePaneSplitViewController.viewModeChanged(_:))
                )
                control.setImage(NSImage(systemSymbolName: "square.grid.3x2", accessibilityDescription: "Gallery"), forSegment: 0)
                control.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List"), forSegment: 1)
                control.segmentStyle = .texturedRounded
                control.setWidth(44, forSegment: 0)
                control.setWidth(44, forSegment: 1)

                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "View"
                item.paletteLabel = "View"
                item.view = control
                item.toolTip = "Switch browser view"
                viewModeControl = control
                return item
            case .zoomOut:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Zoom Out"
                item.paletteLabel = "Zoom Out"
                item.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Zoom out")
                item.autovalidates = false
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.zoomOutAction(_:))
                item.toolTip = "Zoom out thumbnails"
                zoomOutItem = item
                return item
            case .zoomIn:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Zoom In"
                item.paletteLabel = "Zoom In"
                item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Zoom in")
                item.autovalidates = false
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.zoomInAction(_:))
                item.toolTip = "Zoom in thumbnails"
                zoomInItem = item
                return item
            case .sort:
                let menu = NSMenu(title: "Sort")
                menu.autoenablesItems = false
                menu.addItem(withTitle: "Name", action: #selector(NativeThreePaneSplitViewController.sortByNameAction(_:)), keyEquivalent: "")
                menu.addItem(withTitle: "Date Created", action: #selector(NativeThreePaneSplitViewController.sortByCreatedAction(_:)), keyEquivalent: "")
                menu.addItem(withTitle: "Size", action: #selector(NativeThreePaneSplitViewController.sortBySizeAction(_:)), keyEquivalent: "")
                menu.addItem(withTitle: "Kind", action: #selector(NativeThreePaneSplitViewController.sortByKindAction(_:)), keyEquivalent: "")
                for item in menu.items {
                    item.target = controller
                }

                let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Sort"
                item.paletteLabel = "Sort"
                item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
                item.menu = menu
                item.toolTip = "Sort files"
                sortItem = item
                return item
            case .openFolder:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Open"
                item.paletteLabel = "Open"
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open")
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.openFolderAction(_:))
                item.toolTip = "Open a folder"
                return item
            case .refresh:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Refresh"
                item.paletteLabel = "Refresh"
                item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.refreshAction(_:))
                item.toolTip = "Refresh files and metadata"
                return item
            case .applyChanges:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Save/Apply"
                item.paletteLabel = "Save/Apply"
                item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save and apply")
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.applyChangesAction(_:))
                item.toolTip = "Apply metadata changes"
                return item
            case .restoreChanges:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Restore"
                item.paletteLabel = "Restore"
                item.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Restore")
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.restoreAction(_:))
                item.toolTip = "Restore from last backup"
                return item
            case .debugMetadata:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Info"
                item.paletteLabel = "Info"
                item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Information")
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.debugAction(_:))
                item.toolTip = "Open information panel"
                return item
            case .search:
                let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Search"
                item.searchField.placeholderString = "Search files"
                item.searchField.sendsSearchStringImmediately = true
                item.searchField.target = controller
                item.searchField.action = #selector(NativeThreePaneSplitViewController.searchChanged(_:))
                item.preferredWidthForSearchField = 260
                item.searchField.translatesAutoresizingMaskIntoConstraints = false
                let fixedWidth = item.searchField.widthAnchor.constraint(equalToConstant: 260)
                fixedWidth.priority = .required
                fixedWidth.isActive = true
                item.searchField.setContentCompressionResistancePriority(.required, for: .horizontal)
                item.searchField.setContentHuggingPriority(.required, for: .horizontal)
                searchItem = item
                return item
            default:
                return nil
            }
        }

        func syncFromModel() {
            guard let controller else { return }
            let model = controller.model
            if let viewModeControl {
                viewModeControl.selectedSegment = model.browserViewMode == .gallery ? 0 : 1
            }
            zoomOutItem?.isEnabled = model.browserViewMode == .gallery && model.canDecreaseGalleryZoom
            zoomInItem?.isEnabled = model.browserViewMode == .gallery && model.canIncreaseGalleryZoom
            if let sortMenu = sortItem?.menu {
                for item in sortMenu.items {
                    item.state = .off
                }
                switch model.browserSort {
                case .name:
                    sortMenu.item(withTitle: "Name")?.state = .on
                case .created:
                    sortMenu.item(withTitle: "Date Created")?.state = .on
                case .size:
                    sortMenu.item(withTitle: "Size")?.state = .on
                case .kind:
                    sortMenu.item(withTitle: "Kind")?.state = .on
                }
            }
            controller.view.window?.title = controller.toolbarTitleText()
            controller.view.window?.subtitle = controller.toolbarSubtitleText()
            if let searchField = searchItem?.searchField, searchField.stringValue != model.searchQuery {
                searchField.stringValue = model.searchQuery
            }
        }
    }
}

private final class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private extension NSToolbarItem.Identifier {
    static let viewMode = NSToolbarItem.Identifier("ExifEditMac.Toolbar.ViewMode")
    static let sort = NSToolbarItem.Identifier("ExifEditMac.Toolbar.Sort")
    static let zoomOut = NSToolbarItem.Identifier("ExifEditMac.Toolbar.ZoomOut")
    static let zoomIn = NSToolbarItem.Identifier("ExifEditMac.Toolbar.ZoomIn")
    static let openFolder = NSToolbarItem.Identifier("ExifEditMac.Toolbar.OpenFolder")
    static let refresh = NSToolbarItem.Identifier("ExifEditMac.Toolbar.Refresh")
    static let applyChanges = NSToolbarItem.Identifier("ExifEditMac.Toolbar.ApplyChanges")
    static let restoreChanges = NSToolbarItem.Identifier("ExifEditMac.Toolbar.Restore")
    static let debugMetadata = NSToolbarItem.Identifier("ExifEditMac.Toolbar.Debug")
    static let search = NSToolbarItem.Identifier("ExifEditMac.Toolbar.Search")
}

struct NavigationSidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: $model.selectedSidebarID) {
            Section("Sources") {
                ForEach(model.sidebarItems) { item in
                    Label(item.title, systemImage: icon(for: item.kind))
                        .tag(item.id)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(maxHeight: .infinity)
        .onChange(of: model.selectedSidebarID) { _, newValue in
            model.selectSidebar(id: newValue)
        }
    }

    private func icon(for kind: AppModel.SidebarKind) -> String {
        switch kind {
        case .recent:
            return "clock.arrow.circlepath"
        case .folder:
            return "folder"
        }
    }
}

struct BrowserView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.browserViewMode == .gallery {
                BrowserGalleryView(model: model)
            } else {
                BrowserListView(model: model)
            }
        }
        .overlay {
            if model.browserItems.isEmpty {
                ContentUnavailableView(
                    "No Images",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Open a folder from the toolbar to start browsing metadata.")
                )
            }
        }
    }
}

private struct BrowserListView: View {
    @ObservedObject var model: AppModel
    private let topScrollStartInset: CGFloat = 56

    var body: some View {
        BrowserListTableRepresentable(model: model, items: model.filteredBrowserItems)
        .ignoresSafeArea(.container, edges: .top)
        .safeAreaPadding(.top, topScrollStartInset)
    }
}

private struct BrowserListTableRepresentable: NSViewRepresentable {
    @ObservedObject var model: AppModel
    let items: [AppModel.BrowserItem]

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, items: items)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let tableView = BrowserListTableView(frame: .zero)
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 24
        tableView.headerView = NSTableHeaderView()
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.gridStyleMask = []
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))
        tableView.target = context.coordinator
        tableView.onBackgroundClick = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            coordinator.model.clearSelection()
        }

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.minWidth = 220
        nameColumn.width = 340

        let createdColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("created"))
        createdColumn.title = "Date Created"
        createdColumn.minWidth = 170
        createdColumn.width = 190

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Size"
        sizeColumn.minWidth = 90
        sizeColumn.width = 110

        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kindColumn.title = "Kind"
        kindColumn.minWidth = 130
        kindColumn.width = 170

        [nameColumn, createdColumn, sizeColumn, kindColumn].forEach { column in
            column.resizingMask = .userResizingMask
        }

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(createdColumn)
        tableView.addTableColumn(sizeColumn)
        tableView.addTableColumn(kindColumn)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.items = items
        guard let tableView = context.coordinator.tableView else { return }

        let availableWidth = scrollView.contentSize.width
        context.coordinator.applyInitialColumnWidthsIfNeeded(availableWidth: availableWidth)
        if context.coordinator.hasListChanged() {
            tableView.reloadData()
        }

        let selectedIndexes = IndexSet(
            items.enumerated().compactMap { index, item in
                model.selectedFileURLs.contains(item.url) ? index : nil
            }
        )
        if tableView.selectedRowIndexes != selectedIndexes {
            context.coordinator.isApplyingProgrammaticSelection = true
            tableView.selectRowIndexes(selectedIndexes, byExtendingSelection: false)
            context.coordinator.isApplyingProgrammaticSelection = false
        }
        context.coordinator.updateQuickLookSourceFrameFromCurrentSelection()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: AppModel
        var items: [AppModel.BrowserItem]
        weak var tableView: NSTableView?
        var isApplyingProgrammaticSelection = false
        private var didApplyInitialColumnWidths = false
        private var listThumbnailCache: [URL: NSImage] = [:]
        private var listThumbnailInflight: Set<URL> = []
        private var lastRenderedItemURLs: [URL] = []

        init(model: AppModel, items: [AppModel.BrowserItem]) {
            self.model = model
            self.items = items
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < items.count else { return nil }
            let item = items[row]
            let columnID = tableColumn?.identifier.rawValue ?? ""

            let cellID = NSUserInterfaceItemIdentifier("cell-\(columnID)")
            let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView) ?? {
                let view = NSTableCellView(frame: .zero)
                view.identifier = cellID
                let textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingMiddle
                view.addSubview(textField)
                view.textField = textField

                if columnID == "name" {
                    let iconView = NSImageView(frame: .zero)
                    iconView.identifier = NSUserInterfaceItemIdentifier("name-icon")
                    iconView.translatesAutoresizingMaskIntoConstraints = false
                    iconView.imageScaling = .scaleProportionallyDown
                    view.addSubview(iconView)

                    NSLayoutConstraint.activate([
                        iconView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                        iconView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                        iconView.widthAnchor.constraint(equalToConstant: 16),
                        iconView.heightAnchor.constraint(equalToConstant: 16),
                        textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
                        textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                        textField.centerYAnchor.constraint(equalTo: view.centerYAnchor)
                    ])
                } else {
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                    textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                    textField.centerYAnchor.constraint(equalTo: view.centerYAnchor)
                ])
                }
                return view
            }()

            if columnID == "name" {
                cell.textField?.lineBreakMode = .byTruncatingMiddle
                if let iconView = cell.subviews.first(where: { ($0 as? NSImageView)?.identifier?.rawValue == "name-icon" }) as? NSImageView {
                    configureListIcon(iconView, for: item, atRow: row, tableView: tableView)
                }
            } else {
                cell.textField?.lineBreakMode = .byTruncatingTail
            }
            cell.textField?.stringValue = model.listColumnValue(for: item.url, columnID: columnID, fallbackItem: item)

            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticSelection,
                  let tableView = notification.object as? NSTableView
            else {
                return
            }

            let urls = Set(
                tableView.selectedRowIndexes.compactMap { row -> URL? in
                    guard row >= 0, row < items.count else { return nil }
                    return items[row].url
                }
            )

            guard urls != model.selectedFileURLs else { return }
            model.selectedFileURLs = urls
            model.selectionChanged()
            updateQuickLookSourceFrameFromCurrentSelection()
        }

        @objc
        func doubleClicked(_ sender: Any?) {
            guard let tableView = sender as? NSTableView else { return }
            let row = tableView.clickedRow
            guard row >= 0, row < items.count else { return }
            model.openInDefaultApp(items[row].url)
        }

        func applyInitialColumnWidthsIfNeeded(availableWidth: CGFloat) {
            guard !didApplyInitialColumnWidths,
                  let tableView,
                  availableWidth > 0
            else {
                return
            }

            let ids = ["name", "created", "size", "kind"]
            let mins: [CGFloat] = [220, 170, 90, 130]
            let weights: [CGFloat] = [0.48, 0.22, 0.12, 0.18]

            let totalMin = mins.reduce(0, +)
            let extra = max(0, availableWidth - totalMin)

            for (index, id) in ids.enumerated() {
                guard let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == id }) else { continue }
                let target = mins[index] + extra * weights[index]
                column.width = max(column.minWidth, target.rounded(.down))
            }

            didApplyInitialColumnWidths = true
        }

        func hasListChanged() -> Bool {
            let currentURLs = items.map(\.url)
            guard currentURLs != lastRenderedItemURLs else { return false }
            lastRenderedItemURLs = currentURLs
            return true
        }

        func updateQuickLookSourceFrameFromCurrentSelection() {
            guard let tableView else { return }
            guard let selectedIndex = items.firstIndex(where: { model.selectedFileURLs.contains($0.url) }) else { return }
            guard let window = tableView.window else { return }
            let item = items[selectedIndex]

            if let nameColumn = tableView.tableColumns.first(where: { $0.identifier.rawValue == "name" }),
               let nameCell = tableView.view(
                   atColumn: tableView.column(withIdentifier: nameColumn.identifier),
                   row: selectedIndex,
                   makeIfNecessary: true
               ) as? NSTableCellView,
               let iconView = nameCell.subviews.first(where: { ($0 as? NSImageView)?.identifier?.rawValue == "name-icon" }) {
                let iconRectInTable = iconView.convert(iconView.bounds, to: tableView)
                let iconRectInWindow = tableView.convert(iconRectInTable, to: nil)
                let iconRectOnScreen = window.convertToScreen(iconRectInWindow)
                model.setQuickLookSourceFrame(for: item.url, rectOnScreen: iconRectOnScreen)
                if let image = (iconView as? NSImageView)?.image {
                    model.setQuickLookTransitionImage(for: item.url, image: image)
                }
                return
            }
        }

        private func configureListIcon(_ iconView: NSImageView, for item: AppModel.BrowserItem, atRow row: Int, tableView: NSTableView) {
            iconView.toolTip = item.url.path

            if model.selectedFileURLs.contains(item.url),
               let window = tableView.window {
                let iconRectInTable = iconView.convert(iconView.bounds, to: tableView)
                let iconRectInWindow = tableView.convert(iconRectInTable, to: nil)
                let iconRectOnScreen = window.convertToScreen(iconRectInWindow)
                model.setQuickLookSourceFrame(for: item.url, rectOnScreen: iconRectOnScreen)
            }

            if let cached = listThumbnailCache[item.url] {
                iconView.image = cached
                model.setQuickLookTransitionImage(for: item.url, image: cached)
                return
            }

            let fallback = NSWorkspace.shared.icon(forFile: item.url.path)
            fallback.size = NSSize(width: 16, height: 16)
            iconView.image = fallback
            model.setQuickLookTransitionImage(for: item.url, image: fallback)

            guard !listThumbnailInflight.contains(item.url) else { return }
            listThumbnailInflight.insert(item.url)

            let request = QLThumbnailGenerator.Request(
                fileAt: item.url,
                size: CGSize(width: 32, height: 32),
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                representationTypes: .thumbnail
            )

            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self, weak tableView] thumbnail, _ in
                guard let self else { return }
                let imageData = thumbnail?.nsImage.tiffRepresentation
                DispatchQueue.main.async {
                    self.listThumbnailInflight.remove(item.url)
                    guard let imageData, let image = NSImage(data: imageData) else { return }

                    self.listThumbnailCache[item.url] = image
                    self.model.setQuickLookTransitionImage(for: item.url, image: image)

                    guard let tableView else { return }
                    guard self.items.indices.contains(row), self.items[row].url == item.url else { return }

                    let nameColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
                    guard nameColumn >= 0,
                          let nameCell = tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: false) as? NSTableCellView,
                          let currentIcon = nameCell.subviews.first(where: { ($0 as? NSImageView)?.identifier?.rawValue == "name-icon" }) as? NSImageView,
                          currentIcon.toolTip == item.url.path
                    else {
                        return
                    }

                    currentIcon.image = image
                }
            }
        }
    }
}

private final class BrowserListTableView: NSTableView {
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if row(at: point) == -1 {
            deselectAll(nil)
            onBackgroundClick?()
        } else {
            super.mouseDown(with: event)
        }
    }
}

private struct BrowserGalleryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SwiftUIGalleryView(model: model)
    }
}

private final class SwiftUIGalleryThumbnailStore: ObservableObject {
    @Published private(set) var images: [URL: NSImage] = [:]
    private var requestedSide: [URL: CGFloat] = [:]
    private var inflight: Set<URL> = []

    func image(for url: URL) -> NSImage? {
        images[url]
    }

    func request(_ url: URL, side: CGFloat) {
        if let existing = requestedSide[url], existing >= side * 0.9, images[url] != nil {
            return
        }
        if inflight.contains(url) {
            return
        }

        inflight.insert(url)
        requestedSide[url] = max(requestedSide[url] ?? 0, side)

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let self else { return }
            let resolvedImage: NSImage
            if let image = thumbnail?.nsImage {
                resolvedImage = image
            } else {
                let fallback = NSWorkspace.shared.icon(forFile: url.path)
                fallback.size = CGSize(width: side, height: side)
                resolvedImage = fallback
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inflight.remove(url)
                self.images[url] = resolvedImage
            }
        }
    }
}

private struct SwiftUIGalleryView: View {
    @ObservedObject var model: AppModel
    @StateObject private var thumbnails = SwiftUIGalleryThumbnailStore()
    @State private var pinchAccumulator: CGFloat = 0
    @State private var lastMagnification: CGFloat = 1
    private let pinchThreshold: CGFloat = 0.14
    private let topScrollStartInset: CGFloat = 56

    var body: some View {
        GeometryReader { geometry in
            let columns = max(model.galleryColumnCount, 1)
            let horizontalPadding: CGFloat = 14
            let spacing: CGFloat = 12
            let availableWidth = max(geometry.size.width - horizontalPadding * 2 - CGFloat(columns - 1) * spacing, 1)
            let tileWidth = floor(availableWidth / CGFloat(columns))
            let gridItems = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVGrid(columns: gridItems, spacing: 14) {
                            ForEach(model.filteredBrowserItems) { item in
                                SwiftUIGalleryCell(
                                    item: item,
                                    tileWidth: tileWidth,
                                    image: thumbnails.image(for: item.url),
                                    isSelected: model.isSelected(item.url)
                                ) {
                                    let additive = NSEvent.modifierFlags.contains(.command)
                                    model.toggleSelection(for: item.url, additive: additive)
                                } onDoubleTap: {
                                    model.openInDefaultApp(item.url)
                                } onThumbnailFrameChanged: { rectOnScreen in
                                    model.setQuickLookSourceFrame(for: item.url, rectOnScreen: rectOnScreen)
                                } onThumbnailImageAvailable: { image in
                                    model.setQuickLookTransitionImage(for: item.url, image: image)
                                }
                                .onAppear {
                                    thumbnails.request(item.url, side: max(tileWidth * 2, 220))
                                }
                                .id(item.url)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 14)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.clearSelection()
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
                .contentMargins(.top, topScrollStartInset, for: .scrollContent)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .focusable()
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    model.moveSelectionInGallery(direction: direction)
                    DispatchQueue.main.async {
                        guard let selected = model.selectedFileURLs.first else { return }
                        proxy.scrollTo(selected)
                    }
                }
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let delta = value / max(lastMagnification, 0.0001) - 1
                            lastMagnification = value
                            pinchAccumulator += delta

                            while pinchAccumulator >= pinchThreshold {
                                let before = model.galleryGridLevel
                                model.adjustGalleryGridLevel(by: -1)
                                if model.galleryGridLevel == before {
                                    pinchAccumulator = 0
                                    break
                                }
                                pinchAccumulator -= pinchThreshold
                            }

                            while pinchAccumulator <= -pinchThreshold {
                                let before = model.galleryGridLevel
                                model.adjustGalleryGridLevel(by: 1)
                                if model.galleryGridLevel == before {
                                    pinchAccumulator = 0
                                    break
                                }
                                pinchAccumulator += pinchThreshold
                            }
                        }
                        .onEnded { _ in
                            lastMagnification = 1
                            pinchAccumulator = 0
                        }
                )
            }
        }
    }
}

private struct SwiftUIGalleryCell: View {
    let item: AppModel.BrowserItem
    let tileWidth: CGFloat
    let image: NSImage?
    let isSelected: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onThumbnailFrameChanged: (CGRect) -> Void
    let onThumbnailImageAvailable: (NSImage) -> Void
    @State private var isHovered = false

    var body: some View {
        let containerSide = tileWidth
        let fittedSize = fittedThumbnailSize(for: image?.size, in: containerSide)
        let thumbnailCornerRadius: CGFloat = 10

        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: containerSide, height: containerSide)
                        .clipShape(RoundedRectangle(cornerRadius: thumbnailCornerRadius))
                        .task(id: image.size) {
                            onThumbnailImageAvailable(image)
                        }
                } else {
                    RoundedRectangle(cornerRadius: thumbnailCornerRadius)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: containerSide, height: containerSide)
                        .background(ScreenFrameReporter(onFrameChanged: onThumbnailFrameChanged))
                }

                Color.clear
                    .frame(width: fittedSize.width, height: fittedSize.height)
                    .background(ScreenFrameReporter(onFrameChanged: onThumbnailFrameChanged))

                if isHovered && !isSelected {
                    RoundedRectangle(cornerRadius: thumbnailCornerRadius)
                        .stroke(Color.primary.opacity(0.22), lineWidth: 1)
                        .frame(width: fittedSize.width, height: fittedSize.height)
                }

                if isSelected {
                    RoundedRectangle(cornerRadius: thumbnailCornerRadius)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: fittedSize.width, height: fittedSize.height)
                        .shadow(color: Color.accentColor.opacity(0.28), radius: 2, x: 0, y: 0)
                }
            }
            .frame(width: containerSide, height: containerSide)
            .contentShape(RoundedRectangle(cornerRadius: thumbnailCornerRadius))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
            .animation(.easeOut(duration: 0.14), value: isSelected)

            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: tileWidth, alignment: .leading)

            if let modifiedAt = item.modifiedAt {
                Text(modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: tileWidth, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                onTap()
            }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onDoubleTap()
            }
        )
    }

    private func fittedThumbnailSize(for imageSize: CGSize?, in side: CGFloat) -> CGSize {
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: side, height: side)
        }

        let widthRatio = side / imageSize.width
        let heightRatio = side / imageSize.height
        let scale = min(widthRatio, heightRatio)
        let width = floor(imageSize.width * scale)
        let height = floor(imageSize.height * scale)
        return CGSize(width: max(1, width), height: max(1, height))
    }
}

private struct ScreenFrameReporter: NSViewRepresentable {
    let onFrameChanged: (CGRect) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onFrameChanged = onFrameChanged
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onFrameChanged = onFrameChanged
        nsView.reportIfPossible()
    }

    final class ReportingView: NSView {
        var onFrameChanged: ((CGRect) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportIfPossible()
        }

        override func layout() {
            super.layout()
            reportIfPossible()
        }

        func reportIfPossible() {
            guard let window else { return }
            let rectInWindow = convert(bounds, to: nil)
            let rectOnScreen = window.convertToScreen(rectInWindow)
            onFrameChanged?(rectOnScreen)
        }
    }
}


struct InspectorView: View {
    @ObservedObject var model: AppModel
    private let topScrollStartInset: CGFloat = 56
    private let contentHorizontalInset: CGFloat = 16
    private let sectionInnerInset: CGFloat = 12
    @FocusState private var focusedTagID: String?
    @State private var editSessionOriginalValues: [String: String] = [:]

    var body: some View {
        ScrollView {
            if model.selectedFileURLs.isEmpty {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "slider.horizontal.3",
                    description: Text("Select one or more files in the browser.")
                )
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.selectedFileURLs.count == 1,
                           let first = model.selectedFileURLs.first {
                            Text(first.lastPathComponent)
                                .font(.title3.weight(.semibold))
                        } else {
                            Text("\(model.selectedFileURLs.count) photos selected")
                                .font(.title3.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, contentHorizontalInset)

                    ForEach(model.groupedEditableTags, id: \.section) { grouped in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    model.toggleInspectorSection(grouped.section)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: model.isInspectorSectionCollapsed(grouped.section) ? "chevron.right" : "chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(grouped.section.uppercased())
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .tracking(0.4)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if !model.isInspectorSectionCollapsed(grouped.section) {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(grouped.tags) { tag in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(tag.label)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if model.isDateTimeTag(tag) {
                                                DatePicker(
                                                    "",
                                                    selection: Binding(
                                                        get: { model.dateValueForTag(tag) ?? Date() },
                                                        set: { model.updateDateValue($0, for: tag) }
                                                    ),
                                                    displayedComponents: [.date, .hourAndMinute]
                                                )
                                                .labelsHidden()
                                                .datePickerStyle(.field)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            } else if let options = model.pickerOptions(for: tag) {
                                                Picker(
                                                    "",
                                                    selection: Binding(
                                                        get: { model.valueForTag(tag) },
                                                        set: { model.updateValue($0, for: tag) }
                                                    )
                                                ) {
                                                    ForEach(options) { option in
                                                        Text(option.label).tag(option.value)
                                                    }
                                                }
                                                .labelsHidden()
                                                .pickerStyle(.menu)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            } else {
                                                TextField(
                                                    model.placeholderForTag(tag),
                                                    text: Binding(
                                                        get: { model.valueForTag(tag) },
                                                        set: { model.updateValue($0, for: tag) }
                                                    ),
                                                    axis: .vertical
                                                )
                                                .textFieldStyle(.roundedBorder)
                                                .focused($focusedTagID, equals: tag.id)
                                            }
                                        }
                                    }

                                    if grouped.section == "Location", let coordinate = photoCoordinate {
                                        locationMapView(for: coordinate)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(sectionInnerInset)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.quaternary.opacity(0.35))
                                )
                            }
                        }
                        .padding(.horizontal, contentHorizontalInset)
                    }

                    if let lastResult = model.lastResult {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("LAST OPERATION")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.4)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Succeeded: \(lastResult.succeeded.count)")
                                Text("Failed: \(lastResult.failed.count)")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(sectionInnerInset)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.quaternary.opacity(0.35))
                            )
                        }
                        .padding(.horizontal, contentHorizontalInset)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .contentMargins(.top, topScrollStartInset, for: .scrollContent)
        .onChange(of: focusedTagID) { oldValue, newValue in
            if let oldValue {
                editSessionOriginalValues.removeValue(forKey: oldValue)
            }
            guard let newValue,
                  let tag = AppModel.EditableTag.common.first(where: { $0.id == newValue })
            else {
                return
            }
            editSessionOriginalValues[newValue] = model.valueForTag(tag)
        }
        .onChange(of: model.selectedFileURLs) { _, _ in
            editSessionOriginalValues.removeAll()
            focusedTagID = nil
        }
        .onExitCommand {
            guard let focusedTagID,
                  let originalValue = editSessionOriginalValues[focusedTagID],
                  let tag = AppModel.EditableTag.common.first(where: { $0.id == focusedTagID })
            else {
                self.focusedTagID = nil
                return
            }

            model.updateValue(originalValue, for: tag)
            editSessionOriginalValues.removeValue(forKey: focusedTagID)
            self.focusedTagID = nil
        }
    }

    private var photoCoordinate: CLLocationCoordinate2D? {
        guard let latitude = numericValue(forTagID: "exif-gps-lat"),
              let longitude = numericValue(forTagID: "exif-gps-lon"),
              (-90 ... 90).contains(latitude),
              (-180 ... 180).contains(longitude)
        else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func mapRegion(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    }

    private func numericValue(forTagID id: String) -> Double? {
        guard let tag = AppModel.EditableTag.common.first(where: { $0.id == id }) else {
            return nil
        }
        let raw = model.valueForTag(tag).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return parseCoordinate(raw)
    }

    @ViewBuilder
    private func locationMapView(for coordinate: CLLocationCoordinate2D) -> some View {
        InspectorLocationMapView(coordinate: coordinate)
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func parseCoordinate(_ raw: String) -> Double? {
        let upper = raw.uppercased()
        let hasWestOrSouth = upper.contains("W") || upper.contains("S")
        let hasEastOrNorth = upper.contains("E") || upper.contains("N")

        if let direct = Double(raw) {
            if direct == 0, hasWestOrSouth {
                return -0
            }
            return hasWestOrSouth ? -abs(direct) : direct
        }

        let numberMatches = raw.matches(of: /-?\d+(?:\.\d+)?/).map { Double($0.0) ?? 0 }
        guard let first = numberMatches.first else { return nil }

        let absoluteValue: Double
        if numberMatches.count >= 3 {
            let degrees = abs(first)
            let minutes = abs(numberMatches[1])
            let seconds = abs(numberMatches[2])
            absoluteValue = degrees + (minutes / 60) + (seconds / 3600)
        } else {
            absoluteValue = abs(first)
        }

        let hasExplicitNegative = first < 0
        let signed = hasExplicitNegative || hasWestOrSouth
            ? -absoluteValue
            : absoluteValue

        if hasEastOrNorth, signed == -0 {
            return 0
        }
        return signed
    }
}

private struct InspectorLocationMapView: NSViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    private let defaultSpan = MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)

    func makeNSView(context _: Context) -> MKMapView {
        let view = InspectorPassthroughMapView(frame: .zero)
        view.isPitchEnabled = false
        view.isRotateEnabled = false
        view.showsCompass = false
        view.showsScale = false
        view.isZoomEnabled = true
        view.isScrollEnabled = false
        view.setRegion(
            MKCoordinateRegion(
                center: coordinate,
                span: defaultSpan
            ),
            animated: false
        )
        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate
        view.addAnnotation(annotation)
        return view
    }

    func updateNSView(_ view: MKMapView, context _: Context) {
        view.removeAnnotations(view.annotations)
        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate
        view.addAnnotation(annotation)
        view.setRegion(
            MKCoordinateRegion(
                center: coordinate,
                span: defaultSpan
            ),
            animated: false
        )
    }
}

private final class InspectorPassthroughMapView: MKMapView {
    override func scrollWheel(with event: NSEvent) {
        if let scrollView = enclosingScrollView {
            scrollView.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}
