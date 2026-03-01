@preconcurrency import AppKit
import Combine
import ExifEditCore
import MapKit
import SwiftUI

extension Notification.Name {
    static let inspectorDidRequestBrowserFocus = Notification.Name("\(AppBrand.identifierPrefix).InspectorDidRequestBrowserFocus")
    static let inspectorDidRequestFieldNavigation = Notification.Name("\(AppBrand.identifierPrefix).InspectorDidRequestFieldNavigation")
    static let sidebarDidRequestFocus = Notification.Name("\(AppBrand.identifierPrefix).SidebarDidRequestFocus")
    static let browserDidRequestFocus = Notification.Name("\(AppBrand.identifierPrefix).BrowserDidRequestFocus")
    static let browserDidSwitchViewMode = Notification.Name("\(AppBrand.identifierPrefix).BrowserDidSwitchViewMode")
}

enum Motion {
    static let duration: Double = 0.16
    static var timingFunction: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }
}

enum KeyCode {
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

enum UIMetrics {
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
    }

    enum Gallery {
        static let thumbnailCornerRadius: CGFloat = 8
        static let selectionOutset: CGFloat = 5
        static let selectionBorderWidth: CGFloat = 3.5
        static let pendingDotSize: CGFloat = 8
        static let pendingDotInset: CGFloat = 6
        static let titleGap: CGFloat = 6
    }
}

func appAnimation() -> Animation? {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        return nil
    }
    return .easeInOut(duration: Motion.duration)
}

