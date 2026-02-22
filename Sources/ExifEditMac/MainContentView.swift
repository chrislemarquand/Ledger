import AppKit
import Combine
import ExifEditCore
import ImageIO
import MapKit
import QuickLookThumbnailing
import SwiftUI

private extension Notification.Name {
    static let inspectorDidRequestBrowserFocus = Notification.Name("Logbook.InspectorDidRequestBrowserFocus")
    static let inspectorDidRequestFieldNavigation = Notification.Name("Logbook.InspectorDidRequestFieldNavigation")
}

private func generateOrientedBrowserThumbnail(fileURL: URL, maxPixelSize: CGFloat) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(32, Int(maxPixelSize)),
        kCGImageSourceShouldCacheImmediately: true
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    return NSImage(cgImage: cgImage, size: .zero)
}

private func isLikelyImageFile(_ fileURL: URL) -> Bool {
    let imageExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "gif", "bmp", "webp", "dng", "cr2", "cr3", "arw", "nef", "raf", "orf"
    ]
    return imageExtensions.contains(fileURL.pathExtension.lowercased())
}

private func generateQuickLookThumbnail(fileURL: URL, maxPixelSize: CGFloat) async -> NSImage? {
    let request = QLThumbnailGenerator.Request(
        fileAt: fileURL,
        size: CGSize(width: maxPixelSize, height: maxPixelSize),
        scale: NSScreen.main?.backingScaleFactor ?? 2,
        representationTypes: .thumbnail
    )

    return await withCheckedContinuation { continuation in
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
            continuation.resume(returning: thumbnail?.nsImage)
        }
    }
}

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

    private var didConfigureWindow = false
    private var didInstallTopChromeFade = false
    private var nativeToolbarDelegate: NativeToolbarDelegate?
    private var debugWindowController: NSWindowController?
    private var modelObserver: AnyCancellable?
    private var statusObserver: AnyCancellable?
    private weak var topChromeFadeView: NSVisualEffectView?
    private let topChromeFadeHeight: CGFloat = 72
    private var spacebarMonitor: Any?
    private var browserFocusRequestObserver: NSObjectProtocol?
    private var didApplyInitialContentSplit = false

    init(model: AppModel) {
        self.model = model

        sidebarController = NSHostingController(rootView: NavigationSidebarView(model: model))
        browserController = NSHostingController(rootView: BrowserView(model: model))
        inspectorController = NSHostingController(rootView: InspectorView(model: model))
        contentSplitController = NSSplitViewController()

        // Embedded hosting controllers should not drive container sizing from SwiftUI content updates.
        sidebarController.sizingOptions = []
        browserController.sizingOptions = []
        inspectorController.sizingOptions = []

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

        browserItem.minimumThickness = 280
        browserItem.holdingPriority = .defaultLow

        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 900
        inspectorItem.canCollapse = false
        inspectorItem.holdingPriority = .defaultLow

        // Prevent inspector content from forcing pane expansion during metadata/view updates.
        inspectorController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inspectorController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)

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
        resetSplitAutosaveStateIfNeeded()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = NSSplitView.AutosaveName("Logbook.MainSplit")
        contentSplitController.splitView.isVertical = true
        contentSplitController.splitView.dividerStyle = .thin
        contentSplitController.splitView.autosaveName = NSSplitView.AutosaveName("Logbook.ContentSplit")
        installTopChromeFadeIfNeeded()
    }

    private func resetSplitAutosaveStateIfNeeded() {
        let key = "ui.split.autosave.reset.v3"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }

        // Clear any stale persisted split geometry from earlier custom split logic.
        defaults.removeObject(forKey: "NSSplitView Subview Frames Logbook.MainSplit")
        defaults.removeObject(forKey: "NSSplitView Subview Frames Logbook.ContentSplit")
        defaults.removeObject(forKey: "NSSplitView Divider Positions Logbook.MainSplit")
        defaults.removeObject(forKey: "NSSplitView Divider Positions Logbook.ContentSplit")
        defaults.set(true, forKey: key)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindowIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialContentSplitIfNeeded()
    }

    private func applyInitialContentSplitIfNeeded() {
        guard !didApplyInitialContentSplit else { return }
        if hasPersistedContentSplitLayout() {
            didApplyInitialContentSplit = true
            return
        }
        let split = contentSplitController.splitView
        let panes = split.arrangedSubviews
        guard panes.count == 2 else { return }

        let totalWidth = split.bounds.width
        guard totalWidth > 0 else { return }
        // Avoid capturing an early transitional width before the outer split reaches its settled size.
        let stableWidthThreshold = max(browserItem.minimumThickness + inspectorItem.minimumThickness + 240, 860)
        guard totalWidth >= stableWidthThreshold else { return }

        let browserMin = browserItem.minimumThickness
        let inspectorMin = inspectorItem.minimumThickness
        let browserTarget = min(max(totalWidth * 0.7, browserMin), totalWidth - inspectorMin)
        guard browserTarget.isFinite, browserTarget > 0 else { return }
        split.setPosition(browserTarget, ofDividerAt: 0)
        didApplyInitialContentSplit = true
    }

    private func hasPersistedContentSplitLayout() -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "NSSplitView Subview Frames Logbook.ContentSplit") != nil
            || defaults.object(forKey: "NSSplitView Divider Positions Logbook.ContentSplit") != nil
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
        installBrowserFocusRequestObserverIfNeeded()
    }

    private func installSpacebarQuickLookMonitorIfNeeded() {
        guard spacebarMonitor == nil else { return }
        spacebarMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option, .function])

            if shouldHandleInspectorTabCommands() && event.keyCode == 48 { // Tab
                if modifiers.isEmpty {
                    NotificationCenter.default.post(
                        name: .inspectorDidRequestFieldNavigation,
                        object: nil,
                        userInfo: ["backward": false]
                    )
                    return nil
                }
                if modifiers == [.shift] {
                    NotificationCenter.default.post(
                        name: .inspectorDidRequestFieldNavigation,
                        object: nil,
                        userInfo: ["backward": true]
                    )
                    return nil
                }
            }

            guard shouldHandleBrowserKeyCommands() else { return event }

            switch event.keyCode {
            case 53: // Escape
                guard modifiers.isEmpty else { return event }
                model.clearSelection()
                return nil
            case 49: // Space
                guard modifiers.intersection([.command, .control, .option, .function]).isEmpty else { return event }
                model.quickLookSelection()
                return nil
            case 0: // A
                guard modifiers == [.command] else { return event }
                model.selectAllFilteredFiles()
                return nil
            case 2: // D
                guard modifiers == [.command] else { return event }
                model.clearSelection()
                return nil
            case 123, 124, 125, 126: // Arrow keys
                guard let direction = moveDirection(forKeyCode: event.keyCode) else { return event }
                let isShiftOnly = modifiers == [.shift]
                let isCommandShift = modifiers == [.command, .shift]
                guard isShiftOnly || isCommandShift else { return event }

                if isCommandShift {
                    let towardStart = direction == .left || direction == .up
                    model.extendSelectionToBoundary(towardStart: towardStart)
                    return nil
                }

                if model.browserViewMode == .gallery {
                    model.moveSelectionInGallery(direction: direction, extendingSelection: true)
                } else {
                    model.moveSelectionInList(direction: direction, extendingSelection: true)
                }
                return nil
            default:
                return event
            }
        }
    }

    private func installBrowserFocusRequestObserverIfNeeded() {
        guard browserFocusRequestObserver == nil else { return }
        browserFocusRequestObserver = NotificationCenter.default.addObserver(
            forName: .inspectorDidRequestBrowserFocus,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.view.window else { return }
            window.makeFirstResponder(self.browserController.view)
        }
    }

    private func shouldHandleBrowserKeyCommands() -> Bool {
        guard let window = view.window else { return false }

        // Never hijack space while editing text fields.
        if let textView = window.firstResponder as? NSTextView, textView.isEditable {
            return false
        }

        guard let responderView = window.firstResponder as? NSView else { return false }
        return responderView === browserController.view || responderView.isDescendant(of: browserController.view)
    }

    private func shouldHandleInspectorTabCommands() -> Bool {
        guard let window = view.window else { return false }
        guard let responderView = window.firstResponder as? NSView else { return false }
        return responderView === inspectorController.view || responderView.isDescendant(of: inspectorController.view)
    }

    private func moveDirection(forKeyCode keyCode: UInt16) -> MoveCommandDirection? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    private func toolbarTitleText() -> String {
        guard let item = model.selectedSidebarItem else { return "ExifEditMac" }
        switch item.kind {
        case .recent24Hours, .recent7Days, .recent30Days, .pictures, .desktop, .downloads, .mountedVolume:
            return item.title
        case let .folder(url):
            return url.lastPathComponent
        }
    }

    private func toolbarSubtitleText() -> String {
        if model.isFolderMetadataLoading {
            let total = max(model.folderMetadataLoadTotal, 0)
            let done = min(max(model.folderMetadataLoadCompleted, 0), total)
            return "Loading metadata \(done) of \(total)"
        }
        if model.isPreviewPreloading {
            let total = max(model.previewPreloadTotal, 0)
            let done = min(max(model.previewPreloadCompleted, 0), total)
            return "Loading previews \(done) of \(total)"
        }
        if model.isApplyingMetadata {
            let total = max(model.applyMetadataTotal, 0)
            let done = min(max(model.applyMetadataCompleted, 0), total)
            return "Applying metadata \(done) of \(total)"
        }
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
    func focusSearchAction(_: Any?) {
        nativeToolbarDelegate?.focusSearchField()
    }

    @objc
    func applyChangesAction(_: Any?) {
        if model.requiresBatchApplyConfirmation {
            let alert = NSAlert()
            alert.alertStyle = .warning
            let pendingCount = model.pendingEditedFileCount
            alert.messageText = "Apply pending changes?"
            alert.informativeText = "This will apply metadata edits to \(pendingCount) file(s) with pending changes in the current folder."
            alert.addButton(withTitle: "Apply")
            alert.addButton(withTitle: "Cancel")
            if let window = view.window {
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard response == .alertFirstButtonReturn else { return }
                    self?.model.applyChanges()
                }
            } else if alert.runModal() == .alertFirstButtonReturn {
                model.applyChanges()
            }
            return
        }
        model.applyChanges()
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
    func saveCurrentAsPresetAction(_: Any?) {
        model.beginCreatePresetFromCurrent()
    }

    @objc
    func managePresetsAction(_: Any?) {
        model.isManagePresetsPresented = true
    }

    @objc
    func importGPXAction(_: Any?) {
        model.importGPX()
    }

    @objc
    func applySelectedPresetAction(_: Any?) {
        guard let presetID = model.selectedPresetID,
              let preset = model.preset(withID: presetID)
        else {
            model.statusMessage = "Select a preset first."
            return
        }
        confirmAndApplyPreset(preset: preset)
    }

    @objc
    func applyPresetFromMenuAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let presetID = UUID(uuidString: raw),
              let preset = model.preset(withID: presetID)
        else {
            model.statusMessage = "Preset not found."
            return
        }
        model.selectedPresetID = presetID
        confirmAndApplyPreset(preset: preset)
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

    private func confirmAndApplyPreset(preset: MetadataPreset) {
        let fileCount = model.selectedFileURLs.count
        guard fileCount > 0 else {
            model.statusMessage = "Select one or more files first."
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Apply preset “\(preset.name)” to \(fileCount) files?"
        alert.informativeText = "Included preset fields will overwrite existing values."
        alert.addButton(withTitle: "Apply Preset")
        alert.addButton(withTitle: "Cancel")

        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.model.applyPreset(presetID: preset.id)
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            model.applyPreset(presetID: preset.id)
        }
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
    private final class NativeToolbarDelegate: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
        private weak var controller: NativeThreePaneSplitViewController?

        private var viewModeControl: NSSegmentedControl?
        private var zoomOutItem: NSToolbarItem?
        private var zoomInItem: NSToolbarItem?
        private var sortItem: NSMenuToolbarItem?
        private var importMenuItem: NSMenuToolbarItem?
        private var presetsMenuItem: NSMenuToolbarItem?
        private var applyChangesItem: NSToolbarItem?
        private var importMenu: NSMenu?
        private var presetsMenu: NSMenu?
        private var searchItem: NSSearchToolbarItem?
        private var searchWidthConstraint: NSLayoutConstraint?
        private var loadingItem: NSToolbarItem?

        init(controller: NativeThreePaneSplitViewController) {
            self.controller = controller
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [
                .loadingStatus,
                .toggleSidebar,
                .viewMode,
                .sort,
                .zoomOut,
                .zoomIn,
                .importTools,
                .presetTools,
                .flexibleSpace,
                .openFolder,
                .applyChanges,
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
                return NSToolbarItem(itemIdentifier: .toggleSidebar)
            case .loadingStatus:
                let spinnerView = NSHostingView(rootView: ToolbarLoadingSpinner())
                spinnerView.translatesAutoresizingMaskIntoConstraints = false

                let container = NSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
                container.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(spinnerView)
                NSLayoutConstraint.activate([
                    spinnerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    spinnerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    spinnerView.topAnchor.constraint(equalTo: container.topAnchor),
                    spinnerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    container.widthAnchor.constraint(equalToConstant: 16),
                    container.heightAnchor.constraint(equalToConstant: 16)
                ])

                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Loading"
                item.paletteLabel = "Loading"
                item.view = container
                item.toolTip = "Loading metadata"
                item.visibilityPriority = .high
                item.isBordered = false
                item.view?.isHidden = true
                loadingItem = item
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
            case .importTools:
                let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Import"
                item.paletteLabel = "Import"
                item.image = NSImage(systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: "Import")
                item.toolTip = "Import metadata"
                updateImportMenu()
                if let importMenu {
                    item.menu = importMenu
                }
                importMenuItem = item
                return item
            case .presetTools:
                let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Presets"
                item.paletteLabel = "Presets"
                item.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Presets")
                item.toolTip = "Presets"
                updatePresetsMenu()
                if let presetsMenu {
                    item.menu = presetsMenu
                }
                presetsMenuItem = item
                return item
            case .openFolder:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Open Folder"
                item.paletteLabel = "Open Folder"
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open Folder")
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.openFolderAction(_:))
                item.toolTip = "Open a folder"
                return item
            case .applyChanges:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Apply Metadata Changes"
                item.paletteLabel = "Apply Metadata Changes"
                item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save and apply")
                item.autovalidates = false
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.applyChangesAction(_:))
                item.toolTip = "Apply metadata changes"
                applyChangesItem = item
                return item
            case .search:
                let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Search"
                item.paletteLabel = "Search"
                item.searchField.placeholderString = "Search files"
                item.searchField.sendsSearchStringImmediately = true
                item.searchField.target = controller
                item.searchField.action = #selector(NativeThreePaneSplitViewController.searchChanged(_:))
                item.searchField.delegate = self
                item.preferredWidthForSearchField = 260
                item.searchField.translatesAutoresizingMaskIntoConstraints = false
                let widthConstraint = item.searchField.widthAnchor.constraint(equalToConstant: 260)
                widthConstraint.priority = .required
                widthConstraint.isActive = true
                item.toolTip = "Search files"
                searchItem = item
                searchWidthConstraint = widthConstraint
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
            updateImportMenu()
            updatePresetsMenu()
            controller.view.window?.title = controller.toolbarTitleText()
            controller.view.window?.subtitle = controller.toolbarSubtitleText()
            if let searchField = searchItem?.searchField, searchField.stringValue != model.searchQuery {
                searchField.stringValue = model.searchQuery
            }
            searchWidthConstraint?.constant = 260
            applyChangesItem?.isEnabled = model.canApplyMetadataChanges

            let shouldShowLoading = model.isFolderMetadataLoading || model.isPreviewPreloading || model.isApplyingMetadata
            loadingItem?.view?.isHidden = !shouldShowLoading
        }

        func focusSearchField() {
            guard let window = controller?.view.window else { return }
            guard let searchField = searchItem?.searchField else { return }
            window.makeFirstResponder(searchField)
            searchField.selectText(nil)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
                  let searchField = control as? NSSearchField,
                  let controller
            else {
                return false
            }
            searchField.stringValue = ""
            controller.model.searchQuery = ""
            return true
        }

        private func updateImportMenu() {
            guard let controller else { return }
            let menu = NSMenu(title: "Import")

            let refreshItem = NSMenuItem(
                title: "Refresh Files and Metadata",
                action: #selector(NativeThreePaneSplitViewController.refreshAction(_:)),
                keyEquivalent: ""
            )
            refreshItem.target = controller
            menu.addItem(refreshItem)
            menu.addItem(.separator())

            let gpxItem = NSMenuItem(
                title: "Import GPX…",
                action: #selector(NativeThreePaneSplitViewController.importGPXAction(_:)),
                keyEquivalent: ""
            )
            gpxItem.target = controller
            gpxItem.isEnabled = !controller.model.browserItems.isEmpty
            menu.addItem(gpxItem)

            let csvItem = NSMenuItem(title: "Import CSV… (Coming Soon)", action: nil, keyEquivalent: "")
            csvItem.isEnabled = false
            menu.addItem(csvItem)

            let referenceItem = NSMenuItem(title: "Import Reference Folder… (Coming Soon)", action: nil, keyEquivalent: "")
            referenceItem.isEnabled = false
            menu.addItem(referenceItem)

            importMenu = menu
            importMenuItem?.menu = menu
        }

        private func updatePresetsMenu() {
            guard let controller else { return }
            let menu = NSMenu(title: "Presets")
            menu.autoenablesItems = false

            let applyMenuItem = NSMenuItem(title: "Apply Preset", action: nil, keyEquivalent: "")
            let applySubmenu = NSMenu(title: "Apply Preset")
            if controller.model.presets.isEmpty {
                let emptyItem = NSMenuItem(title: "No Presets", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                applySubmenu.addItem(emptyItem)
            } else {
                for preset in controller.model.presets {
                    let item = NSMenuItem(
                        title: preset.name,
                        action: #selector(NativeThreePaneSplitViewController.applyPresetFromMenuAction(_:)),
                        keyEquivalent: ""
                    )
                    item.target = controller
                    item.representedObject = preset.id.uuidString
                    item.state = controller.model.selectedPresetID == preset.id ? .on : .off
                    item.isEnabled = !controller.model.selectedFileURLs.isEmpty
                    applySubmenu.addItem(item)
                }
            }
            menu.setSubmenu(applySubmenu, for: applyMenuItem)
            menu.addItem(applyMenuItem)
            menu.addItem(.separator())

            let saveItem = NSMenuItem(
                title: "Save Current as Preset…",
                action: #selector(NativeThreePaneSplitViewController.saveCurrentAsPresetAction(_:)),
                keyEquivalent: ""
            )
            saveItem.target = controller
            saveItem.isEnabled = !controller.model.selectedFileURLs.isEmpty
            menu.addItem(saveItem)

            let manageItem = NSMenuItem(
                title: "Manage Presets…",
                action: #selector(NativeThreePaneSplitViewController.managePresetsAction(_:)),
                keyEquivalent: ""
            )
            manageItem.target = controller
            menu.addItem(manageItem)

            presetsMenu = menu
            presetsMenuItem?.menu = menu
        }
    }
}

