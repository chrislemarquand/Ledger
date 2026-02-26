@preconcurrency import AppKit
import Combine
import ExifEditCore
import MapKit
import SwiftUI

private extension Notification.Name {
    static let inspectorDidRequestBrowserFocus = Notification.Name("\(AppBrand.identifierPrefix).InspectorDidRequestBrowserFocus")
    static let inspectorDidRequestFieldNavigation = Notification.Name("\(AppBrand.identifierPrefix).InspectorDidRequestFieldNavigation")
    static let sidebarDidRequestFocus = Notification.Name("\(AppBrand.identifierPrefix).SidebarDidRequestFocus")
    static let browserDidRequestFocus = Notification.Name("\(AppBrand.identifierPrefix).BrowserDidRequestFocus")
}

private enum Motion {
    static let duration: Double = 0.16
    static var timingFunction: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }
}

private enum KeyCode {
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let `return`: UInt16 = 36
    static let numpadReturn: UInt16 = 76
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
}

private enum UIMetrics {
    enum Sidebar {
        static let sectionItemIndent: CGFloat = 11
        static let trailingColumnWidth: CGFloat = 28
        static let trailingColumnInset: CGFloat = 6
        static let topControlYOffset: CGFloat = -30
        static let rowIconSize: CGFloat = 15
        static let rowLeadingIconFrame: CGFloat = 16
        static let rowSpacing: CGFloat = 7
        static let headerFontSize: CGFloat = 11
        static let headerChevronFrameHeight: CGFloat = 22
        static let topControlGlyphSize: CGFloat = 16
        static let topControlFrameSize: CGFloat = 24
    }

    enum List {
        static let rowHeight: CGFloat = 24
        static let cellHorizontalInset: CGFloat = 8
        static let iconSize: CGFloat = 16
        static let iconGap: CGFloat = 6
        static let pendingDotSize: CGFloat = 6
        static let pendingDotCornerRadius: CGFloat = 3
    }

    enum Gallery {
        static let thumbnailCornerRadius: CGFloat = 8
        static let selectionOutset: CGFloat = 5
        static let selectionBorderWidth: CGFloat = 3.5
        static let pendingDotCornerRadius: CGFloat = 4
        static let pendingDotSize: CGFloat = 8
        static let pendingDotInset: CGFloat = 6
        static let titleGap: CGFloat = 6
    }
}

private func appAnimation() -> Animation? {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        return nil
    }
    return .easeInOut(duration: Motion.duration)
}

private actor SharedThumbnailRequestBroker {
    static let shared = SharedThumbnailRequestBroker(maxConcurrentRequests: 4)

    private struct RequestKey: Hashable {
        let url: URL
        let requiredSide: Int
    }

    private let maxConcurrentRequests: Int
    private var activeRequestCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inflight: [RequestKey: Task<NSImage?, Never>] = [:]

    init(maxConcurrentRequests: Int) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
    }

    func request(url: URL, requiredSide: CGFloat, forceRefresh: Bool) async -> NSImage? {
        let normalizedSide = max(1, Int(requiredSide.rounded(.up)))
        let key = RequestKey(url: url, requiredSide: normalizedSide)

        if forceRefresh {
            ThumbnailPipeline.invalidateCachedImages(for: [url])
        } else if let task = inflight[key] {
            return await task.value
        }

        let task = Task<NSImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.runWithPermit {
                await ThumbnailPipeline.generateThumbnail(fileURL: url, maxPixelSize: CGFloat(normalizedSide))
            }
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        return image
    }

    private func acquirePermit() async {
        if activeRequestCount < maxConcurrentRequests {
            activeRequestCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releasePermit() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
            return
        }
        activeRequestCount = max(0, activeRequestCount - 1)
    }

    private func runWithPermit(_ operation: @Sendable () async -> NSImage?) async -> NSImage? {
        await acquirePermit()
        defer { releasePermit() }
        return await operation()
    }
}

private struct InspectorPreviewActionPressedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct InspectorPreviewActionHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var inspectorPreviewActionIsPressed: Bool {
        get { self[InspectorPreviewActionPressedKey.self] }
        set { self[InspectorPreviewActionPressedKey.self] = newValue }
    }

    var inspectorPreviewActionIsHovered: Bool {
        get { self[InspectorPreviewActionHoveredKey.self] }
        set { self[InspectorPreviewActionHoveredKey.self] = newValue }
    }
}

private struct InspectorPreviewActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InspectorPreviewActionButton(configuration: configuration)
    }

    private struct InspectorPreviewActionButton: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .environment(\.inspectorPreviewActionIsPressed, configuration.isPressed)
                .environment(\.inspectorPreviewActionIsHovered, isHovered)
                .onHover { hovering in
                    isHovered = hovering
                }
        }
    }
}