actor SharedThumbnailRequestBroker {
    static let shared = SharedThumbnailRequestBroker()

    func request(url: URL, requiredSide: CGFloat, forceRefresh: Bool) async -> NSImage? {
        await ThumbnailService.request(
            url: url,
            requiredSide: requiredSide,
            forceRefresh: forceRefresh
        )
    }
}

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
        let toolbar = NSToolbar(identifier: "\(AppBrand.identifierPrefix).MainToolbar.v4")
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
    /// Also calls rebuildViewMenu immediately so Zoom In/Out keyboard shortcuts
    /// are registered from launch — not only after the user first opens the menu.
    /// menuWillOpen re-runs the rebuild after SwiftUI rebuilds wipe injected items.
    private func injectSortMenuIfNeeded() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for topItem in mainMenu.items {
            guard let submenu = topItem.submenu else { continue }
            if submenu.items.contains(where: { $0.title == "Toggle Sidebar" }) {
                viewMenuForSortInjection = submenu
                submenu.delegate = self
                rebuildViewMenu(submenu)
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
            if submenu.items.contains(where: { $0.title == "Refresh" || $0.title == "Refresh Files and Metadata" }) {
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
            let hasInjectedApplyItems = menu.items.contains { item in
                item.action == #selector(applySelectionAction(_:)) || item.action == #selector(applyFolderAction(_:))
            }
            if !hasInjectedApplyItems {
                let anchor = (menu.items.firstIndex(where: { $0.title == "Refresh" || $0.title == "Refresh Files and Metadata" }) ?? -1) + 1
                // Insert in reverse so final order is: Apply Selection, Apply Folder, Clear, Restore
                let restoreItem = NSMenuItem(title: "Restore from Backup", action: #selector(restoreFromBackupAction(_:)), keyEquivalent: "b")
                restoreItem.keyEquivalentModifierMask = [.command, .shift]
                let clearItem = NSMenuItem(title: "Clear Metadata Changes", action: #selector(clearChangesAction(_:)), keyEquivalent: "k")
                clearItem.keyEquivalentModifierMask = [.command, .shift]
                let applyFolderItem = NSMenuItem(title: "Apply Metadata Changes to Folder", action: #selector(applyFolderAction(_:)), keyEquivalent: "")
                let applySelectionItem = NSMenuItem(title: "Apply Metadata Changes to Selection", action: #selector(applySelectionAction(_:)), keyEquivalent: "s")
                applySelectionItem.keyEquivalentModifierMask = .command
                menu.insertItem(restoreItem, at: anchor)
                menu.insertItem(clearItem, at: anchor)
                menu.insertItem(applyFolderItem, at: anchor)
                menu.insertItem(applySelectionItem, at: anchor)
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
            menuItem.title = model.applyMetadataSelectionTitle(for: selection)
            return model.fileActionState(for: .applyMetadataChanges, targetURLs: selection).isEnabled
        } else if menuItem.action == #selector(applyFolderAction(_:)) {
            menuItem.title = "Apply Metadata Changes to Folder"
            return model.canApplyMetadataChanges
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
        if model.isApplyingMetadata {
            let total = max(model.applyMetadataTotal, 0)
            let done = min(max(model.applyMetadataCompleted, 0), total)
            return "Applying \(done) of \(total)…"
        }
        if model.isFolderMetadataLoading {
            let total = max(model.folderMetadataLoadTotal, 0)
            let done = min(max(model.folderMetadataLoadCompleted, 0), total)
            return total > 0 ? "Loading \(done) of \(total)…" : "Loading…"
        }
        let status = model.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty, status != "Ready" {
            return status
        }
        let total = model.browserItems.count
        guard total > 0 else { return "" }
        let selected = model.selectedFileURLs.count
        if selected > 0, selected < total {
            return "\(selected) of \(total) images"
        }
        return total == 1 ? "1 image" : "\(total) images"
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
            alert.messageText = "Apply Metadata Changes?"
            alert.informativeText = "Metadata changes for \(pendingCount) image(s) in this folder will be written to disk. This can’t be undone."
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
    func applyFolderAction(_: Any?) {
        applyChangesAction(nil)
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
        NotificationCenter.default.post(name: .browserDidSwitchViewMode, object: nil)
    }

    @objc
    func switchToListAction(_: Any?) {
        model.browserViewMode = .list
        nativeToolbarDelegate?.refreshFromModel()
        NotificationCenter.default.post(name: .browserDidSwitchViewMode, object: nil)
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
        NotificationCenter.default.post(name: .browserDidSwitchViewMode, object: nil)
        DispatchQueue.main.async { [weak self] in
            self?.focusBrowserPane()
        }
    }

    private func confirmAndApplyPreset(preset: MetadataPreset) {
        let fileCount = model.selectedFileURLs.count
        guard fileCount > 0 else {
            model.statusMessage = "Select one or more files first."
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Apply “\(preset.name)”?"
        alert.informativeText = "This will update metadata for \(fileCount) image(s). Preset fields will overwrite existing values."
        alert.addButton(withTitle: "Apply")
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

        private var sortItem: NSToolbarItem?
        private var presetsItem: NSToolbarItem?
        private var sortMenu: NSMenu?
        private var presetsMenu: NSMenu?

        init(controller: NativeThreePaneSplitViewController) {
            self.controller = controller
        }

        func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
            return [
                .flexibleSpace,
                .openFolder,
                .toggleSidebar,
                .sidebarTrackingSeparator,
                .viewMode,
                .sort,
                .zoomOut,
                .zoomIn,
                .flexibleSpace,
                .presetTools,
                .applyChanges,
                .inspectorTrackingSeparator,
                .toggleInspector
            ]
        }

        func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
            return [
                .flexibleSpace,
                .openFolder,
                .toggleSidebar,
                .sidebarTrackingSeparator,
                .viewMode,
                .sort,
                .zoomOut,
                .zoomIn,
                .flexibleSpace,
                .presetTools,
                .applyChanges,
                .inspectorTrackingSeparator,
                .toggleInspector
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
            case .inspectorTrackingSeparator:
                // Bind tracking to the inner browser/inspector divider.
                return NSTrackingSeparatorToolbarItem(
                    identifier: .inspectorTrackingSeparator,
                    splitView: controller.contentSplitController.splitView,
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
                item.toolTip = "Zoom out"
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
                item.toolTip = "Zoom in"
                zoomInItem = item
                return item
            case .sort:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Sort"
                item.paletteLabel = "Sort"
                item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
                item.target = self
                item.action = #selector(showSortMenu(_:))
                item.toolTip = "Sort images"
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
                item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Open Folder")
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.openFolderAction(_:))
                item.toolTip = "Open a folder"
                return item
            case .applyChanges:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Apply Changes"
                item.paletteLabel = "Apply Changes"
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
                item.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Show or hide the inspector")
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.toggleInspectorAction(_:))
                item.toolTip = label
                inspectorToggleItem = item
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

        private func updateApplyEnabled(with model: AppModel) {
            applyChangesItem?.isEnabled = model.canApplyMetadataChanges
        }

        private func updateInspectorToggle(with model: AppModel) {
            let label = model.isInspectorCollapsed ? "Show Inspector" : "Hide Inspector"
            inspectorToggleItem?.label = label
            inspectorToggleItem?.toolTip = label
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
    static let inspectorTrackingSeparator = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.InspectorTrackingSeparator")
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
                description: Text("Open a folder from the toolbar to browse and edit image metadata.")
            )
        case let .enumerationError(message):
            ContentUnavailableView(
                "Folder Unavailable",
                systemImage: "lock.fill",
                description: Text(message)
            )
        case .emptyFolder:
            ContentUnavailableView(
                "No Supported Images",
                systemImage: "photo.on.rectangle.angled",
                description: Text("This folder contains no image files supported by Ledger.")
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