private final class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct ToolbarLoadingSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .progressViewStyle(.circular)
            .frame(width: 16, height: 16)
    }
}

private extension NSToolbarItem.Identifier {
    static let loadingStatus = NSToolbarItem.Identifier("ExifEditMac.Toolbar.LoadingStatus")
    static let viewMode = NSToolbarItem.Identifier("ExifEditMac.Toolbar.ViewMode")
    static let sort = NSToolbarItem.Identifier("ExifEditMac.Toolbar.Sort")
    static let importTools = NSToolbarItem.Identifier("ExifEditMac.Toolbar.ImportTools")
    static let presetTools = NSToolbarItem.Identifier("ExifEditMac.Toolbar.PresetTools")
    static let zoomOut = NSToolbarItem.Identifier("ExifEditMac.Toolbar.ZoomOut")
    static let zoomIn = NSToolbarItem.Identifier("ExifEditMac.Toolbar.ZoomIn")
    static let openFolder = NSToolbarItem.Identifier("ExifEditMac.Toolbar.OpenFolder")
    static let applyChanges = NSToolbarItem.Identifier("ExifEditMac.Toolbar.ApplyChanges")
    static let search = NSToolbarItem.Identifier("ExifEditMac.Toolbar.Search")
}

struct NavigationSidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: $model.selectedSidebarID) {
            ForEach(model.sidebarSectionOrder, id: \.self) { section in
                let sectionItems = model.sidebarItems.filter { $0.section == section }
                if !sectionItems.isEmpty {
                    Section(section) {
                        ForEach(sectionItems) { item in
                            Label(item.title, systemImage: icon(for: item.kind))
                                .tag(item.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(maxHeight: .infinity)
        .onChange(of: model.selectedSidebarID) { oldValue, newValue in
            model.handleSidebarSelectionChange(from: oldValue, to: newValue)
        }
    }

    private func icon(for kind: AppModel.SidebarKind) -> String {
        switch kind {
        case .recent24Hours, .recent7Days, .recent30Days:
            return "clock.arrow.circlepath"
        case .pictures:
            return "photo.on.rectangle"
        case .desktop:
            return "desktopcomputer"
        case .downloads:
            return "arrow.down.circle"
        case .mountedVolume:
            return "externaldrive"
        case .folder:
            return "folder"
        }
    }
}

struct BrowserView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            BrowserGalleryView(model: model)
                .opacity(model.browserViewMode == .gallery ? 1 : 0)
                .allowsHitTesting(model.browserViewMode == .gallery)

            BrowserListView(model: model)
                .opacity(model.browserViewMode == .list ? 1 : 0)
                .allowsHitTesting(model.browserViewMode == .list)
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

private struct BrowserListTableRepresentable: NSViewControllerRepresentable {
    @ObservedObject var model: AppModel
    let items: [AppModel.BrowserItem]

    func makeNSViewController(context: Context) -> BrowserListViewController {
        BrowserListViewController(model: model, items: items)
    }

    func updateNSViewController(_ nsViewController: BrowserListViewController, context: Context) {
        nsViewController.update(model: model, items: items)
    }
}

@MainActor
private final class BrowserListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var model: AppModel
    private var items: [AppModel.BrowserItem]

    private let scrollView = NSScrollView()
    private let tableView = BrowserListTableView(frame: .zero)

    private var isApplyingProgrammaticSelection = false
    private var listThumbnailCache: [URL: NSImage] = [:]
    private var listThumbnailInflight: Set<URL> = []
    private var listThumbnailRequestVersion: [URL: Int] = [:]
    private var listThumbnailVersionCounter = 0
    private var lastThumbnailInvalidationToken = UUID()
    private var pendingInvalidatedThumbnailURLs: Set<URL> = []
    private var pendingThumbnailRefreshURLs: Set<URL> = []
    private var lastRenderedItemURLs: [URL] = []
    private var contextMenuTargetURLs: [URL] = []
    private var didApplyInitialColumnFit = false

    init(model: AppModel, items: [AppModel.BrowserItem]) {
        self.model = model
        self.items = items
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureList()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncTableWidthToViewportIfNeeded()
        applyInitialColumnFitIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        syncTableWidthToViewportIfNeeded()
        applyInitialColumnFitIfNeeded()
    }

    func update(model: AppModel, items: [AppModel.BrowserItem]) {
        self.model = model
        self.items = items

        if lastThumbnailInvalidationToken != model.browserThumbnailInvalidationToken {
            lastThumbnailInvalidationToken = model.browserThumbnailInvalidationToken
            let invalidated = model.browserThumbnailInvalidatedURLs
            pendingInvalidatedThumbnailURLs = invalidated
            if invalidated.isEmpty {
                listThumbnailCache.removeAll()
                listThumbnailInflight.removeAll()
                listThumbnailRequestVersion.removeAll()
                pendingThumbnailRefreshURLs.removeAll()
            } else {
                pendingThumbnailRefreshURLs.formUnion(invalidated)
                for url in invalidated {
                    listThumbnailInflight.remove(url)
                    listThumbnailRequestVersion.removeValue(forKey: url)
                }
            }
        }

        syncTableWidthToViewportIfNeeded()
        applyInitialColumnFitIfNeeded()
        if hasListChanged() {
            tableView.reloadData()
        } else {
            if pendingInvalidatedThumbnailURLs.isEmpty {
                tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< items.count), columnIndexes: IndexSet(integersIn: 0 ..< tableView.numberOfColumns))
            } else {
                let rowsToReload = IndexSet(items.enumerated().compactMap { index, item in
                    pendingInvalidatedThumbnailURLs.contains(item.url) ? index : nil
                })
                if rowsToReload.isEmpty {
                    tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< items.count), columnIndexes: IndexSet(integersIn: 0 ..< tableView.numberOfColumns))
                } else {
                    let nameColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
                    if nameColumn >= 0 {
                        tableView.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet(integer: nameColumn))
                    } else {
                        tableView.reloadData()
                    }
                }
            }
        }
        pendingInvalidatedThumbnailURLs = []

        let selectedIndexes = IndexSet(
            items.enumerated().compactMap { index, item in
                model.selectedFileURLs.contains(item.url) ? index : nil
            }
        )
        if tableView.selectedRowIndexes != selectedIndexes {
            isApplyingProgrammaticSelection = true
            tableView.selectRowIndexes(selectedIndexes, byExtendingSelection: false)
            isApplyingProgrammaticSelection = false
        }
        updateQuickLookSourceFrameFromCurrentSelection()
    }

    private func configureList() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView.translatesAutoresizingMaskIntoConstraints = true
        tableView.frame = NSRect(origin: .zero, size: scrollView.contentView.bounds.size)
        tableView.autoresizingMask = [.width]
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 24
        tableView.headerView = NSTableHeaderView()
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.gridStyleMask = []
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.target = self
        tableView.delegate = self
        tableView.dataSource = self

        tableView.onBackgroundClick = { [weak self] in
            self?.model.clearSelection()
        }
        tableView.onModifiedRowClick = { [weak self] row, modifiers in
            self?.handleModifiedRowClick(row: row, modifiers: modifiers)
        }
        tableView.contextMenuProvider = { [weak self] row in
            self?.menuForRow(row)
        }

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.minWidth = 60
        nameColumn.width = 320
        nameColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        let createdColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("created"))
        createdColumn.title = "Date Created"
        createdColumn.minWidth = 84
        createdColumn.width = 140
        createdColumn.resizingMask = .userResizingMask

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Size"
        sizeColumn.minWidth = 64
        sizeColumn.width = 90
        sizeColumn.resizingMask = .userResizingMask

        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kindColumn.title = "Kind"
        kindColumn.minWidth = 84
        kindColumn.width = 120
        kindColumn.resizingMask = .userResizingMask

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(createdColumn)
        tableView.addTableColumn(sizeColumn)
        tableView.addTableColumn(kindColumn)

        scrollView.documentView = tableView
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func syncTableWidthToViewportIfNeeded() {
        let width = scrollView.contentView.bounds.width
        guard width > 0 else { return }
        if abs(tableView.frame.width - width) > 0.5 {
            var frame = tableView.frame
            frame.size.width = width
            tableView.frame = frame
        }
    }

    private func applyInitialColumnFitIfNeeded() {
        guard !didApplyInitialColumnFit else { return }
        guard let nameColumn = tableView.tableColumns.first(where: { $0.identifier.rawValue == "name" }),
              let createdColumn = tableView.tableColumns.first(where: { $0.identifier.rawValue == "created" }),
              let sizeColumn = tableView.tableColumns.first(where: { $0.identifier.rawValue == "size" }),
              let kindColumn = tableView.tableColumns.first(where: { $0.identifier.rawValue == "kind" })
        else {
            return
        }

        let viewportWidth = scrollView.contentView.bounds.width
        guard viewportWidth > 0 else { return }

        let spacing = tableView.intercellSpacing.width * CGFloat(max(tableView.numberOfColumns - 1, 0))
        let fixedWidth = createdColumn.width + sizeColumn.width + kindColumn.width + spacing + 8
        let fittedNameWidth = max(nameColumn.minWidth, floor(viewportWidth - fixedWidth))
        nameColumn.width = fittedNameWidth
        tableView.tile()
        didApplyInitialColumnFit = true
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
                let pendingDot = NSView(frame: .zero)
                pendingDot.identifier = NSUserInterfaceItemIdentifier("pending-dot")
                pendingDot.translatesAutoresizingMaskIntoConstraints = false
                pendingDot.wantsLayer = true
                pendingDot.layer?.cornerRadius = 3
                pendingDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
                view.addSubview(pendingDot)

                let iconView = NSImageView(frame: .zero)
                iconView.identifier = NSUserInterfaceItemIdentifier("name-icon")
                iconView.translatesAutoresizingMaskIntoConstraints = false
                iconView.imageScaling = .scaleProportionallyDown
                view.addSubview(iconView)

                NSLayoutConstraint.activate([
                    pendingDot.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                    pendingDot.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    pendingDot.widthAnchor.constraint(equalToConstant: 6),
                    pendingDot.heightAnchor.constraint(equalToConstant: 6),
                    iconView.leadingAnchor.constraint(equalTo: pendingDot.trailingAnchor, constant: 6),
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
            if let pendingDot = cell.subviews.first(where: { $0.identifier?.rawValue == "pending-dot" }) {
                pendingDot.isHidden = !model.hasPendingEdits(for: item.url)
            }
            if let iconView = cell.subviews.first(where: { ($0 as? NSImageView)?.identifier?.rawValue == "name-icon" }) as? NSImageView {
                configureListIcon(iconView, for: item, atRow: row)
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
        let focusedURL: URL?
        if tableView.selectedRow >= 0, tableView.selectedRow < items.count {
            focusedURL = items[tableView.selectedRow].url
        } else {
            focusedURL = nil
        }
        model.setSelectionFromList(urls, focusedURL: focusedURL)
        updateQuickLookSourceFrameFromCurrentSelection()
    }

    @objc
    private func doubleClicked(_ sender: Any?) {
        guard let tableView = sender as? NSTableView else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        model.openInDefaultApp(items[row].url)
    }

    private func menuForRow(_ row: Int) -> NSMenu? {
        guard row >= 0, row < items.count else { return nil }
        let clickedURL = items[row].url

        let targetURLs: [URL]
        if model.selectedFileURLs.contains(clickedURL) {
            targetURLs = items.compactMap { item in
                model.selectedFileURLs.contains(item.url) ? item.url : nil
            }
        } else {
            targetURLs = [clickedURL]
            model.setSelectionFromList(Set(targetURLs), focusedURL: clickedURL)
            isApplyingProgrammaticSelection = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isApplyingProgrammaticSelection = false
        }

        contextMenuTargetURLs = targetURLs
        let openAppName = model.defaultAppDisplayName(for: targetURLs.first)
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open in \(openAppName)", action: #selector(openFromContextMenu(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let hasPending = targetURLs.contains { model.hasPendingEdits(for: $0) }
        let hasRestorable = targetURLs.contains { model.hasRestorableBackup(for: $0) }

        let applyItem = NSMenuItem(title: "Apply Metadata Changes", action: #selector(applyFromContextMenu(_:)), keyEquivalent: "")
        applyItem.target = self
        applyItem.isEnabled = hasPending
        menu.addItem(applyItem)

        let refreshItem = NSMenuItem(title: "Refresh Metadata", action: #selector(refreshFromContextMenu(_:)), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let clearItem = NSMenuItem(title: "Clear Metadata Changes", action: #selector(clearFromContextMenu(_:)), keyEquivalent: "")
        clearItem.target = self
        clearItem.isEnabled = hasPending
        menu.addItem(clearItem)

        let restoreItem = NSMenuItem(title: "Restore from Last Backup", action: #selector(restoreFromContextMenu(_:)), keyEquivalent: "")
        restoreItem.target = self
        restoreItem.isEnabled = hasRestorable
        menu.addItem(restoreItem)
        return menu
    }

    @objc
    private func openFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.openInDefaultApp(contextMenuTargetURLs)
    }

    @objc
    private func applyFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.applyChanges(for: contextMenuTargetURLs)
    }

    @objc
    private func refreshFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.refreshMetadata(for: contextMenuTargetURLs)
    }

    @objc
    private func clearFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.clearPendingEdits(for: contextMenuTargetURLs)
    }

    @objc
    private func restoreFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.restoreLastOperation(for: contextMenuTargetURLs)
    }

    private func handleModifiedRowClick(row: Int, modifiers: NSEvent.ModifierFlags) {
        guard row >= 0, row < items.count else { return }
        model.selectFile(items[row].url, modifiers: modifiers, in: items)

        let selectedIndexes = IndexSet(
            items.enumerated().compactMap { index, item in
                model.selectedFileURLs.contains(item.url) ? index : nil
            }
        )
        isApplyingProgrammaticSelection = true
        tableView.selectRowIndexes(selectedIndexes, byExtendingSelection: false)
        isApplyingProgrammaticSelection = false
        updateQuickLookSourceFrameFromCurrentSelection()
    }

    private func hasListChanged() -> Bool {
        let currentURLs = items.map(\.url)
        guard currentURLs != lastRenderedItemURLs else { return false }
        lastRenderedItemURLs = currentURLs
        return true
    }

    private func updateQuickLookSourceFrameFromCurrentSelection() {
        guard model.browserViewMode == .list else { return }
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
            if let iconImageView = iconView as? NSImageView {
                model.setQuickLookTransitionImage(for: item.url, image: quickLookTransitionSnapshot(for: iconImageView))
            }
        }
    }

    private func quickLookTransitionSnapshot(for iconView: NSImageView) -> NSImage? {
        guard iconView.bounds.width > 0, iconView.bounds.height > 0 else {
            return iconView.image
        }
        guard let rep = iconView.bitmapImageRepForCachingDisplay(in: iconView.bounds) else {
            return iconView.image
        }
        iconView.cacheDisplay(in: iconView.bounds, to: rep)
        let image = NSImage(size: iconView.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func configureListIcon(_ iconView: NSImageView, for item: AppModel.BrowserItem, atRow row: Int) {
        iconView.toolTip = item.url.path
        let isActiveListView = model.browserViewMode == .list

        if isActiveListView, model.selectedFileURLs.contains(item.url), let window = tableView.window {
            let iconRectInTable = iconView.convert(iconView.bounds, to: tableView)
            let iconRectInWindow = tableView.convert(iconRectInTable, to: nil)
            let iconRectOnScreen = window.convertToScreen(iconRectInWindow)
            model.setQuickLookSourceFrame(for: item.url, rectOnScreen: iconRectOnScreen)
        }

        if let cached = listThumbnailCache[item.url] {
            iconView.image = cached
            if isActiveListView {
                model.setQuickLookTransitionImage(for: item.url, image: quickLookTransitionSnapshot(for: iconView))
            }
            requestListThumbnailIfNeeded(for: item, row: row, forceRefresh: pendingThumbnailRefreshURLs.contains(item.url))
            return
        }

        if isLikelyImageFile(item.url) {
            iconView.image = nil
        } else {
            let fallback = NSWorkspace.shared.icon(forFile: item.url.path)
            fallback.size = NSSize(width: 16, height: 16)
            iconView.image = fallback
        }
        if isActiveListView {
            model.setQuickLookTransitionImage(for: item.url, image: quickLookTransitionSnapshot(for: iconView))
        }

        requestListThumbnailIfNeeded(for: item, row: row, forceRefresh: pendingThumbnailRefreshURLs.contains(item.url))
    }

    private func requestListThumbnailIfNeeded(for item: AppModel.BrowserItem, row: Int, forceRefresh: Bool) {
        if !forceRefresh, listThumbnailCache[item.url] != nil { return }
        guard !listThumbnailInflight.contains(item.url) else { return }
        listThumbnailInflight.insert(item.url)
        listThumbnailVersionCounter += 1
        let requestVersion = listThumbnailVersionCounter
        listThumbnailRequestVersion[item.url] = requestVersion

        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                var image = generateOrientedBrowserThumbnail(fileURL: item.url, maxPixelSize: 64)
                if image == nil {
                    image = await generateQuickLookThumbnail(fileURL: item.url, maxPixelSize: 64)
                }
                if image == nil {
                    image = NSImage(contentsOf: item.url)
                }
                if image == nil, !isLikelyImageFile(item.url) {
                    let fallback = NSWorkspace.shared.icon(forFile: item.url.path)
                    fallback.size = NSSize(width: 16, height: 16)
                    image = fallback
                }
                return image
            }.value

            guard let self else { return }
            self.listThumbnailInflight.remove(item.url)
            guard self.listThumbnailRequestVersion[item.url] == requestVersion else { return }
            self.pendingThumbnailRefreshURLs.remove(item.url)
            guard let image else { return }
            self.listThumbnailCache[item.url] = image

            guard self.items.indices.contains(row), self.items[row].url == item.url else { return }
            let nameColumn = self.tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            guard nameColumn >= 0,
                  let nameCell = self.tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: false) as? NSTableCellView,
                  let currentIcon = nameCell.subviews.first(where: { ($0 as? NSImageView)?.identifier?.rawValue == "name-icon" }) as? NSImageView,
                  currentIcon.toolTip == item.url.path
            else {
                return
            }

            currentIcon.alphaValue = 1
            currentIcon.image = image

            if self.model.browserViewMode == .list {
                self.model.setQuickLookTransitionImage(for: item.url, image: self.quickLookTransitionSnapshot(for: currentIcon))
            }
        }
    }
}