private struct InspectorPreviewActionLabel: View {
    let symbolName: String
    let title: String
    @Environment(\.inspectorPreviewActionIsPressed) private var isPressed
    @Environment(\.inspectorPreviewActionIsHovered) private var isHovered

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbolName)
                .font(.body)
                .foregroundStyle(isPressed ? Color.white : (isHovered ? Color.primary : Color.secondary))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class NativeThreePaneSplitViewController: NSSplitViewController, NSMenuItemValidation, NSMenuDelegate {
    private var model: AppModel

    private let sidebarController: NSHostingController<AnyView>
    private let browserController: NSHostingController<AnyView>
    private let inspectorController: NSHostingController<AnyView>
    private let contentSplitController: NSSplitViewController

    private let sidebarItem: NSSplitViewItem
    private let contentItem: NSSplitViewItem
    private let browserItem: NSSplitViewItem
    private let inspectorItem: NSSplitViewItem

    private var didConfigureWindow = false
    private var nativeToolbarDelegate: NativeToolbarDelegate?
    private weak var viewMenuForSortInjection: NSMenu?
    private weak var folderMenuForInjection: NSMenu?
    private var menuTrackingObserver: NSObjectProtocol?
    private var modelObserver: AnyCancellable?
    private var statusObserver: AnyCancellable?
    private var spacebarMonitor: Any?
    private var browserFocusRequestObserver: NSObjectProtocol?
    private var splitResizeObserver: NSObjectProtocol?
    private var didApplyInitialContentSplit = false
    private var didApplyInitialInspectorVisibility = false
    private var lastWindowTitleText = ""
    private var lastWindowSubtitleText = ""

    init(model: AppModel) {
        self.model = model

        sidebarController = NSHostingController(rootView: AnyView(NavigationSidebarView(model: model).tint(AppTheme.accentColor)))
        browserController = NSHostingController(rootView: AnyView(BrowserView(model: model).tint(AppTheme.accentColor)))
        inspectorController = NSHostingController(rootView: AnyView(InspectorView(model: model).tint(AppTheme.accentColor)))
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
        inspectorItem.canCollapse = true
        inspectorItem.holdingPriority = .defaultLow

        // Prevent inspector or sidebar content from forcing pane expansion during view updates.
        sidebarController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sidebarController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
                    self?.nativeToolbarDelegate?.refreshFromModel()
                    self?.refreshWindowTitleSubtitleIfNeeded()
                }
            }

        statusObserver = model.$statusMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.nativeToolbarDelegate?.refreshFromModel()
                self?.refreshWindowTitleSubtitleIfNeeded()
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Configure the window before it becomes visible so the macOS 26
        // compositor can apply the correct floating-sidebar shadow from the
        // first frame. Calling this in viewDidAppear causes a brief flash of
        // sharp-cornered shadow before the toolbar style triggers a re-composite.
        configureWindowIfNeeded()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        teardownObserversAndMonitors()
    }

    private func teardownObserversAndMonitors() {
        if let spacebarMonitor {
            NSEvent.removeMonitor(spacebarMonitor)
            self.spacebarMonitor = nil
        }
        if let browserFocusRequestObserver {
            NotificationCenter.default.removeObserver(browserFocusRequestObserver)
            self.browserFocusRequestObserver = nil
        }
        if let splitResizeObserver {
            NotificationCenter.default.removeObserver(splitResizeObserver)
            self.splitResizeObserver = nil
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        resetSplitAutosaveStateIfNeeded()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = NSSplitView.AutosaveName(Self.mainSplitAutosaveName)
        contentSplitController.splitView.isVertical = true
        contentSplitController.splitView.dividerStyle = .thin
        contentSplitController.splitView.autosaveName = NSSplitView.AutosaveName(Self.contentSplitAutosaveName)
        syncSidebarCollapsedState()
        installSplitResizeObserverIfNeeded()
    }

    private func resetSplitAutosaveStateIfNeeded() {
        let key = "ui.split.autosave.reset.v4"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }

        // Preserve old split layout by migrating prior-brand keys to the current brand namespace.
        for legacyPrefix in AppBrand.legacyDisplayNames {
            migrateSplitAutosaveValues(fromPrefix: legacyPrefix, toPrefix: AppBrand.identifierPrefix, defaults: defaults)
        }
        defaults.set(true, forKey: key)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        ensureInitialInspectorVisibilityIfNeeded()
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

    private func ensureInitialInspectorVisibilityIfNeeded() {
        guard !didApplyInitialInspectorVisibility else { return }
        didApplyInitialInspectorVisibility = true
        inspectorItem.isCollapsed = false
        syncInspectorCollapsedState()
    }

    private func hasPersistedContentSplitLayout() -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "NSSplitView Subview Frames \(Self.contentSplitAutosaveName)") != nil
            || defaults.object(forKey: "NSSplitView Divider Positions \(Self.contentSplitAutosaveName)") != nil
    }

    private func configureWindowIfNeeded() {
        guard !didConfigureWindow, let window = view.window else { return }
        didConfigureWindow = true

        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false

        let delegate = NativeToolbarDelegate(controller: self)
        // Bump toolbar identifier so AppKit rebuilds default item layout.
        let toolbar = NSToolbar(identifier: "\(AppBrand.identifierPrefix).MainToolbar.v2")
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar

        nativeToolbarDelegate = delegate
        if sidebarItem.isCollapsed {
            sidebarItem.isCollapsed = false
        }
        syncSidebarCollapsedState()
        refreshWindowTitleSubtitleIfNeeded()
        installSpacebarQuickLookMonitorIfNeeded()
        installBrowserFocusRequestObserverIfNeeded()
        syncInspectorCollapsedState()
        DispatchQueue.main.async { [weak self] in
            self?.focusBrowserPane()
            self?.injectSortMenuIfNeeded()
            self?.injectFolderMenuIfNeeded()
        }
        // Re-register menu delegates every time the user clicks the menu bar.
        // SwiftUI may rebuild NSMenu objects after our initial async setup, invalidating
        // the weak references. didBeginTrackingNotification fires before menuWillOpen,
        // so delegates are always current by the time injection is needed.
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.injectSortMenuIfNeeded()
                self?.injectFolderMenuIfNeeded()
            }
        }
    }

    private func refreshWindowTitleSubtitleIfNeeded() {
        guard let window = view.window else { return }
        let title = toolbarTitleText()
        let subtitle = toolbarSubtitleText()
        if title != lastWindowTitleText {
            lastWindowTitleText = title
            window.title = title
        }
        if subtitle != lastWindowSubtitleText {
            lastWindowSubtitleText = subtitle
            window.subtitle = subtitle
        }
    }

    private func installSpacebarQuickLookMonitorIfNeeded() {
        guard spacebarMonitor == nil else { return }
        spacebarMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option, .function])
            let isTabWithoutCommand = event.keyCode == KeyCode.tab && (modifiers.isEmpty || modifiers == [.shift])

            if isTabWithoutCommand && shouldHandlePaneTabSwitchCommands() {
                togglePaneFocusBetweenSidebarAndBrowser()
                return nil
            }

            if shouldHandleInspectorTabCommands() && event.keyCode == KeyCode.tab {
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
            case KeyCode.escape:
                guard modifiers.isEmpty else { return event }
                model.clearSelection()
                return nil
            case KeyCode.space:
                guard modifiers.intersection([.command, .control, .option, .function]).isEmpty else { return event }
                model.quickLookSelection()
                return nil
            case _ where event.characters == "a":
                guard modifiers == [.command] else { return event }
                model.selectAllFilteredFiles()
                return nil
            case _ where event.characters == "d":
                guard modifiers == [.command] else { return event }
                model.clearSelection()
                return nil
            case KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.downArrow, KeyCode.upArrow: // Arrow keys
                guard let direction = moveDirection(forKeyCode: event.keyCode) else { return event }
                if modifiers.isEmpty {
                    if model.browserViewMode == .gallery {
                        model.moveSelectionInGallery(direction: direction, extendingSelection: false)
                        return nil
                    }
                    if direction == .up || direction == .down {
                        model.moveSelectionInList(direction: direction, extendingSelection: false)
                        return nil
                    }
                    return event
                }
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

    private static var mainSplitAutosaveName: String { "\(AppBrand.identifierPrefix).MainSplit" }
    private static var contentSplitAutosaveName: String { "\(AppBrand.identifierPrefix).ContentSplit" }

    private func migrateSplitAutosaveValues(fromPrefix oldPrefix: String, toPrefix newPrefix: String, defaults: UserDefaults) {
        guard oldPrefix != newPrefix else { return }
        let keyPairs = [
            ("NSSplitView Subview Frames \(oldPrefix).MainSplit", "NSSplitView Subview Frames \(newPrefix).MainSplit"),
            ("NSSplitView Subview Frames \(oldPrefix).ContentSplit", "NSSplitView Subview Frames \(newPrefix).ContentSplit"),
            ("NSSplitView Divider Positions \(oldPrefix).MainSplit", "NSSplitView Divider Positions \(newPrefix).MainSplit"),
            ("NSSplitView Divider Positions \(oldPrefix).ContentSplit", "NSSplitView Divider Positions \(newPrefix).ContentSplit"),
        ]
        for (oldKey, newKey) in keyPairs {
            guard defaults.object(forKey: newKey) == nil, let value = defaults.object(forKey: oldKey) else { continue }
            defaults.set(value, forKey: newKey)
        }
    }

    private func installBrowserFocusRequestObserverIfNeeded() {
        guard browserFocusRequestObserver == nil else { return }
        browserFocusRequestObserver = NotificationCenter.default.addObserver(
            forName: .inspectorDidRequestBrowserFocus,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.focusBrowserPane()
            }
        }
    }

    private func installSplitResizeObserverIfNeeded() {
        guard splitResizeObserver == nil else { return }
        splitResizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncSidebarCollapsedState()
                self?.syncInspectorCollapsedState()
            }
        }
    }

    func isSidebarCollapsedForMenu() -> Bool {
        sidebarItem.isCollapsed
    }

    func isInspectorCollapsedForMenu() -> Bool {
        inspectorItem.isCollapsed
    }

    @objc
    func toggleInspectorAction(_: Any?) {
        let previousResponder = view.window?.firstResponder
        inspectorItem.animator().isCollapsed.toggle()
        syncInspectorCollapsedState()

        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.view.window else { return }
            if let previousResponder {
                _ = window.makeFirstResponder(previousResponder)
            }
        }
    }

    private func syncSidebarCollapsedState() {
        model.isSidebarCollapsed = sidebarItem.isCollapsed
        nativeToolbarDelegate?.refreshFromModel()
    }

    private func syncInspectorCollapsedState() {
        model.isInspectorCollapsed = inspectorItem.isCollapsed
        nativeToolbarDelegate?.refreshFromModel()
    }

    /// Finds the View menu and registers self as its NSMenuDelegate.
    /// Called deferred so SwiftUI has fully built the menu first.
    /// The actual Sort By injection happens in menuWillOpen so it survives SwiftUI rebuilds.
    private func injectSortMenuIfNeeded() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for topItem in mainMenu.items {
            guard let submenu = topItem.submenu else { continue }
            if submenu.items.contains(where: { $0.title == "Toggle Sidebar" }) {
                viewMenuForSortInjection = submenu
                submenu.delegate = self
                return
            }
        }
    }

    /// Finds the Folder menu and registers self as its NSMenuDelegate.
    /// Apply / Clear / Restore injection happens in menuWillOpen so it survives SwiftUI rebuilds.
    private func injectFolderMenuIfNeeded() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for topItem in mainMenu.items {
            guard let submenu = topItem.submenu else { continue }
            if submenu.items.contains(where: { $0.title == "Refresh Files and Metadata" }) {
                folderMenuForInjection = submenu
                submenu.delegate = self
                return
            }
        }
    }

    /// Builds and returns the Sort By NSMenuItem with submenu.
    private func makeSortByMenuItem() -> NSMenuItem {
        let sortMenu = NSMenu(title: "Sort By")
        sortMenu.addItem(withTitle: "Name", action: #selector(sortByNameAction(_:)), keyEquivalent: "")
        sortMenu.addItem(withTitle: "Date Created", action: #selector(sortByCreatedAction(_:)), keyEquivalent: "")
        sortMenu.addItem(withTitle: "Size", action: #selector(sortBySizeAction(_:)), keyEquivalent: "")
        sortMenu.addItem(withTitle: "Kind", action: #selector(sortByKindAction(_:)), keyEquivalent: "")
        let item = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
        item.submenu = sortMenu
        return item
    }

    /// Rebuilds the View menu in the desired order with SF Symbol images.
    /// Collects SwiftUI-managed items (Toggle Sidebar, Toggle Inspector) and any
    /// unrecognised AppKit items (Enter Full Screen), clears the menu, then re-adds
    /// everything in order: As Gallery, As List, Sort By, Zoom In/Out,
    /// Toggle Sidebar, Toggle Inspector, other (Enter Full Screen).
    private func rebuildViewMenu(_ menu: NSMenu) {
        // Early exit if already in the correct order.
        guard menu.items.first?.title != "As Gallery" else { return }

        // Collect items we don't own so we can keep them.
        var sidebarMenuItem: NSMenuItem?
        var inspectorMenuItem: NSMenuItem?
        var extraItems: [NSMenuItem] = []
        let ownedTitles: Set<String> = ["As Gallery", "As List", "Sort By", "Zoom In", "Zoom Out"]

        for item in menu.items where !item.isSeparatorItem {
            switch item.title {
            case "Toggle Sidebar":  sidebarMenuItem = item
            case "Toggle Inspector": inspectorMenuItem = item
            case _ where ownedTitles.contains(item.title): break  // will be recreated
            default: extraItems.append(item)
            }
        }

        // Build fresh injected items with images.
        let galleryItem = NSMenuItem(title: "As Gallery", action: #selector(switchToGalleryAction(_:)), keyEquivalent: "1")
        galleryItem.keyEquivalentModifierMask = .command
        galleryItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)

        let listItem = NSMenuItem(title: "As List", action: #selector(switchToListAction(_:)), keyEquivalent: "2")
        listItem.keyEquivalentModifierMask = .command
        listItem.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)

        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(zoomInAction(_:)), keyEquivalent: "+")
        zoomInItem.keyEquivalentModifierMask = .command
        zoomInItem.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil)

        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(zoomOutAction(_:)), keyEquivalent: "-")
        zoomOutItem.keyEquivalentModifierMask = .command
        zoomOutItem.image = NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: nil)

        // Stamp images onto SwiftUI-managed items.
        sidebarMenuItem?.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        inspectorMenuItem?.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: nil)

        // Rebuild in desired order.
        menu.removeAllItems()
        menu.addItem(galleryItem)
        menu.addItem(listItem)
        menu.addItem(.separator())
        menu.addItem(makeSortByMenuItem())
        menu.addItem(.separator())
        menu.addItem(zoomInItem)
        menu.addItem(zoomOutItem)
        menu.addItem(.separator())
        if let sidebarMenuItem  { menu.addItem(sidebarMenuItem) }
        if let inspectorMenuItem { menu.addItem(inspectorMenuItem) }
        if !extraItems.isEmpty {
            menu.addItem(.separator())
            extraItems.forEach { menu.addItem($0) }
        }
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        if menu === viewMenuForSortInjection {
            rebuildViewMenu(menu)
        } else if menu === folderMenuForInjection {
            if !menu.items.contains(where: { $0.title == "Apply Metadata Changes" }) {
                let anchor = (menu.items.firstIndex(where: { $0.title == "Refresh Files and Metadata" }) ?? -1) + 1
                // Insert in reverse so final order is: Apply, Clear, Restore
                let restoreItem = NSMenuItem(title: "Restore from Last Backup", action: #selector(restoreFromBackupAction(_:)), keyEquivalent: "b")
                restoreItem.keyEquivalentModifierMask = [.command, .shift]
                let clearItem = NSMenuItem(title: "Clear Metadata Changes", action: #selector(clearChangesAction(_:)), keyEquivalent: "k")
                clearItem.keyEquivalentModifierMask = [.command, .shift]
                let applyItem = NSMenuItem(title: "Apply Metadata Changes", action: #selector(applySelectionAction(_:)), keyEquivalent: "s")
                applyItem.keyEquivalentModifierMask = .command
                menu.insertItem(restoreItem, at: anchor)
                menu.insertItem(clearItem, at: anchor)
                menu.insertItem(applyItem, at: anchor)
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let selection = Array(model.selectedFileURLs)
        if menuItem.action == #selector(toggleInspectorAction(_:)) {
            menuItem.title = inspectorItem.isCollapsed ? "Show Inspector" : "Hide Inspector"
        } else if menuItem.action == #selector(switchToGalleryAction(_:)) {
            menuItem.state = model.browserViewMode == .gallery ? .on : .off
        } else if menuItem.action == #selector(switchToListAction(_:)) {
            menuItem.state = model.browserViewMode == .list ? .on : .off
        } else if menuItem.action == #selector(applySelectionAction(_:)) {
            return model.fileActionState(for: .applyMetadataChanges, targetURLs: selection).isEnabled
        } else if menuItem.action == #selector(clearChangesAction(_:)) {
            return model.fileActionState(for: .clearMetadataChanges, targetURLs: selection).isEnabled
        } else if menuItem.action == #selector(restoreFromBackupAction(_:)) {
            return model.fileActionState(for: .restoreFromLastBackup, targetURLs: selection).isEnabled
        } else if menuItem.action == #selector(zoomInAction(_:)) {
            return model.browserViewMode == .gallery && model.canIncreaseGalleryZoom
        } else if menuItem.action == #selector(zoomOutAction(_:)) {
            return model.browserViewMode == .gallery && model.canDecreaseGalleryZoom
        } else if menuItem.action == #selector(sortByNameAction(_:)) {
            menuItem.state = model.browserSort == .name ? .on : .off
        } else if menuItem.action == #selector(sortByCreatedAction(_:)) {
            menuItem.state = model.browserSort == .created ? .on : .off
        } else if menuItem.action == #selector(sortBySizeAction(_:)) {
            menuItem.state = model.browserSort == .size ? .on : .off
        } else if menuItem.action == #selector(sortByKindAction(_:)) {
            menuItem.state = model.browserSort == .kind ? .on : .off
        }
        return true
    }

    private func shouldHandleBrowserKeyCommands() -> Bool {
        guard let window = view.window else { return false }
        guard canHandleBrowserShortcuts(in: window) else { return false }

        // Never hijack space while editing text fields.
        if let textView = window.firstResponder as? NSTextView, textView.isEditable {
            return false
        }

        guard let responderView = window.firstResponder as? NSView else { return false }
        return responderView === browserController.view || responderView.isDescendant(of: browserController.view)
    }

    private func shouldHandleInspectorTabCommands() -> Bool {
        guard let window = view.window else { return false }
        guard canHandleBrowserShortcuts(in: window) else { return false }
        guard let responderView = window.firstResponder as? NSView else { return false }
        return responderView === inspectorController.view || responderView.isDescendant(of: inspectorController.view)
    }

    private func shouldHandlePaneTabSwitchCommands() -> Bool {
        guard let window = view.window else { return false }
        guard canHandleBrowserShortcuts(in: window) else { return false }

        if let textView = window.firstResponder as? NSTextView, textView.isEditable {
            return false
        }

        guard let responderView = window.firstResponder as? NSView else { return false }
        let inBrowser = responderView === browserController.view || responderView.isDescendant(of: browserController.view)
        let inSidebar = responderView === sidebarController.view || responderView.isDescendant(of: sidebarController.view)
        return inBrowser || inSidebar
    }

    private func togglePaneFocusBetweenSidebarAndBrowser() {
        guard let window = view.window,
              let responderView = window.firstResponder as? NSView
        else {
            return
        }

        let inSidebar = responderView === sidebarController.view || responderView.isDescendant(of: sidebarController.view)
        if inSidebar {
            focusBrowserPane()
            return
        }

        let inBrowser = responderView === browserController.view || responderView.isDescendant(of: browserController.view)
        if inBrowser {
            NotificationCenter.default.post(name: .sidebarDidRequestFocus, object: nil)
        }
    }

    private func focusBrowserPane() {
        guard let window = view.window else { return }
        NotificationCenter.default.post(name: .browserDidRequestFocus, object: nil)
        window.makeFirstResponder(browserController.view)
    }

    private func canHandleBrowserShortcuts(in window: NSWindow) -> Bool {
        // If any app-modal panel (e.g. NSOpenPanel.runModal) is active, browser shortcuts must be disabled.
        if NSApp.modalWindow != nil {
            return false
        }

        // If our window is presenting a sheet (e.g. preset editor), don't route keyboard shortcuts to the browser.
        if window.attachedSheet != nil {
            return false
        }

        // Only handle browser shortcuts while our main split window is key.
        guard let keyWindow = NSApp.keyWindow else { return false }
        return keyWindow === window
    }

    private func moveDirection(forKeyCode keyCode: UInt16) -> MoveCommandDirection? {
        switch keyCode {
        case KeyCode.leftArrow: return .left
        case KeyCode.rightArrow: return .right
        case KeyCode.downArrow: return .down
        case KeyCode.upArrow: return .up
        default: return nil
        }
    }

    private func toolbarTitleText() -> String {
        guard let item = model.selectedSidebarItem else { return AppBrand.displayName }
        switch item.kind {
        case .pictures, .desktop, .downloads, .mountedVolume, .favorite:
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
    func focusInspectorEntryAction(_: Any?) {
        guard !model.selectedFileURLs.isEmpty else { return }
        NotificationCenter.default.post(
            name: .inspectorDidRequestFieldNavigation,
            object: nil,
            userInfo: ["backward": false]
        )
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
    func applySelectionAction(_: Any?) {
        model.performFileAction(.applyMetadataChanges, targetURLs: Array(model.selectedFileURLs))
    }

    @objc
    func clearChangesAction(_: Any?) {
        model.performFileAction(.clearMetadataChanges, targetURLs: Array(model.selectedFileURLs))
    }

    @objc
    func restoreFromBackupAction(_: Any?) {
        model.performFileAction(.restoreFromLastBackup, targetURLs: Array(model.selectedFileURLs))
    }

    @objc
    func zoomOutAction(_: Any?) {
        guard model.browserViewMode == .gallery else { return }
        model.decreaseGalleryZoom()
        nativeToolbarDelegate?.refreshFromModel()
    }

    @objc
    func zoomInAction(_: Any?) {
        guard model.browserViewMode == .gallery else { return }
        model.increaseGalleryZoom()
        nativeToolbarDelegate?.refreshFromModel()
    }

    @objc
    func switchToGalleryAction(_: Any?) {
        model.browserViewMode = .gallery
        nativeToolbarDelegate?.refreshFromModel()
    }

    @objc
    func switchToListAction(_: Any?) {
        model.browserViewMode = .list
        nativeToolbarDelegate?.refreshFromModel()
    }

    @objc
    func sortByNameAction(_: Any?) {
        model.browserSort = .name
        nativeToolbarDelegate?.refreshFromModel()
    }

    @objc
    func sortByCreatedAction(_: Any?) {
        model.browserSort = .created
        nativeToolbarDelegate?.refreshFromModel()
    }

    @objc
    func sortBySizeAction(_: Any?) {
        model.browserSort = .size
        nativeToolbarDelegate?.refreshFromModel()
    }

    @objc
    func sortByKindAction(_: Any?) {
        model.browserSort = .kind
        nativeToolbarDelegate?.refreshFromModel()
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
        nativeToolbarDelegate?.refreshFromModel()
        DispatchQueue.main.async { [weak self] in
            self?.focusBrowserPane()
        }
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

    @MainActor
    private final class NativeToolbarDelegate: NSObject, NSToolbarDelegate {
        private weak var controller: NativeThreePaneSplitViewController?

        private var viewModeControl: NSSegmentedControl?
        private var zoomOutItem: NSToolbarItem?
        private var zoomInItem: NSToolbarItem?
        private var applyChangesItem: NSToolbarItem?
        private var inspectorToggleItem: NSToolbarItem?
        private var searchItem: NSSearchToolbarItem?
        private var sortItem: NSToolbarItem?
        private var presetsItem: NSToolbarItem?
        private var sortMenu: NSMenu?
        private var presetsMenu: NSMenu?

        init(controller: NativeThreePaneSplitViewController) {
            self.controller = controller
        }

        func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
            return [
                .toggleSidebar,
                .sidebarTrackingSeparator,
                .flexibleSpace,
                .viewMode,
                .sort,
                .zoomOut,
                .zoomIn,
                .presetTools,
                .openFolder,
                .applyChanges,
                .toggleInspector,
                .search
            ]
        }

        func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
            return [
                .toggleSidebar,
                .sidebarTrackingSeparator,
                .viewMode,
                .sort,
                .zoomOut,
                .zoomIn,
                .presetTools,
                .openFolder,
                .toggleInspector,
                .flexibleSpace,
                .applyChanges,
                .search
            ]
        }

        func toolbar(
            _: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar _: Bool
        ) -> NSToolbarItem? {
            guard let controller else { return nil }

            switch itemIdentifier {
            case .toggleSidebar:
                // Let AppKit provide the native sidebar toggle toolbar item.
                return nil
            case .sidebarTrackingSeparator:
                // Bind tracking explicitly to the outer sidebar/content divider.
                return NSTrackingSeparatorToolbarItem(
                    identifier: .sidebarTrackingSeparator,
                    splitView: controller.splitView,
                    dividerIndex: 0
                )
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
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Sort"
                item.paletteLabel = "Sort"
                item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
                item.target = self
                item.action = #selector(showSortMenu(_:))
                item.toolTip = "Sort files"
                sortItem = item
                return item
            case .presetTools:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Presets"
                item.paletteLabel = "Presets"
                item.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Presets")
                item.target = self
                item.action = #selector(showPresetsMenu(_:))
                item.toolTip = "Presets"
                presetsItem = item
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
            case .toggleInspector:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                let collapsed = controller.inspectorItem.isCollapsed
                let label = collapsed ? "Show Inspector" : "Hide Inspector"
                item.label = label
                item.paletteLabel = "Toggle Inspector"
                item.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Toggle inspector")
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.toggleInspectorAction(_:))
                item.toolTip = label
                inspectorToggleItem = item
                return item
            case .search:
                let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Search"
                item.paletteLabel = "Search"
                item.searchField.placeholderString = "Search files"
                item.searchField.sendsSearchStringImmediately = true
                item.searchField.target = controller
                item.searchField.action = #selector(NativeThreePaneSplitViewController.searchChanged(_:))
                item.toolTip = "Search files"
                searchItem = item
                return item
            default:
                return nil
            }
        }

        func refreshFromModel() {
            guard let controller else { return }
            let model = controller.model
            updateViewMode(with: model)
            updateZoom(with: model)
            updateSortMenu(with: model)
            updatePresetsMenu(with: model)
            updateSearch(with: model)
            updateApplyEnabled(with: model)
            updateInspectorToggle(with: model)
        }

        private func updateViewMode(with model: AppModel) {
            viewModeControl?.selectedSegment = model.browserViewMode == .gallery ? 0 : 1
        }

        private func updateZoom(with model: AppModel) {
            zoomOutItem?.isEnabled = model.browserViewMode == .gallery && model.canDecreaseGalleryZoom
            zoomInItem?.isEnabled = model.browserViewMode == .gallery && model.canIncreaseGalleryZoom
        }

        private func updateSortMenu(with model: AppModel) {
            let menu = makeSortMenu(model: model)
            sortMenu = menu
            for item in menu.items {
                item.state = .off
            }
            switch model.browserSort {
            case .name:
                menu.item(withTitle: "Name")?.state = .on
            case .created:
                menu.item(withTitle: "Date Created")?.state = .on
            case .size:
                menu.item(withTitle: "Size")?.state = .on
            case .kind:
                menu.item(withTitle: "Kind")?.state = .on
            }
        }

        private func updatePresetsMenu(with model: AppModel) {
            presetsMenu = makePresetsMenu(model: model)
        }

        private func updateSearch(with model: AppModel) {
            guard let searchField = searchItem?.searchField, searchField.stringValue != model.searchQuery else { return }
            searchField.stringValue = model.searchQuery
        }

        private func updateApplyEnabled(with model: AppModel) {
            applyChangesItem?.isEnabled = model.canApplyMetadataChanges
        }

        private func updateInspectorToggle(with model: AppModel) {
            let label = model.isInspectorCollapsed ? "Show Inspector" : "Hide Inspector"
            inspectorToggleItem?.label = label
            inspectorToggleItem?.toolTip = label
        }

        func focusSearchField() {
            guard let window = controller?.view.window,
                  let searchField = searchItem?.searchField else { return }
            window.makeFirstResponder(searchField)
            searchField.selectText(nil)
        }

        @objc
        private func showSortMenu(_ sender: Any?) {
            guard let controller else { return }
            if sortMenu == nil {
                updateSortMenu(with: controller.model)
            }
            present(menu: sortMenu, sender: sender)
        }

        @objc
        private func showPresetsMenu(_ sender: Any?) {
            guard let controller else { return }
            updatePresetsMenu(with: controller.model)
            present(menu: presetsMenu, sender: sender)
        }

        private func present(menu: NSMenu?, sender: Any?) {
            guard let menu,
                  let controller,
                  let window = controller.view.window,
                  let contentView = window.contentView
            else { return }
            let anchorInScreen = NSEvent.mouseLocation
            let anchorInWindow = window.convertPoint(fromScreen: anchorInScreen)
            let anchorInContent = contentView.convert(anchorInWindow, from: nil)
            menu.popUp(positioning: nil, at: CGPoint(x: anchorInContent.x, y: anchorInContent.y - 6), in: contentView)
            _ = sender
        }

        private func makeSortMenu(model: AppModel) -> NSMenu {
            guard let controller else { return NSMenu(title: "Sort") }
            let menu = NSMenu(title: "Sort")
            menu.autoenablesItems = false
            menu.addItem(withTitle: "Name", action: #selector(NativeThreePaneSplitViewController.sortByNameAction(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Date Created", action: #selector(NativeThreePaneSplitViewController.sortByCreatedAction(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Size", action: #selector(NativeThreePaneSplitViewController.sortBySizeAction(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Kind", action: #selector(NativeThreePaneSplitViewController.sortByKindAction(_:)), keyEquivalent: "")
            for item in menu.items {
                item.target = controller
            }
            switch model.browserSort {
            case .name:
                menu.item(withTitle: "Name")?.state = .on
            case .created:
                menu.item(withTitle: "Date Created")?.state = .on
            case .size:
                menu.item(withTitle: "Size")?.state = .on
            case .kind:
                menu.item(withTitle: "Kind")?.state = .on
            }
            return menu
        }

        private func makePresetsMenu(model: AppModel) -> NSMenu {
            guard let controller else { return NSMenu(title: "Presets") }
            let menu = NSMenu(title: "Presets")
            menu.autoenablesItems = false

            let applyMenuItem = NSMenuItem(title: "Apply Preset", action: nil, keyEquivalent: "")
            let applySubmenu = NSMenu(title: "Apply Preset")
            if model.presets.isEmpty {
                let emptyItem = NSMenuItem(title: "No Presets", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                applySubmenu.addItem(emptyItem)
            } else {
                for preset in model.presets {
                    let item = NSMenuItem(
                        title: preset.name,
                        action: #selector(NativeThreePaneSplitViewController.applyPresetFromMenuAction(_:)),
                        keyEquivalent: ""
                    )
                    item.target = controller
                    item.representedObject = preset.id.uuidString
                    item.isEnabled = !model.selectedFileURLs.isEmpty
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
            saveItem.isEnabled = !model.selectedFileURLs.isEmpty
            menu.addItem(saveItem)

            let manageItem = NSMenuItem(
                title: "Manage Presets…",
                action: #selector(NativeThreePaneSplitViewController.managePresetsAction(_:)),
                keyEquivalent: ""
            )
            manageItem.target = controller
            menu.addItem(manageItem)
            return menu
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let viewMode = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.ViewMode")
    static let sort = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.Sort")
    static let presetTools = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.PresetTools")
    static let zoomOut = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.ZoomOut")
    static let zoomIn = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.ZoomIn")
    static let openFolder = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.OpenFolder")
    static let applyChanges = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.ApplyChanges")
    static let toggleInspector = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.ToggleInspector")
    static let search = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.Search")
}

struct NavigationSidebarView: View {
    @ObservedObject var model: AppModel
    @State private var collapsedSections: Set<String> = []
    @State private var hoveredSection: String?
    @Environment(\.controlActiveState) private var controlActiveState
    @FocusState private var isSidebarFocused: Bool

    var body: some View {
        List(selection: $model.selectedSidebarID) {
            ForEach(model.sidebarSectionOrder, id: \.self) { section in
                let sectionItems = model.sidebarItems.filter { $0.section == section }
                if !sectionItems.isEmpty {
                    Section {
                        if !collapsedSections.contains(section) {
                            ForEach(sectionItems) { item in
                                Group {
                                    if hasSidebarActions(item) {
                                        sidebarRow(item)
                                            .contextMenu {
                                                // Reset tint so SF Symbol images render in label
                                                // colour, not the inherited accent tint.
                                                sidebarContextMenu(for: item)
                                                    .tint(Color.primary)
                                            }
                                    } else {
                                        sidebarRow(item)
                                    }
                                }
                                .task(id: item.id) {
                                    switch item.kind {
                                    case .desktop, .downloads: break
                                    default: model.ensureSidebarImageCount(for: item)
                                    }
                                }
                            }
                        }
                    } header: {
                        sidebarSectionHeader(section)
                    }
                }
            }
        }
        .animation(appAnimation(), value: collapsedSections)
        .listStyle(.sidebar)
        .frame(maxHeight: .infinity)
        .focused($isSidebarFocused)
        .onReceive(NotificationCenter.default.publisher(for: .sidebarDidRequestFocus)) { _ in
            isSidebarFocused = true
        }
        .onChange(of: model.selectedSidebarID) { oldValue, newValue in
            // Defer out of the SwiftUI update cycle. Calling handleSidebarSelectionChange
            // synchronously here causes B14: clearLoadedContentState + loadFiles mutate
            // @Published properties (browserItems → filteredBrowserItems) from within
            // the SwiftUI transaction, which triggers "Publishing changes from within
            // view updates is not allowed" and downstream NSHostingView reentrant layout.
            Task { @MainActor in
                model.handleSidebarSelectionChange(from: oldValue, to: newValue)
            }
        }
    }

    private func icon(for kind: AppModel.SidebarKind) -> String {
        switch kind {
        case .pictures:
            return "photo"
        case .desktop:
            return "menubar.dock.rectangle"
        case .downloads:
            return "arrow.down.circle"
        case .mountedVolume:
            return "externaldrive"
        case .favorite:
            return "pin"
        case .folder:
            return "folder"
        }
    }

    private func hasSidebarActions(_ item: AppModel.SidebarItem) -> Bool {
        model.canPinSidebarItem(item)
            || model.canUnpinSidebarItem(item)
            || model.canMoveFavoriteUp(item)
            || model.canMoveFavoriteDown(item)
    }

    @ViewBuilder
    private func sidebarRow(_ item: AppModel.SidebarItem) -> some View {
        let isSelected = model.selectedSidebarID == item.id
        let isInactiveSelected = isSelected && !isSidebarFocused
        let row = HStack(spacing: UIMetrics.Sidebar.rowSpacing) {
            Image(systemName: icon(for: item.kind))
                .font(.system(size: UIMetrics.Sidebar.rowIconSize))
                .frame(width: UIMetrics.Sidebar.rowLeadingIconFrame, alignment: .center)
            Text(item.title)
            Spacer(minLength: 8)
            if let countText = model.sidebarImageCountText(for: item) {
                Text(countText)
                    .font(.system(size: 14))
                    .monospacedDigit()
                    .animation(nil, value: model.selectedSidebarID)
                    .frame(width: UIMetrics.Sidebar.trailingColumnWidth, alignment: .trailing)
                    .padding(.trailing, UIMetrics.Sidebar.trailingColumnInset)
            } else {
                Color.clear
                    .frame(width: UIMetrics.Sidebar.trailingColumnWidth, height: 1, alignment: .trailing)
                    .padding(.trailing, UIMetrics.Sidebar.trailingColumnInset)
            }
        }
        .padding(.leading, UIMetrics.Sidebar.sectionItemIndent)
        .tag(item.id)

        if isInactiveSelected {
            row.foregroundStyle(Color.accentColor)
        } else {
            row
        }
    }

    private func sidebarSectionHeader(_ section: String) -> some View {
        Button {
            toggleSection(section)
        } label: {
            Text(section)
                .font(.system(size: UIMetrics.Sidebar.headerFontSize, weight: .semibold))
                .foregroundStyle(sidebarHeaderColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    Image(systemName: collapsedSections.contains(section) ? "chevron.right" : "chevron.down")
                        .font(.system(size: UIMetrics.Sidebar.headerFontSize, weight: .semibold))
                        .foregroundStyle(sidebarHeaderColor)
                        .opacity(hoveredSection == section ? 1 : 0)
                        .frame(width: UIMetrics.Sidebar.trailingColumnWidth, height: UIMetrics.Sidebar.headerChevronFrameHeight, alignment: .trailing)
                        .contentShape(Rectangle())
                        .padding(.trailing, UIMetrics.Sidebar.trailingColumnInset)
                }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredSection = isHovering ? section : nil
        }
    }

    private func toggleSection(_ section: String) {
        withAnimation(appAnimation()) {
            if collapsedSections.contains(section) {
                collapsedSections.remove(section)
            } else {
                collapsedSections.insert(section)
            }
        }
    }

    private var sidebarHeaderColor: Color {
        controlActiveState == .key
            ? Color(nsColor: .secondaryLabelColor)
            : Color(nsColor: .disabledControlTextColor)
    }

    @ViewBuilder
    private func sidebarContextMenu(for item: AppModel.SidebarItem) -> some View {
        if model.canOpenSidebarItemInFinder(item) {
            Button {
                model.openSidebarItemInFinder(item)
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }
        }

        if model.canPinSidebarItem(item) {
            if model.canOpenSidebarItemInFinder(item) {
                Divider()
            }
            Button {
                model.pinSidebarItem(item)
            } label: {
                Label("Pin", systemImage: "pin")
            }
        }

        if model.canUnpinSidebarItem(item) {
            Button {
                model.unpinSidebarItem(item)
            } label: {
                Label("Unpin Pinned", systemImage: "pin.slash")
            }

            if model.canMoveFavoriteUp(item) || model.canMoveFavoriteDown(item) {
                Divider()
            }

            Button {
                model.moveFavoriteUp(item)
            } label: {
                Label("Move Pinned Up", systemImage: "arrow.up")
            }
            .disabled(!model.canMoveFavoriteUp(item))

            Button {
                model.moveFavoriteDown(item)
            } label: {
                Label("Move Pinned Down", systemImage: "arrow.down")
            }
            .disabled(!model.canMoveFavoriteDown(item))
        }
    }
}

struct BrowserView: View {
    @ObservedObject var model: AppModel

    private enum OverlayState {
        case none
        case noSelection
        case loading
        case enumerationError(String)
        case emptyFolder
        case noResults
    }

    private var overlayState: OverlayState {
        if model.selectedSidebarID == nil {
            return .noSelection
        }
        if let error = model.browserEnumerationError {
            return .enumerationError(error.localizedDescription)
        }
        if model.isFolderMetadataLoading, model.browserItems.isEmpty {
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

    @ViewBuilder
    private var browserContent: some View {
        ZStack {
            BrowserGalleryView(model: model)
                .opacity(model.browserViewMode == .gallery ? 1 : 0)
                .allowsHitTesting(model.browserViewMode == .gallery)

            BrowserListView(model: model)
                .opacity(model.browserViewMode == .list ? 1 : 0)
                .allowsHitTesting(model.browserViewMode == .list)
        }
    }

    @ViewBuilder
    var body: some View {
        switch overlayState {
        case .none:
            browserContent
        case .loading:
            ZStack {
                browserContent
                BrowserLoadingPlaceholderView(mode: model.browserViewMode)
            }
        case .noSelection:
            ContentUnavailableView(
                "No Folder Selected",
                systemImage: "folder",
                description: Text("Open a folder from the toolbar to start browsing metadata.")
            )
        case let .enumerationError(message):
            ContentUnavailableView(
                "Folder Unavailable",
                systemImage: "lock.fill",
                description: Text(message)
            )
        case .emptyFolder:
            ContentUnavailableView(
                "No Images",
                systemImage: "photo.on.rectangle.angled",
                description: Text("This folder has no supported image files.")
            )
        case .noResults:
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("Try a different search term.")
            )
        }
    }
}

private struct BrowserLoadingPlaceholderView: View {
    let mode: AppModel.BrowserViewMode

    var body: some View {
        Group {
            if mode == .list {
                VStack(spacing: 10) {
                    ForEach(0 ..< 10, id: \.self) { _ in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.quaternary.opacity(0.42))
                                .frame(width: 16, height: 16)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.quaternary.opacity(0.38))
                                .frame(height: 12)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.quaternary.opacity(0.3))
                                .frame(width: 54, height: 12)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 70)
            } else {
                GeometryReader { proxy in
                    let columns = 4
                    let spacing: CGFloat = 14
                    let horizontalPadding: CGFloat = 18
                    let usableWidth = max(1, proxy.size.width - (horizontalPadding * 2) - (CGFloat(columns - 1) * spacing))
                    let side = floor(usableWidth / CGFloat(columns))

                    VStack(alignment: .leading, spacing: spacing) {
                        ForEach(0 ..< 3, id: \.self) { _ in
                            HStack(spacing: spacing) {
                                ForEach(0 ..< columns, id: \.self) { _ in
                                    VStack(spacing: 6) {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(.quaternary.opacity(0.35))
                                            .frame(width: side, height: side)
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(.quaternary.opacity(0.3))
                                            .frame(width: side * 0.68, height: 12)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 74)
                    .padding(.horizontal, horizontalPadding)
                }
            }
        }
        .allowsHitTesting(false)
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
    private var listThumbnailRequestVersion: [URL: Int] = [:]
    private var listThumbnailVersionCounter = 0
    private var lastThumbnailInvalidationToken = UUID()
    private var pendingInvalidatedThumbnailURLs: Set<URL> = []
    private var pendingThumbnailRefreshURLs: Set<URL> = []
    private var listThumbnailTasksByURL: [URL: Task<Void, Never>] = [:]
    private var isRenderingState = false
    private var lastRenderedItemURLs: [URL] = []
    private var contextMenuTargetURLs: [URL] = []
    private var didApplyInitialColumnFit = false
    private var browserFocusObserver: NSObjectProtocol?

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
        updateListPresentationState(hasItems: !items.isEmpty)
        browserFocusObserver = NotificationCenter.default.addObserver(
            forName: .browserDidRequestFocus,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.focusListForKeyboardNavigation()
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        for task in listThumbnailTasksByURL.values {
            task.cancel()
        }
        listThumbnailTasksByURL.removeAll()
        if let browserFocusObserver {
            NotificationCenter.default.removeObserver(browserFocusObserver)
            self.browserFocusObserver = nil
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncTableWidthToViewportIfNeeded()
        applyInitialColumnFitIfNeeded()
        updateListPresentationState(hasItems: !items.isEmpty)
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
                ThumbnailPipeline.invalidateAllCachedImages()
                for task in listThumbnailTasksByURL.values {
                    task.cancel()
                }
                listThumbnailTasksByURL.removeAll()
                listThumbnailRequestVersion.removeAll()
                pendingThumbnailRefreshURLs.removeAll()
            } else {
                pendingThumbnailRefreshURLs.formUnion(invalidated)
                for url in invalidated {
                    listThumbnailTasksByURL[url]?.cancel()
                    listThumbnailTasksByURL[url] = nil
                    listThumbnailRequestVersion.removeValue(forKey: url)
                }
            }
        }

        syncTableWidthToViewportIfNeeded()
        applyInitialColumnFitIfNeeded()
        updateListPresentationState(hasItems: !items.isEmpty)
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

        if shouldAdoptTableSelectionIntoModel() {
            let urls = Set(
                tableView.selectedRowIndexes.compactMap { row -> URL? in
                    guard row >= 0, row < items.count else { return nil }
                    return items[row].url
                }
            )
            if !urls.isEmpty {
                let focusedURL: URL?
                if tableView.selectedRow >= 0, tableView.selectedRow < items.count {
                    focusedURL = items[tableView.selectedRow].url
                } else {
                    focusedURL = nil
                }
                model.setSelectionFromList(urls, focusedURL: focusedURL)
                updateQuickLookSourceFrameFromCurrentSelection()
            }
            return
        }

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

    private func shouldAdoptTableSelectionIntoModel() -> Bool {
        guard model.selectedFileURLs.isEmpty else { return false }
        guard !tableView.selectedRowIndexes.isEmpty else { return false }
        guard let window = view.window else { return false }
        guard let responderView = window.firstResponder as? NSView else { return false }
        return responderView === tableView || responderView.isDescendant(of: tableView)
    }

    private func focusListForKeyboardNavigation() {
        guard model.browserViewMode == .list else { return }
        guard let window = view.window else { return }
        window.makeFirstResponder(tableView)
    }

    private func focusInspectorFromBrowser() {
        guard model.browserViewMode == .list else { return }
        guard !model.selectedFileURLs.isEmpty else { return }
        _ = NSApp.sendAction(
            #selector(NativeThreePaneSplitViewController.focusInspectorEntryAction(_:)),
            to: nil,
            from: self
        )
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
        tableView.rowHeight = UIMetrics.List.rowHeight
        tableView.usesAlternatingRowBackgroundColors = true
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
        tableView.onActivateSelection = { [weak self] in
            self?.focusInspectorFromBrowser()
        }

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.minWidth = 60
        nameColumn.width = 300
        nameColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        let createdColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("created"))
        createdColumn.title = "Date Created"
        createdColumn.minWidth = 84
        createdColumn.width = 160
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

    private func updateListPresentationState(hasItems: Bool) {
        tableView.usesAlternatingRowBackgroundColors = hasItems
        tableView.headerView?.isHidden = !hasItems
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
                pendingDot.layer?.cornerRadius = UIMetrics.List.pendingDotCornerRadius
                pendingDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
                view.addSubview(pendingDot)

                let iconView = NSImageView(frame: .zero)
                iconView.identifier = NSUserInterfaceItemIdentifier("name-icon")
                iconView.translatesAutoresizingMaskIntoConstraints = false
                iconView.imageScaling = .scaleProportionallyDown
                view.addSubview(iconView)

                NSLayoutConstraint.activate([
                    pendingDot.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: UIMetrics.List.cellHorizontalInset),
                    pendingDot.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    pendingDot.widthAnchor.constraint(equalToConstant: UIMetrics.List.pendingDotSize),
                    pendingDot.heightAnchor.constraint(equalToConstant: UIMetrics.List.pendingDotSize),
                    iconView.leadingAnchor.constraint(equalTo: pendingDot.trailingAnchor, constant: UIMetrics.List.iconGap),
                    iconView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    iconView.widthAnchor.constraint(equalToConstant: UIMetrics.List.iconSize),
                    iconView.heightAnchor.constraint(equalToConstant: UIMetrics.List.iconSize),
                    textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: UIMetrics.List.iconGap),
                    textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -UIMetrics.List.cellHorizontalInset),
                    textField.centerYAnchor.constraint(equalTo: view.centerYAnchor)
                ])
            } else {
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: UIMetrics.List.cellHorizontalInset),
                    textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -UIMetrics.List.cellHorizontalInset),
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
        let menu = NSMenu()
        menu.autoenablesItems = false
        let openState = model.fileActionState(for: .openInDefaultApp, targetURLs: targetURLs)
        let refreshState = model.fileActionState(for: .refreshMetadata, targetURLs: targetURLs)
        let applyState = model.fileActionState(for: .applyMetadataChanges, targetURLs: targetURLs)
        let clearState = model.fileActionState(for: .clearMetadataChanges, targetURLs: targetURLs)
        let restoreState = model.fileActionState(for: .restoreFromLastBackup, targetURLs: targetURLs)

        let openItem = NSMenuItem(title: openState.title, action: #selector(openFromContextMenu(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.isEnabled = openState.isEnabled
        openItem.image = NSImage(systemSymbolName: openState.symbolName, accessibilityDescription: nil)
        menu.addItem(openItem)

        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinderFromContextMenu(_:)), keyEquivalent: "")
        revealItem.target = self
        revealItem.isEnabled = !targetURLs.isEmpty
        revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(revealItem)

        menu.addItem(.separator())

        let applyItem = NSMenuItem(title: applyState.title, action: #selector(applyFromContextMenu(_:)), keyEquivalent: "")
        applyItem.target = self
        applyItem.isEnabled = applyState.isEnabled
        applyItem.image = NSImage(systemSymbolName: applyState.symbolName, accessibilityDescription: nil)
        menu.addItem(applyItem)

        let refreshItem = NSMenuItem(title: refreshState.title, action: #selector(refreshFromContextMenu(_:)), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.isEnabled = refreshState.isEnabled
        refreshItem.image = NSImage(systemSymbolName: refreshState.symbolName, accessibilityDescription: nil)
        menu.addItem(refreshItem)

        let clearItem = NSMenuItem(title: clearState.title, action: #selector(clearFromContextMenu(_:)), keyEquivalent: "")
        clearItem.target = self
        clearItem.isEnabled = clearState.isEnabled
        clearItem.image = NSImage(systemSymbolName: clearState.symbolName, accessibilityDescription: nil)
        menu.addItem(clearItem)

        let restoreItem = NSMenuItem(title: restoreState.title, action: #selector(restoreFromContextMenu(_:)), keyEquivalent: "")
        restoreItem.target = self
        restoreItem.isEnabled = restoreState.isEnabled
        restoreItem.image = NSImage(systemSymbolName: restoreState.symbolName, accessibilityDescription: nil)
        menu.addItem(restoreItem)
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
        }
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

        if let cached = ThumbnailPipeline.cachedImage(for: item.url, minRenderedSide: 1) {
            iconView.image = model.displayImageForCurrentStagedState(cached, fileURL: item.url)
            requestListThumbnailIfNeeded(for: item, row: row, forceRefresh: pendingThumbnailRefreshURLs.contains(item.url))
            return
        }

        iconView.image = ThumbnailPipeline.fallbackIcon(for: item.url, side: 16)

        requestListThumbnailIfNeeded(for: item, row: row, forceRefresh: pendingThumbnailRefreshURLs.contains(item.url))
    }

    private func requestListThumbnailIfNeeded(for item: AppModel.BrowserItem, row _: Int, forceRefresh: Bool) {
        let requiredSide: CGFloat = 64
        if !forceRefresh,
           ThumbnailPipeline.cachedImage(for: item.url, minRenderedSide: requiredSide) != nil {
            return
        }
        listThumbnailVersionCounter += 1
        let requestVersion = listThumbnailVersionCounter
        listThumbnailRequestVersion[item.url] = requestVersion
        listThumbnailTasksByURL[item.url]?.cancel()
        listThumbnailTasksByURL[item.url] = Task { [weak self] in
            guard let self else { return }
            let image = await SharedThumbnailRequestBroker.shared.request(
                url: item.url,
                requiredSide: requiredSide,
                forceRefresh: forceRefresh
            )
            await self.completeListThumbnailRequest(url: item.url, requestVersion: requestVersion, image: image)
        }
    }

    private func completeListThumbnailRequest(url: URL, requestVersion: Int, image: NSImage?) async {
        listThumbnailTasksByURL[url] = nil

        guard listThumbnailRequestVersion[url] == requestVersion else { return }
        pendingThumbnailRefreshURLs.remove(url)
        guard let image else { return }

        guard let row = items.firstIndex(where: { $0.url == url }) else { return }
        let nameColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard nameColumn >= 0,
              let nameCell = tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: false) as? NSTableCellView,
              let currentIcon = nameCell.subviews.first(where: { ($0 as? NSImageView)?.identifier?.rawValue == "name-icon" }) as? NSImageView,
              currentIcon.toolTip == url.path
        else {
            return
        }

        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = Motion.duration
            transition.timingFunction = Motion.timingFunction
            currentIcon.layer?.add(transition, forKey: "listThumbnailSwapFade")
        }
        currentIcon.alphaValue = 1
        currentIcon.image = model.displayImageForCurrentStagedState(image, fileURL: url)
    }
}

private final class BrowserListTableView: NSTableView {
    var onBackgroundClick: (() -> Void)?
    var onModifiedRowClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    var contextMenuProvider: ((Int) -> NSMenu?)?
    var onActivateSelection: (() -> Void)?

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

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift, .function]).isEmpty else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == KeyCode.return || event.keyCode == KeyCode.numpadReturn {
            onActivateSelection?()
            return
        }

        super.keyDown(with: event)
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
    private var layout = AppKitGalleryLayout()

    private var isApplyingProgrammaticSelection = false
    private var contextMenuTargetURLs: [URL] = []
    private var lastRenderedURLs: [URL] = []
    private var lastRenderedSelected: Set<URL> = []
    private var lastRenderedPending: Set<URL> = []
    private var lastRenderedPrimarySelectionURL: URL?
    private var lastStagedOpsDisplayToken: UInt64 = 0
    private var thumbnailRequestVersion: [URL: Int] = [:]
    private var thumbnailVersionCounter = 0
    private var lastThumbnailInvalidationToken = UUID()
    private var pendingThumbnailRefreshURLs: Set<URL> = []
    private var thumbnailTasksByURL: [URL: Task<Void, Never>] = [:]
    private var isRenderingState = false
    private var zoomRestoreToken = 0
    private var pinchAccumulator: CGFloat = 0
    private var lastMagnification: CGFloat = 0
    private let pinchThreshold: CGFloat = 0.14
    private var browserFocusObserver: NSObjectProtocol?

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
        browserFocusObserver = NotificationCenter.default.addObserver(
            forName: .browserDidRequestFocus,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.focusGalleryForKeyboardNavigation()
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        for task in thumbnailTasksByURL.values {
            task.cancel()
        }
        thumbnailTasksByURL.removeAll()
        if let browserFocusObserver {
            NotificationCenter.default.removeObserver(browserFocusObserver)
            self.browserFocusObserver = nil
        }
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
                for task in thumbnailTasksByURL.values {
                    task.cancel()
                }
                thumbnailTasksByURL.removeAll()
                thumbnailRequestVersion.removeAll()
                pendingThumbnailRefreshURLs.removeAll()
                collectionView.reloadData()
            } else {
                pendingThumbnailRefreshURLs.formUnion(invalidated)
                for url in invalidated {
                    thumbnailTasksByURL[url]?.cancel()
                    thumbnailTasksByURL[url] = nil
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

        if listChanged || columnsChanged || selectionChanged {
            syncSelection(selectedURLs: selectedURLs, scrollPrimaryIntoView: primaryChanged)
            lastRenderedSelected = selectedURLs
            lastRenderedPrimarySelectionURL = model.primarySelectionURL
        }

        if listChanged || columnsChanged || selectionChanged || pendingChanged || stagedOpsChanged {
            refreshVisibleCellState(
                pendingURLs: pendingURLs,
                selectedURLs: selectedURLs,
                needsFullReconfigure: listChanged || columnsChanged || pendingChanged || stagedOpsChanged
            )
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
            } else {
                cell.applySelection(isSelected: selectedURLs.contains(item.url))
                cell.applyPending(hasPendingEdits: pendingURLs.contains(item.url))
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

    private func requestThumbnailIfNeeded(for item: AppModel.BrowserItem, tileSide: CGFloat) {
        let requiredSide = max(tileSide, 120)
        let forceRefresh = pendingThumbnailRefreshURLs.contains(item.url)
        if forceRefresh {
            ThumbnailPipeline.invalidateCachedImages(for: [item.url])
        } else if ThumbnailPipeline.cachedImage(for: item.url, minRenderedSide: requiredSide * 0.9) != nil {
            return
        }
        thumbnailVersionCounter += 1
        let requestVersion = thumbnailVersionCounter
        thumbnailRequestVersion[item.url] = requestVersion
        thumbnailTasksByURL[item.url]?.cancel()
        thumbnailTasksByURL[item.url] = Task { [weak self] in
            guard let self else { return }
            let image = await SharedThumbnailRequestBroker.shared.request(
                url: item.url,
                requiredSide: requiredSide * 2,
                forceRefresh: forceRefresh
            )
            await self.completeThumbnailRequest(
                url: item.url,
                requiredSide: requiredSide,
                requestVersion: requestVersion,
                image: image
            )
        }
    }

    private func completeThumbnailRequest(
        url: URL,
        requiredSide: CGFloat,
        requestVersion: Int,
        image: NSImage?
    ) async {
        thumbnailTasksByURL[url] = nil

        guard thumbnailRequestVersion[url] == requestVersion else { return }
        guard let image else { return }

        pendingThumbnailRefreshURLs.remove(url)

        guard let row = items.firstIndex(where: { $0.url == url }) else { return }
        let indexPath = IndexPath(item: row, section: 0)
        guard let cell = collectionView.item(at: indexPath) as? AppKitGalleryItem else { return }
        let item = items[row]
        let displayImage = model.displayImageForCurrentStagedState(image, fileURL: url)
        cell.configure(
            name: item.name,
            image: displayImage,
            isSelected: model.selectedFileURLs.contains(url),
            hasPendingEdits: model.hasPendingEdits(for: url),
            tileSide: max(layout.tileSide, 40),
            preferredAspectRatio: preferredAspectRatio(for: url)
        )
        updateQuickLookArtifacts()
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
        let refreshState = model.fileActionState(for: .refreshMetadata, targetURLs: contextMenuTargetURLs)
        let applyState = model.fileActionState(for: .applyMetadataChanges, targetURLs: contextMenuTargetURLs)
        let clearState = model.fileActionState(for: .clearMetadataChanges, targetURLs: contextMenuTargetURLs)
        let restoreState = model.fileActionState(for: .restoreFromLastBackup, targetURLs: contextMenuTargetURLs)

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
        menu.addItem(makeItem("Reveal in Finder", action: #selector(revealInFinderFromContextMenu(_:)), symbolName: "folder", enabled: !contextMenuTargetURLs.isEmpty))
        menu.addItem(.separator())
        menu.addItem(makeItem(applyState.title, action: #selector(applyFromContextMenu(_:)), symbolName: applyState.symbolName, enabled: applyState.isEnabled))
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
    private var preferredAspectRatio: CGFloat?
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?

    override func loadView() {
        view = NSView(frame: .zero)
        configureViewHierarchy()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let liveSide = max(1, floor(min(thumbnailContainer.bounds.width, thumbnailContainer.bounds.height)))
        updateTileSide(liveSide, animated: false)
    }

    private func configureViewHierarchy() {
        view.wantsLayer = true

        thumbnailContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.wantsLayer = true
        view.addSubview(thumbnailContainer)

        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = UIMetrics.Gallery.thumbnailCornerRadius
        thumbnailImageView.layer?.masksToBounds = true
        thumbnailContainer.addSubview(thumbnailImageView)

        selectionOverlay.translatesAutoresizingMaskIntoConstraints = false
        selectionOverlay.wantsLayer = true
        // Derived from thumbnailCornerRadius + selectionOutset so the ring corners
        // always track the thumbnail corners — one source of truth.
        selectionOverlay.layer?.cornerRadius = UIMetrics.Gallery.thumbnailCornerRadius + UIMetrics.Gallery.selectionOutset
        selectionOverlay.layer?.masksToBounds = true
        selectionOverlay.layer?.borderWidth = UIMetrics.Gallery.selectionBorderWidth
        selectionOverlay.layer?.borderColor = NSColor.clear.cgColor
        thumbnailContainer.addSubview(selectionOverlay)

        pendingDot.translatesAutoresizingMaskIntoConstraints = false
        pendingDot.wantsLayer = true
        pendingDot.layer?.cornerRadius = UIMetrics.Gallery.pendingDotCornerRadius
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

            // Anchor overlay directly to the image view so it is always
            // definitionally concentric — no independent size calculation needed.
            selectionOverlay.centerXAnchor.constraint(equalTo: thumbnailImageView.centerXAnchor),
            selectionOverlay.centerYAnchor.constraint(equalTo: thumbnailImageView.centerYAnchor),

            pendingDot.widthAnchor.constraint(equalToConstant: UIMetrics.Gallery.pendingDotSize),
            pendingDot.heightAnchor.constraint(equalToConstant: UIMetrics.Gallery.pendingDotSize),
            pendingDot.trailingAnchor.constraint(equalTo: selectionOverlay.trailingAnchor, constant: -UIMetrics.Gallery.pendingDotInset),
            pendingDot.topAnchor.constraint(equalTo: selectionOverlay.topAnchor, constant: UIMetrics.Gallery.pendingDotInset),

            titleField.topAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: UIMetrics.Gallery.titleGap),
            titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleField.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titleField.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])

        imageWidthConstraint = thumbnailImageView.widthAnchor.constraint(equalToConstant: 20)
        imageHeightConstraint = thumbnailImageView.heightAnchor.constraint(equalToConstant: 20)
        // Overlay size is always imageView + outset on each side; auto-tracks during animation.
        let overlayW = selectionOverlay.widthAnchor.constraint(
            equalTo: thumbnailImageView.widthAnchor, constant: UIMetrics.Gallery.selectionOutset * 2)
        let overlayH = selectionOverlay.heightAnchor.constraint(
            equalTo: thumbnailImageView.heightAnchor, constant: UIMetrics.Gallery.selectionOutset * 2)
        imageWidthConstraint?.isActive = true
        imageHeightConstraint?.isActive = true
        overlayW.isActive = true
        overlayH.isActive = true
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
        setImage(image)
        applySelection(isSelected: isSelected)
        applyPending(hasPendingEdits: hasPendingEdits)
        updateTileSide(tileSide, animated: false)
    }

    func updateTileSide(_ tileSide: CGFloat, animated: Bool) {
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
        selectionOverlay.layer?.borderColor = isSelected ? AppTheme.accentStrongNSColor.cgColor : NSColor.clear.cgColor
    }

    func applyPending(hasPendingEdits: Bool) {
        pendingDot.isHidden = !hasPendingEdits
    }

    func setImage(_ image: NSImage?) {
        guard thumbnailImageView.image !== image else { return }
        let shouldFadeTransition = thumbnailImageView.image != nil
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
            thumbnailImageView.alphaValue = 1
            thumbnailImageView.image = image
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
        let aspect: CGFloat
        // Prefer the rendered image dimensions so the selector always matches what is on screen.
        if let fallbackImageSize, fallbackImageSize.width > 0, fallbackImageSize.height > 0 {
            aspect = fallbackImageSize.width / fallbackImageSize.height
        } else if let preferredAspectRatio, preferredAspectRatio > 0 {
            aspect = preferredAspectRatio
        } else {
            aspect = 1
        }

        if aspect >= 1 {
            let width = max(1, floor(side))
            let height = max(1, floor(side / aspect))
            return CGSize(width: width, height: height)
        } else {
            let width = max(1, floor(side * aspect))
            let height = max(1, floor(side))
            return CGSize(width: width, height: height)
        }
    }
}
struct InspectorView: View {
    let model: AppModel
    private let topScrollStartInset: CGFloat = 56
    private let contentHorizontalInset: CGFloat = 16
    private let sectionInnerInset: CGFloat = 12
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedTagID: String?
    @State private var editSessionSnapshots: [String: AppModel.EditSessionSnapshot] = [:]
    @State private var activeEditTagID: String?
    @State private var suppressNextFocusScrollAnimation = false
    @State private var inspectorRefreshRevision: UInt64 = 0

    var body: some View {
        let _ = inspectorRefreshRevision
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
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { !model.isInspectorSectionCollapsed("Preview") },
                                set: { _ in
                                    var t = Transaction(animation: appAnimation())
                                    if reduceMotion { t.disablesAnimations = true }
                                    withTransaction(t) { model.toggleInspectorSection("Preview") }
                                }
                            )
                        ) {
                            if let previewURL = primarySelectedFileURL {
                                VStack(spacing: 10) {
                                    InspectorPreviewImageView(model: model, fileURL: previewURL)
                                        .frame(maxWidth: .infinity)

                                    Divider()

                                    HStack(spacing: 0) {
                                        Button {
                                            model.rotateLeft(fileURL: previewURL)
                                        } label: {
                                            InspectorPreviewActionLabel(symbolName: "rotate.left", title: "Rotate")
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(InspectorPreviewActionButtonStyle())

                                        Divider()
                                            .frame(height: 28)

                                        Button {
                                            model.flipHorizontal(fileURL: previewURL)
                                        } label: {
                                            InspectorPreviewActionLabel(symbolName: "flip.horizontal", title: "Flip")
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(InspectorPreviewActionButtonStyle())

                                        Divider()
                                            .frame(height: 28)

                                        Button {
                                            model.openInDefaultApp(previewURL)
                                        } label: {
                                            InspectorPreviewActionLabel(symbolName: "arrow.up.forward.app", title: "Open")
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(InspectorPreviewActionButtonStyle())
                                    }
                                }
                                .padding(sectionInnerInset)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.quaternary.opacity(0.35))
                                )
                            }
                        } label: {
                            Text("PREVIEW")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.accentColor)
                                .tracking(0.4)
                        }
                        .padding(.horizontal, contentHorizontalInset)
                    }

                    ForEach(model.groupedEditableTags, id: \.section) { grouped in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { !model.isInspectorSectionCollapsed(grouped.section) },
                                set: { _ in
                                    var t = Transaction(animation: appAnimation())
                                    if reduceMotion { t.disablesAnimations = true }
                                    withTransaction(t) { model.toggleInspectorSection(grouped.section) }
                                }
                            )
                        ) {
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
                                                        DatePicker(
                                                            "",
                                                            selection: Binding(
                                                                get: { model.dateValueForTag(tag) ?? date },
                                                                set: {
                                                                    beginEditSessionIfNeeded(for: tag)
                                                                    model.updateDateValue($0, for: tag)
                                                                }
                                                            ),
                                                            displayedComponents: [.date, .hourAndMinute]
                                                        )
                                                        .labelsHidden()
                                                        .datePickerStyle(.stepperField)
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
                                                Picker("", selection: Binding(
                                                    get: { model.valueForTag(tag) },
                                                    set: {
                                                        beginEditSessionIfNeeded(for: tag)
                                                        model.updateValue($0, for: tag)
                                                    }
                                                )) {
                                                    ForEach(options, id: \.value) { option in
                                                        Text(option.label).tag(option.value)
                                                    }
                                                }
                                                .labelsHidden()
                                                .pickerStyle(.menu)
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
                                                        .foregroundStyle(.secondary)
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
                        } label: {
                            Text(grouped.section.uppercased())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.accentColor)
                                .tracking(0.4)
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
            .animation(appAnimation(), value: model.collapsedInspectorSections)
            .onChange(of: focusedTagID) { oldValue, newValue in
                guard let newValue else { return }
                guard oldValue != nil else { return }
                DispatchQueue.main.async {
                    if suppressNextFocusScrollAnimation {
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            proxy.scrollTo(newValue)
                        }
                        suppressNextFocusScrollAnimation = false
                    } else {
                        withAnimation(appAnimation()) {
                            proxy.scrollTo(newValue)
                        }
                    }
                }
            }
        }
        .onChange(of: model.selectedFileURLs) { _, _ in
            editSessionSnapshots.removeAll()
            focusedTagID = nil
            activeEditTagID = nil
            suppressNextFocusScrollAnimation = true
        }
        .onAppear {
            inspectorRefreshRevision = model.inspectorRefreshRevision
        }
        .onReceive(model.$inspectorRefreshRevision.removeDuplicates()) { revision in
            inspectorRefreshRevision = revision
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
        .sheet(item: Binding(
            get: { model.activePresetEditor },
            set: { model.activePresetEditor = $0 }
        )) { editor in
            PresetEditorSheet(
                model: model,
                initialEditor: editor
            )
        }
        .tint(AppTheme.accentColor)
        .sheet(isPresented: Binding(
            get: { model.isManagePresetsPresented },
            set: { model.isManagePresetsPresented = $0 }
        )) {
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
        if let (width, height) = model.imagePixelDimensions(for: url),
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
        let focusableTagIDs = focusableInspectorTagIDs()

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

        guard focusedTagID != nextID else { return }
        focusedTagID = nextID
    }

    private func focusableInspectorTagIDs() -> [String] {
        model.groupedEditableTags
            .filter { !model.isInspectorSectionCollapsed($0.section) }
            .flatMap(\.tags)
            .filter { tag in
                !model.isDateTimeTag(tag) && model.pickerOptions(for: tag) == nil
            }
            .map(\.id)
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
                Button("Cancel") {
                    let reopenManagePresets: Bool = {
                        switch editor.mode {
                        case .createFromCurrent:
                            return false
                        case .createBlank, .edit:
                            return true
                        }
                    }()
                    model.dismissPresetEditor(reopenManagePresets: reopenManagePresets)
                }
                    .keyboardShortcut(.cancelAction)
                Button(editorPrimaryButtonTitle) {
                    handleSave()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 760, height: 520)
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
            set: { updatePresetValue($0, for: tag) }
        )
    }

    private func updatePresetValue(_ value: String, for tag: AppModel.EditableTag) {
        editor.valuesByTagID[tag.id] = value
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editor.includedTagIDs.insert(tag.id)
        }
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
                            set: { updatePresetValue(model.formatEditableDateValue($0), for: tag) }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .datePickerStyle(.field)

                    Button {
                        updatePresetValue("", for: tag)
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
                        updatePresetValue(model.formatEditableDateValue(Date()), for: tag)
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

private struct InspectorPreviewImageView: View {
    @ObservedObject var model: AppModel
    let fileURL: URL

    var body: some View {
        ZStack(alignment: .topLeading) {
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

            if model.hasPendingImageEdits(for: fileURL) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 9, height: 9)
                    .padding(8)
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: previewTaskID) {
            model.ensureInspectorPreviewLoaded(for: fileURL)
        }
    }

    private var previewTaskID: String {
        "\(fileURL.path)::\(model.inspectorRefreshRevision)"
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