private final class BrowserListTableView: NSTableView {
    var onBackgroundClick: (() -> Void)?
    var onModifiedRowClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        if clickedRow == -1 {
            deselectAll(nil)
            onBackgroundClick?()
            return
        }

        let selectionModifiers = event.modifierFlags.intersection([.command, .shift])
        if !selectionModifiers.isEmpty {
            onModifiedRowClick?(clickedRow, selectionModifiers)
            return
        }

        if clickedRow >= 0 {
            super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else { return nil }
        return contextMenuProvider?(clickedRow)
    }
}

private struct BrowserGalleryView: View {
    @ObservedObject var model: AppModel
    private let topScrollStartInset: CGFloat = 56

    var body: some View {
        BrowserGalleryCollectionRepresentable(
            model: model,
            items: model.filteredBrowserItems
        )
        .ignoresSafeArea(.container, edges: .top)
        .safeAreaPadding(.top, topScrollStartInset)
    }
}

private struct BrowserGalleryCollectionRepresentable: NSViewControllerRepresentable {
    @ObservedObject var model: AppModel
    let items: [AppModel.BrowserItem]

    func makeNSViewController(context: Context) -> BrowserGalleryViewController {
        BrowserGalleryViewController(model: model, items: items)
    }

    func updateNSViewController(_ nsViewController: BrowserGalleryViewController, context: Context) {
        nsViewController.update(model: model, items: items)
    }
}

@MainActor
private final class BrowserGalleryViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private var model: AppModel
    private var items: [AppModel.BrowserItem]

    private let scrollView = NSScrollView()
    private let collectionView = AppKitGalleryCollectionView()
    private let layout = AppKitGalleryLayout()

    private var isApplyingProgrammaticSelection = false
    private var contextMenuTargetURLs: [URL] = []
    private var lastRenderedURLs: [URL] = []
    private var lastRenderedSelected: Set<URL> = []
    private var lastRenderedPending: Set<URL> = []
    private var lastRenderedPrimarySelectionURL: URL?
    private var thumbnailCache: [URL: NSImage] = [:]
    private var thumbnailRenderedSide: [URL: CGFloat] = [:]
    private var thumbnailInflight: Set<URL> = []
    private var thumbnailRequestVersion: [URL: Int] = [:]
    private var thumbnailVersionCounter = 0
    private var lastThumbnailInvalidationToken = UUID()
    private var pendingThumbnailRefreshURLs: Set<URL> = []
    private var pinchAccumulator: CGFloat = 0
    private var lastMagnification: CGFloat = 0
    private let pinchThreshold: CGFloat = 0.14

    init(model: AppModel, items: [AppModel.BrowserItem]) {
        self.model = model
        self.items = items
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
    }

    func update(model: AppModel, items: [AppModel.BrowserItem]) {
        self.model = model
        self.items = items
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

    private func renderState() {
        if lastThumbnailInvalidationToken != model.browserThumbnailInvalidationToken {
            lastThumbnailInvalidationToken = model.browserThumbnailInvalidationToken
            let invalidated = model.browserThumbnailInvalidatedURLs
            if invalidated.isEmpty {
                thumbnailCache.removeAll()
                thumbnailRenderedSide.removeAll()
                thumbnailInflight.removeAll()
                thumbnailRequestVersion.removeAll()
                pendingThumbnailRefreshURLs.removeAll()
                collectionView.reloadData()
            } else {
                pendingThumbnailRefreshURLs.formUnion(invalidated)
                for url in invalidated {
                    thumbnailInflight.remove(url)
                    thumbnailRequestVersion.removeValue(forKey: url)
                }
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
        let columnsChanged = layout.columnCount != model.galleryColumnCount
        let selectionChanged = selectedURLs != lastRenderedSelected
        let pendingChanged = pendingURLs != lastRenderedPending
        let primaryChanged = model.primarySelectionURL != lastRenderedPrimarySelectionURL

        if listChanged {
            let urlSet = Set(currentURLs)
            thumbnailCache = thumbnailCache.filter { urlSet.contains($0.key) }
            thumbnailRenderedSide = thumbnailRenderedSide.filter { urlSet.contains($0.key) }
        }

        if columnsChanged {
            layout.columnCount = max(model.galleryColumnCount, 1)
            layout.invalidateLayout()
        }

        if listChanged || columnsChanged {
            collectionView.reloadData()
            lastRenderedURLs = currentURLs
        }

        if listChanged || columnsChanged || selectionChanged {
            syncSelection(selectedURLs: selectedURLs, scrollPrimaryIntoView: primaryChanged)
            lastRenderedSelected = selectedURLs
            lastRenderedPrimarySelectionURL = model.primarySelectionURL
        }

        if listChanged || columnsChanged || selectionChanged || pendingChanged {
            refreshVisibleCellState(pendingURLs: pendingURLs, selectedURLs: selectedURLs)
            lastRenderedPending = pendingURLs
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

    private func refreshVisibleCellState(pendingURLs: Set<URL>, selectedURLs: Set<URL>) {
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard indexPath.item >= 0, indexPath.item < items.count else { continue }
            guard let cell = collectionView.item(at: indexPath) as? AppKitGalleryItem else { continue }
            let item = items[indexPath.item]
            cell.applySelection(isSelected: selectedURLs.contains(item.url))
            cell.applyPending(hasPendingEdits: pendingURLs.contains(item.url))
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
        model.setQuickLookTransitionImage(for: primaryURL, image: quickLookTransitionSnapshot(for: imageView))
    }

    private func quickLookTransitionSnapshot(for imageView: NSImageView) -> NSImage? {
        guard imageView.bounds.width > 0, imageView.bounds.height > 0 else {
            return imageView.image
        }
        guard let rep = imageView.bitmapImageRepForCachingDisplay(in: imageView.bounds) else {
            return imageView.image
        }
        imageView.cacheDisplay(in: imageView.bounds, to: rep)
        let image = NSImage(size: imageView.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func requestThumbnailIfNeeded(for item: AppModel.BrowserItem, tileSide: CGFloat) {
        let requiredSide = max(tileSide, 120)
        let forceRefresh = pendingThumbnailRefreshURLs.contains(item.url)
        if !forceRefresh,
           let renderedSide = thumbnailRenderedSide[item.url],
           renderedSide >= requiredSide * 0.9,
           thumbnailCache[item.url] != nil {
            return
        }
        guard !thumbnailInflight.contains(item.url) else { return }
        thumbnailInflight.insert(item.url)
        thumbnailVersionCounter += 1
        let requestVersion = thumbnailVersionCounter
        thumbnailRequestVersion[item.url] = requestVersion

        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                var image = generateOrientedBrowserThumbnail(fileURL: item.url, maxPixelSize: requiredSide * 2)
                if image == nil {
                    image = await generateQuickLookThumbnail(fileURL: item.url, maxPixelSize: requiredSide * 2)
                }
                if image == nil {
                    image = NSImage(contentsOf: item.url)
                }
                if image == nil, !isLikelyImageFile(item.url) {
                    let fallback = NSWorkspace.shared.icon(forFile: item.url.path)
                    fallback.size = NSSize(width: 128, height: 128)
                    image = fallback
                }
                return image
            }.value

            guard let self else { return }
            self.thumbnailInflight.remove(item.url)
            guard self.thumbnailRequestVersion[item.url] == requestVersion else { return }
            guard let image else { return }
            self.thumbnailCache[item.url] = image
            self.thumbnailRenderedSide[item.url] = requiredSide
            self.pendingThumbnailRefreshURLs.remove(item.url)

            guard let row = self.items.firstIndex(where: { $0.url == item.url }) else { return }
            let indexPath = IndexPath(item: row, section: 0)
            guard let cell = self.collectionView.item(at: indexPath) as? AppKitGalleryItem else { return }
            cell.configure(
                name: item.name,
                image: image,
                isSelected: self.model.selectedFileURLs.contains(item.url),
                hasPendingEdits: self.model.hasPendingEdits(for: item.url),
                tileSide: max(self.layout.tileSide, 40)
            )
            self.updateQuickLookArtifacts()
        }
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

        let openAppName = model.defaultAppDisplayName(for: contextMenuTargetURLs.first)
        let hasPending = contextMenuTargetURLs.contains { model.hasPendingEdits(for: $0) }
        let hasRestorable = contextMenuTargetURLs.contains { model.hasRestorableBackup(for: $0) }

        func makeItem(_ title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            return item
        }

        let menu = NSMenu()
        menu.addItem(makeItem("Open in \(openAppName)", action: #selector(openFromContextMenu(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem("Apply Metadata Changes", action: #selector(applyFromContextMenu(_:)), enabled: hasPending))
        menu.addItem(makeItem("Refresh Metadata", action: #selector(refreshFromContextMenu(_:))))
        menu.addItem(makeItem("Clear Metadata Changes", action: #selector(clearFromContextMenu(_:)), enabled: hasPending))
        menu.addItem(makeItem("Restore from Last Backup", action: #selector(restoreFromContextMenu(_:)), enabled: hasRestorable))
        return menu
    }

    @objc
    private func openFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.openInDefaultApp(contextMenuTargetURLs)
    }

    @objc
    private func applyFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.applyChanges(for: contextMenuTargetURLs)
    }

    @objc
    private func refreshFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.refreshMetadata(for: contextMenuTargetURLs)
    }

    @objc
    private func clearFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.clearPendingEdits(for: contextMenuTargetURLs)
    }

    @objc
    private func restoreFromContextMenu(_: Any?) {
        guard !contextMenuTargetURLs.isEmpty else { return }
        model.restoreLastOperation(for: contextMenuTargetURLs)
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
        let image = thumbnailCache[item.url] ?? {
            if isLikelyImageFile(item.url) {
                return nil
            }
            let fallback = NSWorkspace.shared.icon(forFile: item.url.path)
            fallback.size = NSSize(width: 128, height: 128)
            return fallback
        }()

        cell.configure(
            name: item.name,
            image: image,
            isSelected: model.selectedFileURLs.contains(item.url),
            hasPendingEdits: model.hasPendingEdits(for: item.url),
            tileSide: max(layout.tileSide, 40)
        )
        requestThumbnailIfNeeded(for: item, tileSide: max(layout.tileSide, 40))
        return cell
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
}

private final class AppKitGalleryCollectionView: NSCollectionView {
    var onBackgroundClick: (() -> Void)?
    var onMoveSelection: ((MoveCommandDirection) -> Void)?
    var contextMenuProvider: ((IndexPath) -> NSMenu?)?
    var onDoubleClick: ((IndexPath) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else {
            deselectAll(nil)
            onBackgroundClick?()
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

        if event.keyCode == 53 {
            deselectAll(nil)
            onBackgroundClick?()
            return
        }

        let direction: MoveCommandDirection?
        switch event.keyCode {
        case 123: direction = .left
        case 124: direction = .right
        case 125: direction = .down
        case 126: direction = .up
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

    private let defaultInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    private let horizontalSpacing: CGFloat = 12
    private let verticalSpacing: CGFloat = 14
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
        let side = floor(usableWidth / CGFloat(columns))
        itemSize = NSSize(width: side, height: side + titleGap + titleHeight)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        true
    }
}

private final class AppKitGalleryItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AppKitGalleryItem")

    let thumbnailImageView = NSImageView(frame: .zero)
    private let thumbnailContainer = NSView(frame: .zero)
    private let selectionOverlay = NSView(frame: .zero)
    private let pendingDot = NSView(frame: .zero)
    private let titleField = NSTextField(labelWithString: "")
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?
    private var overlayWidthConstraint: NSLayoutConstraint?
    private var overlayHeightConstraint: NSLayoutConstraint?

    override func loadView() {
        view = NSView(frame: .zero)
        configureViewHierarchy()
    }

    private func configureViewHierarchy() {
        view.wantsLayer = true

        thumbnailContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.wantsLayer = true
        view.addSubview(thumbnailContainer)

        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = 8
        thumbnailImageView.layer?.masksToBounds = true
        thumbnailContainer.addSubview(thumbnailImageView)

        selectionOverlay.translatesAutoresizingMaskIntoConstraints = false
        selectionOverlay.wantsLayer = true
        selectionOverlay.layer?.cornerRadius = 8
        selectionOverlay.layer?.masksToBounds = true
        selectionOverlay.layer?.borderWidth = 2
        selectionOverlay.layer?.borderColor = NSColor.clear.cgColor
        thumbnailContainer.addSubview(selectionOverlay)

        pendingDot.translatesAutoresizingMaskIntoConstraints = false
        pendingDot.wantsLayer = true
        pendingDot.layer?.cornerRadius = 4
        pendingDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
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

            thumbnailImageView.centerXAnchor.constraint(equalTo: thumbnailContainer.centerXAnchor),
            thumbnailImageView.centerYAnchor.constraint(equalTo: thumbnailContainer.centerYAnchor),

            selectionOverlay.centerXAnchor.constraint(equalTo: thumbnailContainer.centerXAnchor),
            selectionOverlay.centerYAnchor.constraint(equalTo: thumbnailContainer.centerYAnchor),

            pendingDot.widthAnchor.constraint(equalToConstant: 8),
            pendingDot.heightAnchor.constraint(equalToConstant: 8),
            pendingDot.trailingAnchor.constraint(equalTo: selectionOverlay.trailingAnchor, constant: -6),
            pendingDot.topAnchor.constraint(equalTo: selectionOverlay.topAnchor, constant: 6),

            titleField.topAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: 6),
            titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleField.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titleField.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])

        imageWidthConstraint = thumbnailImageView.widthAnchor.constraint(equalToConstant: 20)
        imageHeightConstraint = thumbnailImageView.heightAnchor.constraint(equalToConstant: 20)
        overlayWidthConstraint = selectionOverlay.widthAnchor.constraint(equalToConstant: 20)
        overlayHeightConstraint = selectionOverlay.heightAnchor.constraint(equalToConstant: 20)
        imageWidthConstraint?.isActive = true
        imageHeightConstraint?.isActive = true
        overlayWidthConstraint?.isActive = true
        overlayHeightConstraint?.isActive = true
    }

    func configure(name: String, image: NSImage?, isSelected: Bool, hasPendingEdits: Bool, tileSide: CGFloat) {
        titleField.stringValue = name
        setImage(image)
        applySelection(isSelected: isSelected)
        applyPending(hasPendingEdits: hasPendingEdits)
        let fitted = fittedThumbnailSize(for: image?.size, in: tileSide)
        imageWidthConstraint?.constant = fitted.width
        imageHeightConstraint?.constant = fitted.height
        overlayWidthConstraint?.constant = fitted.width
        overlayHeightConstraint?.constant = fitted.height
    }

    func applySelection(isSelected: Bool) {
        selectionOverlay.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
    }

    func applyPending(hasPendingEdits: Bool) {
        pendingDot.isHidden = !hasPendingEdits
    }

    func setImage(_ image: NSImage?) {
        if thumbnailImageView.image !== image {
            thumbnailImageView.alphaValue = 1
            thumbnailImageView.image = image
        }
    }

    private func fittedThumbnailSize(for imageSize: CGSize?, in side: CGFloat) -> CGSize {
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: side, height: side)
        }
        let widthRatio = side / imageSize.width
        let heightRatio = side / imageSize.height
        let scale = min(widthRatio, heightRatio)
        return CGSize(width: max(1, floor(imageSize.width * scale)), height: max(1, floor(imageSize.height * scale)))
    }
}
struct InspectorView: View {
    @ObservedObject var model: AppModel
    private let topScrollStartInset: CGFloat = 56
    private let contentHorizontalInset: CGFloat = 16
    private let sectionInnerInset: CGFloat = 12
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
    @FocusState private var focusedTagID: String?
    @State private var editSessionSnapshots: [String: AppModel.EditSessionSnapshot] = [:]
    @State private var activeEditTagID: String?

    var body: some View {
        ScrollViewReader { proxy in
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
                            Text(first.deletingPathExtension().lastPathComponent)
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let subtitle = singleSelectionSubtitle {
                                Text(subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        } else {
                            Text("\(model.selectedFileURLs.count) photos selected")
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let subtitle = multiSelectionSubtitle {
                                Text(subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, contentHorizontalInset)

                    if model.selectedFileURLs.count == 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    model.toggleInspectorSection("Preview")
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: model.isInspectorSectionCollapsed("Preview") ? "chevron.right" : "chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 10, alignment: .center)
                                    Text("PREVIEW")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color(nsColor: .systemYellow))
                                        .tracking(0.4)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if !model.isInspectorSectionCollapsed("Preview"),
                               let previewURL = primarySelectedFileURL {
                                VStack(spacing: 10) {
                                    InspectorPreviewImageView(model: model, fileURL: previewURL)
                                        .frame(maxWidth: .infinity)

                                    Divider()

                                    HStack(spacing: 0) {
                                        Button {
                                            model.rotateLeft(fileURL: previewURL)
                                        } label: {
                                            VStack(spacing: 4) {
                                                Image(systemName: "rotate.left")
                                                    .font(.body)
                                                Text("Rotate")
                                                    .font(.caption)
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)

                                        Divider()
                                            .frame(height: 28)

                                        Button {
                                            model.flipHorizontal(fileURL: previewURL)
                                        } label: {
                                            VStack(spacing: 4) {
                                                Image(systemName: "flip.horizontal")
                                                    .font(.body)
                                                Text("Flip")
                                                    .font(.caption)
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)

                                        Divider()
                                            .frame(height: 28)

                                        Button {
                                            model.openInDefaultApp(previewURL)
                                        } label: {
                                            VStack(spacing: 4) {
                                                Image(systemName: "arrow.up.forward.app")
                                                    .font(.body)
                                                Text("Open")
                                                    .font(.caption)
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(sectionInnerInset)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.quaternary.opacity(0.35))
                                )
                            }
                        }
                        .padding(.horizontal, contentHorizontalInset)
                    }

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
                                        .frame(width: 10, alignment: .center)
                                    Text(grouped.section.uppercased())
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color(nsColor: .systemYellow))
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
                                            HStack(spacing: 6) {
                                                if model.hasPendingChange(for: tag) {
                                                    Circle()
                                                        .fill(.orange)
                                                        .frame(width: 6, height: 6)
                                                }
                                                Text(tag.label)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if model.isDateTimeTag(tag) {
                                                if let date = model.dateValueForTag(tag) {
                                                    HStack(spacing: 6) {
                                                        FullWidthDateTimePicker(
                                                            selection: Binding(
                                                                get: { model.dateValueForTag(tag) ?? date },
                                                                set: {
                                                                    beginEditSessionIfNeeded(for: tag)
                                                                    model.updateDateValue($0, for: tag)
                                                                }
                                                            )
                                                        )
                                                        .frame(maxWidth: .infinity, alignment: .leading)

                                                        Button {
                                                            beginEditSessionIfNeeded(for: tag)
                                                            model.clearDateValue(for: tag)
                                                        } label: {
                                                            Image(systemName: "xmark.circle.fill")
                                                                .foregroundStyle(.secondary)
                                                        }
                                                        .buttonStyle(.plain)
                                                        .help("Clear date/time")
                                                    }
                                                } else {
                                                    HStack(spacing: 6) {
                                                        if model.isMixedValue(for: tag) {
                                                            HStack {
                                                                Text("Multiple values")
                                                                    .foregroundStyle(.secondary)
                                                                    .font(.body)
                                                                Spacer(minLength: 0)
                                                            }
                                                            .padding(.horizontal, 10)
                                                            .padding(.vertical, 6)
                                                            .frame(maxWidth: .infinity, alignment: .leading)
                                                            .background(
                                                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                                    .strokeBorder(.quaternary, lineWidth: 1)
                                                            )
                                                        } else {
                                                            TextField("", text: .constant(""))
                                                                .textFieldStyle(.roundedBorder)
                                                                .disabled(true)
                                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                        }

                                                        Button("Set") {
                                                            beginEditSessionIfNeeded(for: tag)
                                                            model.updateDateValue(Date(), for: tag)
                                                        }
                                                        .controlSize(.small)
                                                    }
                                                }
                                            } else if let options = model.pickerOptions(for: tag) {
                                                FullWidthPopupPicker(
                                                    options: options,
                                                    selection: Binding(
                                                        get: { model.valueForTag(tag) },
                                                        set: {
                                                            beginEditSessionIfNeeded(for: tag)
                                                            model.updateValue($0, for: tag)
                                                        }
                                                    )
                                                )
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            } else {
                                                TextField(
                                                    "",
                                                    text: Binding(
                                                        get: { model.valueForTag(tag) },
                                                        set: {
                                                            beginEditSessionIfNeeded(for: tag)
                                                            model.updateValue($0, for: tag)
                                                        }
                                                    ),
                                                    prompt: Text(model.isMixedValue(for: tag) ? "Multiple values" : model.placeholderForTag(tag))
                                                        .foregroundStyle(.secondary),
                                                    axis: .vertical
                                                )
                                                .textFieldStyle(.roundedBorder)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .focused($focusedTagID, equals: tag.id)
                                            }
                                        }
                                        .id(tag.id)
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
            .onChange(of: focusedTagID) { _, newValue in
                guard let newValue else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(newValue)
                    }
                }
            }
        }
        .onChange(of: focusedTagID) { oldValue, newValue in
            guard let newValue,
                  let tag = AppModel.EditableTag.common.first(where: { $0.id == newValue })
            else {
                return
            }
            editSessionSnapshots[newValue] = model.makeEditSessionSnapshot(for: tag)
            activeEditTagID = newValue
        }
        .onChange(of: model.selectedFileURLs) { _, _ in
            editSessionSnapshots.removeAll()
            focusedTagID = nil
            activeEditTagID = nil
        }
        .onExitCommand {
            let targetTagID = focusedTagID ?? activeEditTagID
            guard let targetTagID,
                  let snapshot = editSessionSnapshots[targetTagID]
            else {
                self.focusedTagID = nil
                NotificationCenter.default.post(name: .inspectorDidRequestBrowserFocus, object: nil)
                return
            }

            // Mixed-value text fields can emit a late commit after Esc.
            // Restore twice (now and next runloop) so staged edits are truly cleared.
            model.restoreEditSession(snapshot)
            DispatchQueue.main.async {
                model.restoreEditSession(snapshot)
            }
            editSessionSnapshots.removeValue(forKey: targetTagID)
            activeEditTagID = nil
            self.focusedTagID = nil
            NotificationCenter.default.post(name: .inspectorDidRequestBrowserFocus, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .inspectorDidRequestFieldNavigation)) { notification in
            let backward = (notification.userInfo?["backward"] as? Bool) ?? false
            moveInspectorFieldFocus(backward: backward)
        }
        .sheet(item: $model.activePresetEditor) { editor in
            PresetEditorSheet(
                model: model,
                initialEditor: editor
            )
        }
        .sheet(isPresented: $model.isImportConflictSheetPresented) {
            ImportConflictResolutionSheet(model: model)
        }
        .sheet(isPresented: $model.isManagePresetsPresented) {
            PresetManagerSheet(model: model)
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

    private var primarySelectedFileURL: URL? {
        model.selectedFileURLs.sorted { $0.path < $1.path }.first
    }

    private var singleSelectionSubtitle: String? {
        guard model.selectedFileURLs.count == 1,
              let url = primarySelectedFileURL
        else {
            return nil
        }

        let browserItem = model.browserItems.first(where: { $0.url == url })
        let typeText = browserItem?.kind ?? {
            let ext = url.pathExtension.uppercased()
            return ext.isEmpty ? "Unknown" : ext
        }()
        let sizeText: String = {
            if let size = browserItem?.sizeBytes, size >= 0 {
                return Self.byteCountFormatter.string(fromByteCount: Int64(size))
            }
            return "—"
        }()

        var parts: [String] = [typeText, sizeText]
        if let (width, height) = imageDimensions(for: url),
           width > 0, height > 0 {
            parts.append("\(width)×\(height)")
            let megapixels = (Double(width) * Double(height)) / 1_000_000
            parts.append(String(format: "%.1f MP", megapixels))
        }
        return parts.joined(separator: " • ")
    }

    private var multiSelectionSubtitle: String? {
        let selectedItems = model.browserItems.filter { model.selectedFileURLs.contains($0.url) }
        guard !selectedItems.isEmpty else { return nil }

        let selectedCount = selectedItems.count
        let nonEmptyTypes = selectedItems
            .compactMap { $0.kind?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let uniqueTypes = Set(nonEmptyTypes)
        let typeSummary: String = {
            if uniqueTypes.count == 1, let only = uniqueTypes.first {
                return only
            }
            return "Mixed types"
        }()

        let totalSize = selectedItems.reduce(Int64(0)) { partial, item in
            partial + Int64(max(item.sizeBytes ?? 0, 0))
        }
        let totalSizeText = Self.byteCountFormatter.string(fromByteCount: totalSize)

        return "\(typeSummary), \(selectedCount) selected • \(totalSizeText) total"
    }

    private func imageDimensions(for url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return (width, height)
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

    private func beginEditSessionIfNeeded(for tag: AppModel.EditableTag) {
        if editSessionSnapshots[tag.id] == nil {
            editSessionSnapshots[tag.id] = model.makeEditSessionSnapshot(for: tag)
        }
        activeEditTagID = tag.id
    }

    private func moveInspectorFieldFocus(backward: Bool) {
        let focusableTagIDs = model.groupedEditableTags
            .filter { !model.isInspectorSectionCollapsed($0.section) }
            .flatMap(\.tags)
            .filter { tag in
                !model.isDateTimeTag(tag) && model.pickerOptions(for: tag) == nil
            }
            .map(\.id)

        guard !focusableTagIDs.isEmpty else { return }

        let current = focusedTagID ?? activeEditTagID
        let nextID: String

        if let current,
           let currentIndex = focusableTagIDs.firstIndex(of: current) {
            let delta = backward ? -1 : 1
            let nextIndex = (currentIndex + delta + focusableTagIDs.count) % focusableTagIDs.count
            nextID = focusableTagIDs[nextIndex]
        } else {
            nextID = backward ? focusableTagIDs.last! : focusableTagIDs.first!
        }

        focusedTagID = nextID
        activeEditTagID = nextID
    }
}

private struct PresetEditorSheet: View {
    @ObservedObject var model: AppModel
    @State private var editor: PresetEditorState
    @State private var validationMessage: String?
    @State private var duplicateConflict: MetadataPreset?

    init(model: AppModel, initialEditor: PresetEditorState) {
        self.model = model
        _editor = State(initialValue: initialEditor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editorTitle)
                .font(.title3.weight(.semibold))

            HStack {
                Text("Name")
                    .frame(width: 70, alignment: .leading)
                TextField("Preset name", text: $editor.name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top) {
                Text("Notes")
                    .frame(width: 70, alignment: .leading)
                    .padding(.top, 6)
                TextField("Optional notes", text: $editor.notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 3)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.groupedEditableTags, id: \.section) { grouped in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(grouped.section.uppercased())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.4)

                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(grouped.tags) { tag in
                                    HStack(alignment: .top, spacing: 10) {
                                        Toggle("", isOn: includeBinding(for: tag))
                                            .labelsHidden()
                                            .toggleStyle(.checkbox)
                                            .padding(.top, 3)

                                        Text(tag.label)
                                            .font(.callout)
                                            .frame(width: 160, alignment: .leading)
                                            .padding(.top, 4)

                                        presetControl(for: tag)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.quaternary.opacity(0.35))
                            )
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.dismissPresetEditor() }
                    .keyboardShortcut(.cancelAction)
                Button(editorPrimaryButtonTitle) {
                    handleSave()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 640)
        .alert("Preset name already exists", isPresented: duplicateAlertBinding) {
            Button("Replace") {
                replaceExistingPreset()
            }
            Button("Duplicate") {
                saveAsDuplicate()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let duplicateConflict {
                Text("A preset named “\(duplicateConflict.name)” already exists.")
            } else {
                Text("A preset with this name already exists.")
            }
        }
    }

    private var editorTitle: String {
        switch editor.mode {
        case .createFromCurrent:
            return "Save Current as Preset"
        case .createBlank:
            return "Add Preset"
        case .edit:
            return "Edit Preset"
        }
    }

    private var editorPrimaryButtonTitle: String {
        switch editor.mode {
        case .createFromCurrent, .createBlank:
            return "Save Preset"
        case .edit:
            return "Update Preset"
        }
    }

    private var duplicateAlertBinding: Binding<Bool> {
        Binding(
            get: { duplicateConflict != nil },
            set: { newValue in
                if !newValue { duplicateConflict = nil }
            }
        )
    }

    private func includeBinding(for tag: AppModel.EditableTag) -> Binding<Bool> {
        Binding(
            get: { editor.includedTagIDs.contains(tag.id) },
            set: { include in
                if include {
                    editor.includedTagIDs.insert(tag.id)
                } else {
                    editor.includedTagIDs.remove(tag.id)
                }
            }
        )
    }

    private func valueBinding(for tag: AppModel.EditableTag) -> Binding<String> {
        Binding(
            get: { editor.valuesByTagID[tag.id] ?? "" },
            set: { editor.valuesByTagID[tag.id] = $0 }
        )
    }

    @ViewBuilder
    private func presetControl(for tag: AppModel.EditableTag) -> some View {
        if model.isDateTimeTag(tag) {
            let raw = editor.valuesByTagID[tag.id] ?? ""
            if let date = model.parseEditableDateValue(raw) {
                HStack(spacing: 6) {
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { model.parseEditableDateValue(editor.valuesByTagID[tag.id] ?? "") ?? date },
                            set: { editor.valuesByTagID[tag.id] = model.formatEditableDateValue($0) }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .datePickerStyle(.field)

                    Button {
                        editor.valuesByTagID[tag.id] = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 6) {
                    TextField("", text: .constant(""))
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button("Set") {
                        editor.valuesByTagID[tag.id] = model.formatEditableDateValue(Date())
                    }
                    .controlSize(.small)
                }
            }
        } else if let options = presetPickerOptions(for: tag) {
            Picker("", selection: valueBinding(for: tag)) {
                Text("Not Set").tag("")
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        } else {
            TextField("", text: valueBinding(for: tag), axis: .vertical)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func presetPickerOptions(for tag: AppModel.EditableTag) -> [AppModel.PickerOption]? {
        switch tag.id {
        case "exif-exposure-program":
            return [
                .init(value: "0", label: "Not Defined"),
                .init(value: "1", label: "Manual"),
                .init(value: "2", label: "Program AE"),
                .init(value: "3", label: "Aperture-priority AE"),
                .init(value: "4", label: "Shutter-priority AE"),
                .init(value: "5", label: "Creative Program"),
                .init(value: "6", label: "Action Program"),
                .init(value: "7", label: "Portrait Mode"),
                .init(value: "8", label: "Landscape Mode")
            ]
        case "exif-flash":
            return [
                .init(value: "0", label: "No Flash"),
                .init(value: "1", label: "Fired"),
                .init(value: "5", label: "Fired, Return Not Detected"),
                .init(value: "7", label: "Fired, Return Detected"),
                .init(value: "9", label: "On, Did Not Fire"),
                .init(value: "13", label: "On, Return Not Detected"),
                .init(value: "15", label: "On, Return Detected"),
                .init(value: "16", label: "Off, Did Not Fire"),
                .init(value: "24", label: "Auto, Did Not Fire"),
                .init(value: "25", label: "Auto, Fired"),
                .init(value: "29", label: "Auto, Fired, Return Not Detected"),
                .init(value: "31", label: "Auto, Fired, Return Detected"),
                .init(value: "32", label: "No Flash Function"),
                .init(value: "65", label: "Fired, Red-eye Reduction"),
                .init(value: "69", label: "Fired, Red-eye, Return Not Detected"),
                .init(value: "71", label: "Fired, Red-eye, Return Detected"),
                .init(value: "73", label: "On, Red-eye, Did Not Fire"),
                .init(value: "77", label: "On, Red-eye, Return Not Detected"),
                .init(value: "79", label: "On, Red-eye, Return Detected"),
                .init(value: "89", label: "Auto, Fired, Red-eye"),
                .init(value: "93", label: "Auto, Fired, Red-eye, Return Not Detected"),
                .init(value: "95", label: "Auto, Fired, Red-eye, Return Detected")
            ]
        case "exif-metering-mode":
            return [
                .init(value: "0", label: "Unknown"),
                .init(value: "1", label: "Average"),
                .init(value: "2", label: "Center-weighted Average"),
                .init(value: "3", label: "Spot"),
                .init(value: "4", label: "Multi-spot"),
                .init(value: "5", label: "Multi-segment"),
                .init(value: "6", label: "Partial"),
                .init(value: "255", label: "Other")
            ]
        default:
            return nil
        }
    }

    private func handleSave() {
        validationMessage = nil

        let trimmedName = editor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Preset name is required."
            return
        }
        guard !editor.includedTagIDs.isEmpty else {
            validationMessage = "Select at least one field to include."
            return
        }

        let conflictingPreset = model.presets.first { preset in
            if case let .edit(editingID) = editor.mode, preset.id == editingID {
                return false
            }
            return preset.name.compare(trimmedName, options: .caseInsensitive) == .orderedSame
        }

        if let conflictingPreset {
            duplicateConflict = conflictingPreset
            return
        }

        persist(editorName: trimmedName, overridePresetID: nil, forceCreate: false)
    }

    private func replaceExistingPreset() {
        guard let duplicateConflict else { return }
        persist(
            editorName: editor.name.trimmingCharacters(in: .whitespacesAndNewlines),
            overridePresetID: duplicateConflict.id,
            forceCreate: false
        )
        self.duplicateConflict = nil
    }

    private func saveAsDuplicate() {
        persist(
            editorName: editor.name.trimmingCharacters(in: .whitespacesAndNewlines),
            overridePresetID: nil,
            forceCreate: true
        )
        duplicateConflict = nil
    }

    private func persist(editorName: String, overridePresetID: UUID?, forceCreate: Bool) {
        let fields = editor.includedTagIDs.map { tagID in
            PresetFieldValue(tagID: tagID, value: editor.valuesByTagID[tagID] ?? "")
        }
        let notes = editor.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNotes = notes.isEmpty ? nil : notes

        let saved: MetadataPreset?
        if forceCreate {
            saved = model.createPreset(name: editorName, notes: normalizedNotes, fields: fields)
        } else if let overridePresetID {
            saved = model.updatePreset(id: overridePresetID, name: editorName, notes: normalizedNotes, fields: fields)
        } else {
            switch editor.mode {
            case .createFromCurrent, .createBlank:
                saved = model.createPreset(name: editorName, notes: normalizedNotes, fields: fields)
            case let .edit(id):
                saved = model.updatePreset(id: id, name: editorName, notes: normalizedNotes, fields: fields)
            }
        }

        if saved != nil {
            model.dismissPresetEditor()
        } else {
            validationMessage = "Could not save preset."
        }
    }
}

private struct PresetManagerSheet: View {
    @ObservedObject var model: AppModel
    @State private var selectedPresetID: UUID?
    @State private var pendingDeletePresetID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Presets")
                .font(.title3.weight(.semibold))

            List(model.presets, selection: $selectedPresetID) { preset in
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                    Text("\(preset.fields.count) field\(preset.fields.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(preset.id)
            }
            .frame(minHeight: 280)

            HStack {
                Button("Add…") {
                    model.beginCreateBlankPreset()
                    model.isManagePresetsPresented = false
                }

                Button("Edit…") {
                    guard let selectedPresetID else { return }
                    model.beginEditPreset(selectedPresetID)
                    model.isManagePresetsPresented = false
                }
                .disabled(selectedPresetID == nil)

                Button("Duplicate") {
                    guard let selectedPresetID else { return }
                    _ = model.duplicatePreset(id: selectedPresetID)
                }
                .disabled(selectedPresetID == nil)

                Button("Delete", role: .destructive) {
                    pendingDeletePresetID = selectedPresetID
                }
                .disabled(selectedPresetID == nil)

                Spacer()

                Button("Close") {
                    model.isManagePresetsPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 420)
        .onAppear {
            if selectedPresetID == nil {
                selectedPresetID = model.selectedPresetID ?? model.presets.first?.id
            }
        }
        .alert("Delete preset?", isPresented: Binding(
            get: { pendingDeletePresetID != nil },
            set: { newValue in
                if !newValue { pendingDeletePresetID = nil }
            }
        )) {
            Button("Delete", role: .destructive) {
                guard let pendingDeletePresetID else { return }
                model.deletePreset(id: pendingDeletePresetID)
                selectedPresetID = model.selectedPresetID ?? model.presets.first?.id
                self.pendingDeletePresetID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletePresetID = nil
            }
        } message: {
            Text("This cannot be undone.")
        }
    }
}

private struct ImportConflictResolutionSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resolve Import Conflicts")
                .font(.title3.weight(.semibold))

            Text("Choose whether to keep existing staged values or use imported values.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.groupedImportConflicts, id: \.fileURL) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.fileURL.lastPathComponent)
                                .font(.headline)
                            ForEach(group.conflicts, id: \.id) { conflict in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conflict.tag.label)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    HStack {
                                        Text("Current: \(conflict.existing.value)")
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    HStack {
                                        Text("Imported: \(conflict.incomingValue)")
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                    Picker(
                                        "Choice",
                                        selection: Binding(
                                            get: { model.importConflictChoice(for: conflict.id) },
                                            set: { model.setImportConflictChoice($0, for: conflict.id) }
                                        )
                                    ) {
                                        Text("Keep Existing").tag(false)
                                        Text("Use Imported").tag(true)
                                    }
                                    .pickerStyle(.segmented)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(.quaternary.opacity(0.3))
                                )
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelImportConflictResolution()
                }
                .keyboardShortcut(.cancelAction)

                Button("Apply Decisions") {
                    model.applyImportConflictResolution()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 420)
    }
}

private struct InspectorPreviewImageView: View {
    @ObservedObject var model: AppModel
    let fileURL: URL

    var body: some View {
        ZStack {
            if let image = model.inspectorPreviewImage(for: fileURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.22))
            }

            if model.isInspectorPreviewLoading(for: fileURL) {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: fileURL) {
            model.ensureInspectorPreviewLoaded(for: fileURL)
        }
    }
}

private struct FullWidthPopupPicker: NSViewRepresentable {
    let options: [AppModel.PickerOption]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.selectionChanged(_:))
        return popup
    }

    func updateNSView(_ popup: NSPopUpButton, context: Context) {
        let currentTitles = popup.itemTitles
        let nextTitles = options.map(\.label)
        if currentTitles != nextTitles || popup.numberOfItems != options.count {
            popup.removeAllItems()
            popup.addItems(withTitles: nextTitles)
        }

        context.coordinator.options = options
        let selectedIndex = options.firstIndex(where: { $0.value == selection }) ?? 0
        if popup.indexOfSelectedItem != selectedIndex, selectedIndex < popup.numberOfItems {
            popup.selectItem(at: selectedIndex)
        }
    }

    final class Coordinator: NSObject {
        @Binding var selection: String
        var options: [AppModel.PickerOption] = []

        init(selection: Binding<String>) {
            _selection = selection
        }

        @MainActor @objc
        func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard options.indices.contains(index) else { return }
            selection = options[index].value
        }
    }
}

private struct FullWidthDateTimePicker: NSViewRepresentable {
    @Binding var selection: Date

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker(frame: .zero)
        picker.datePickerStyle = .textField
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.datePickerMode = .single
        picker.isBordered = true
        picker.isBezeled = true
        picker.drawsBackground = true
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.selectionChanged(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        if abs(picker.dateValue.timeIntervalSince(selection)) > 0.5 {
            picker.dateValue = selection
        }
    }

    final class Coordinator: NSObject {
        @Binding var selection: Date

        init(selection: Binding<Date>) {
            _selection = selection
        }

        @MainActor @objc
        func selectionChanged(_ sender: NSDatePicker) {
            selection = sender.dateValue
        }
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
