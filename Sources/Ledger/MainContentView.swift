@preconcurrency import AppKit
import Combine
import ExifEditCore
import MapKit
import SharedUI
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let inspectorDidRequestBrowserFocus = Notification.Name("\(AppBrand.identifierPrefix).InspectorDidRequestBrowserFocus")
    static let sidebarDidRequestFocus = Notification.Name("\(AppBrand.identifierPrefix).SidebarDidRequestFocus")
    static let browserDidRequestFocus = Notification.Name("\(AppBrand.identifierPrefix).BrowserDidRequestFocus")
    static let browserDidSwitchViewMode = Notification.Name("\(AppBrand.identifierPrefix).BrowserDidSwitchViewMode")
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
        static let pendingDotSize: CGFloat = 8
        static let pendingDotInset: CGFloat = 6
        static let titleGap: CGFloat = 6
    }
}

final class NativeThreePaneSplitViewController: ThreePaneSplitViewController, NSMenuItemValidation, NSMenuDelegate {
    private var model: AppModel

    private let sidebarController: AppKitSidebarController<LedgerSidebarSection, LedgerSidebarItem>
    private let browserController: BrowserContainerViewController
    private let inspectorController: NSHostingController<AnyView>

    private var didConfigureWindow = false
    private var mainToolbarController: MainToolbarController?
    private var toolbarShellController: ToolbarShellController?
    private weak var fileMenuForInjection: NSMenu?
    private weak var editMenuForInjection: NSMenu?
    private weak var viewMenuForSortInjection: NSMenu?
    private weak var imageMenuForInjection: NSMenu?
    private weak var helpMenuForInjection: NSMenu?
    private var menuTrackingObserver: NSObjectProtocol?
    private var uiRefreshObservers: [AnyCancellable] = []
    private var browserFocusRequestObserver: NSObjectProtocol?
    private var lastWindowTitleText = ""
    private var lastWindowSubtitleText = ""
    private var isModelUIRefreshScheduled = false
    private var isSidebarReloadScheduled = false
    private var isSidebarSelectionSyncScheduled = false
    init(model: AppModel) {
        self.model = model

        let sc = AppKitSidebarController(
            sections: Self.buildSidebarSections(from: model),
            items: Self.buildSidebarItems(from: model),
            initialSelectionBehavior: .noInitialSelection
        )
        let bc = BrowserContainerViewController(model: model)
        let ic = NSHostingController(rootView: AnyView(InspectorView(model: model).tint(AppTheme.accentColor)))
        // Prevent inspector content from forcing pane expansion during SwiftUI view updates.
        ic.sizingOptions = []

        self.sidebarController = sc
        self.browserController = bc
        self.inspectorController = ic

        super.init(
            sidebar: sc,
            content: bc,
            inspector: ic,
            mainSplitAutosaveName: Self.mainSplitAutosaveName,
            contentSplitAutosaveName: Self.contentSplitAutosaveName
        )

        sc.onSelectionChange = { [weak self] item in
            self?.model.handleExplicitSidebarSelectionChange(to: item.id)
        }
        sc.menuProvider = { [weak self] item in
            self?.buildSidebarContextMenu(for: item)
        }
        sc.onItemsReordered = { [weak self] reorderedItems in
            self?.applySidebarReorder(from: reorderedItems)
        }

        onPaneStateChanged = { [weak self] in
            guard let self else { return }
            let sc = self.isSidebarCollapsed
            let ic = self.isInspectorCollapsed
            if self.model.isSidebarCollapsed != sc { self.model.isSidebarCollapsed = sc }
            if self.model.isInspectorCollapsed != ic { self.model.isInspectorCollapsed = ic }
            self.refreshToolbarState()
        }

        installUIRefreshObservers()
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
        uiRefreshObservers.removeAll()
        if let browserFocusRequestObserver {
            NotificationCenter.default.removeObserver(browserFocusRequestObserver)
            self.browserFocusRequestObserver = nil
        }
        if let menuTrackingObserver {
            NotificationCenter.default.removeObserver(menuTrackingObserver)
            self.menuTrackingObserver = nil
        }
    }

    private func installUIRefreshObservers() {
        func observe<Value: Equatable>(_ publisher: Published<Value>.Publisher) {
            observeEquatable(publisher, storeIn: &uiRefreshObservers) { [weak self] in
                self?.scheduleModelDrivenUIRefresh()
            }
        }

        observe(model.$selectedSidebarID)
        observe(model.$selectedFileURLs)
        observe(model.$browserItems)
        observe(model.$browserViewMode)
        observe(model.$browserSort)
        observe(model.$browserSortAscending)
        observe(model.$galleryGridLevel)
        observe(model.$isApplyingMetadata)
        observe(model.$applyMetadataCompleted)
        observe(model.$applyMetadataTotal)
        observe(model.$isFolderMetadataLoading)
        observe(model.$folderMetadataLoadCompleted)
        observe(model.$folderMetadataLoadTotal)
        observe(model.$statusMessage)
        observe(model.$isSidebarCollapsed)
        observe(model.$isInspectorCollapsed)
        observe(model.$inspectorRefreshRevision)
        observe(model.$stagedOpsDisplayToken)

        // Sidebar data — rebuild and reload when the item list or image counts change.
        observeEquatable(model.$sidebarItems, storeIn: &uiRefreshObservers) { [weak self] in
            self?.scheduleSidebarReload()
        }
        observeEquatable(model.$sidebarImageCounts, storeIn: &uiRefreshObservers) { [weak self] in
            self?.scheduleSidebarReload()
        }
        // Sidebar selection — sync model-driven selection changes back to the controller
        // (e.g. when an unsaved-edits guard reverts the selection, or programmatic changes).
        observeEquatable(model.$selectedSidebarID, storeIn: &uiRefreshObservers) { [weak self] in
            self?.scheduleSidebarSelectionSync()
        }
    }

    private func scheduleModelDrivenUIRefresh() {
        guard !isModelUIRefreshScheduled else { return }
        isModelUIRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isModelUIRefreshScheduled = false
            self.refreshToolbarState()
            self.refreshWindowTitleSubtitleIfNeeded()
        }
    }

    private func scheduleSidebarReload() {
        guard !isSidebarReloadScheduled else { return }
        isSidebarReloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSidebarReloadScheduled = false
            self.sidebarController.sections = Self.buildSidebarSections(from: self.model)
            self.sidebarController.items = Self.buildSidebarItems(from: self.model)
            self.sidebarController.reloadData()
        }
    }

    private func scheduleSidebarSelectionSync() {
        guard !isSidebarSelectionSyncScheduled else { return }
        isSidebarSelectionSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSidebarSelectionSyncScheduled = false
            let id = self.model.selectedSidebarID
            if let id {
                self.sidebarController.selectItem(where: { $0.id == id })
            } else {
                self.sidebarController.clearSelection()
            }
        }
    }

    private func applySidebarReorder(from reorderedItems: [LedgerSidebarItem]) {
        let reorderedFavoriteIDs = reorderedItems
            .filter { $0.section == .pinned && $0.isSidebarReorderable }
            .map(\.id)
        model.applyFavoriteOrder(sidebarIDs: reorderedFavoriteIDs)
    }

    private static func buildSidebarSections(from model: AppModel) -> [LedgerSidebarSection] {
        LedgerSidebarSection.allCases.filter { section in
            model.sidebarItems.contains { $0.section == section.rawValue }
        }
    }

    private static func buildSidebarItems(from model: AppModel) -> [LedgerSidebarItem] {
        model.sidebarItems.compactMap { item in
            guard let section = LedgerSidebarSection(rawValue: item.section) else { return nil }
            let countText = model.sidebarImageCounts[item.id].map { "\($0)" }
            return LedgerSidebarItem(from: item, section: section, countText: countText)
        }
    }

    private func buildSidebarContextMenu(for ledgerItem: LedgerSidebarItem) -> NSMenu? {
        guard let appItem = model.sidebarItems.first(where: { $0.id == ledgerItem.id }) else {
            return nil
        }

        let canFinder = model.canOpenSidebarItemInFinder(appItem)
        let canPin    = model.canPinSidebarItem(appItem)
        let canUnpin  = model.canUnpinSidebarItem(appItem)
        let canRemove = model.canRemoveRecentSidebarItem(appItem)
        let canUp     = model.canMoveFavoriteUp(appItem)
        let canDown   = model.canMoveFavoriteDown(appItem)

        guard canFinder || canPin || canUnpin || canRemove else { return nil }

        let menu = NSMenu()

        if canFinder {
            menu.addItem(ClosureMenuItem(title: "Open in Finder", image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)) {
                [weak self] in self?.model.openSidebarItemInFinder(appItem)
            })
        }

        if canPin {
            if canFinder { menu.addItem(.separator()) }
            menu.addItem(ClosureMenuItem(title: "Pin", image: NSImage(systemSymbolName: "pin", accessibilityDescription: nil)) {
                [weak self] in self?.model.pinSidebarItem(appItem)
            })
            if canRemove {
                menu.addItem(ClosureMenuItem(title: "Remove", image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)) {
                    [weak self] in self?.model.removeRecentSidebarItem(appItem)
                })
            }
        }

        if canUnpin {
            menu.addItem(ClosureMenuItem(title: "Unpin", image: NSImage(systemSymbolName: "pin.slash", accessibilityDescription: nil)) {
                [weak self] in self?.model.unpinSidebarItem(appItem)
            })
            if canRemove {
                menu.addItem(ClosureMenuItem(title: "Remove", image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)) {
                    [weak self] in self?.model.removeRecentSidebarItem(appItem)
                })
            }
            if canUp || canDown {
                menu.addItem(.separator())
                let upItem = ClosureMenuItem(title: "Move Up", image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)) {
                    [weak self] in self?.model.moveFavoriteUp(appItem)
                }
                upItem.isEnabled = canUp
                menu.addItem(upItem)
                let downItem = ClosureMenuItem(title: "Move Down", image: NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)) {
                    [weak self] in self?.model.moveFavoriteDown(appItem)
                }
                downItem.isEnabled = canDown
                menu.addItem(downItem)
            }
        }

        return menu
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        resetSplitAutosaveStateIfNeeded()
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

    private func installMainToolbar(on window: NSWindow, resetDelegateState: Bool) {
        let toolbarContent: MainToolbarController
        if let existing = mainToolbarController {
            toolbarContent = existing
            if resetDelegateState {
                toolbarContent.resetCachedToolbarReferences()
            }
        } else {
            toolbarContent = MainToolbarController(controller: self)
        }
        mainToolbarController = toolbarContent

        let shell = toolbarShellController ?? ToolbarShellController(content: toolbarContent)
        shell.setContent(toolbarContent)
        toolbarShellController = shell
        _ = shell.installToolbar(
            on: window,
            identifier: "\(AppBrand.identifierPrefix).MainToolbar.v5",
            displayMode: .iconOnly,
            allowsUserCustomization: false,
            autosavesConfiguration: false
        )
    }

    private func configureWindowIfNeeded() {
        guard !didConfigureWindow, let window = view.window else { return }
        didConfigureWindow = true

        configureWindowForToolbar(window)

        installMainToolbar(on: window, resetDelegateState: true)
        toolbarShellController?.syncAndValidate(window: window)
        if isSidebarCollapsed { isSidebarCollapsed = false }
        schedulePaneStateSync()
        refreshWindowTitleSubtitleIfNeeded()
        installBrowserFocusRequestObserverIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.focusBrowserPane()
            self?.injectFileMenuIfNeeded()
            self?.injectEditMenuIfNeeded()
            self?.injectSortMenuIfNeeded()
            self?.injectImageMenuIfNeeded()
            self?.injectHelpMenuIfNeeded()
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
                self?.injectFileMenuIfNeeded()
                self?.injectEditMenuIfNeeded()
                self?.injectImageMenuIfNeeded()
                self?.injectHelpMenuIfNeeded()
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

    private func refreshToolbarState() {
        toolbarShellController?.syncAndValidate(window: view.window)
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

    func isSidebarCollapsedForMenu() -> Bool { isSidebarCollapsed }
    func isInspectorCollapsedForMenu() -> Bool { isInspectorCollapsed }

    @objc func toggleInspectorAction(_ sender: Any?) { toggleInspector(sender) }
    @objc func togglePathBarAction(_ sender: Any?) { browserController.setPathBarVisible(!browserController.isPathBarVisible) }

    private enum MenuTag {
        static let fileOpenFolder = 9_101
        static let fileOpenSelection = 9_102
        static let fileOpenWith = 9_103
        static let fileReveal = 9_104
        static let fileQuickLook = 9_105
        static let filePin = 9_106
        static let fileUnpin = 9_107
        static let fileMoveUp = 9_108
        static let fileMoveDown = 9_109
        static let fileImportRoot = 9_110
        static let fileImportCSV = 9_111
        static let fileImportGPX = 9_112
        static let fileImportReferenceFolder = 9_113
        static let fileImportReferenceImage = 9_114
        static let fileImportEOS1V = 9_115
        static let fileExportRoot = 9_116
        static let fileExportExifToolCSV = 9_117
        static let fileExportSendToPhotos = 9_118
        static let fileExportSendToLightroom = 9_119
        static let fileExportSendToLightroomClassic = 9_120

        static let editRotate = 9_201
        static let editFlip = 9_202

        static let imageApplySelection = 9_301
        static let imageRefreshSelection = 9_302
        static let imageClearSelection = 9_303
        static let imageRestoreSelection = 9_304
        static let imageApplyAll = 9_305
        static let imageRefreshAll = 9_306
        static let imageClearAll = 9_307
        static let imageRestoreAll = 9_308
        static let imageSavePreset = 9_309
        static let imageManagePresets = 9_310
        static let imageApplyPreset = 9_311
        static let imageBatchRenameSelection = 9_312
        static let imageBatchRenameFolder = 9_313

        static let helpWhatsNew = 9_400
        static let helpExifToolDocs = 9_401
    }

    private func ensureTopLevelMenu(title: String, insertAfterTitle: String? = nil) -> NSMenu? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        if let existing = mainMenu.items.first(where: { $0.title == title }) {
            if existing.submenu == nil {
                existing.submenu = NSMenu(title: title)
            }
            if let insertAfterTitle,
               let anchorIndex = mainMenu.items.firstIndex(where: { $0.title == insertAfterTitle }),
               let existingIndex = mainMenu.items.firstIndex(of: existing) {
                let desiredIndex = anchorIndex + 1
                if existingIndex != desiredIndex {
                    mainMenu.removeItem(at: existingIndex)
                    let clampedIndex = min(desiredIndex, mainMenu.items.count)
                    mainMenu.insertItem(existing, at: clampedIndex)
                }
            }
            return existing.submenu
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: title)

        if let insertAfterTitle,
           let anchorIndex = mainMenu.items.firstIndex(where: { $0.title == insertAfterTitle }) {
            mainMenu.insertItem(item, at: anchorIndex + 1)
        } else {
            // Keep the app menu first; append otherwise.
            let insertIndex = max(1, mainMenu.items.count)
            if insertIndex <= mainMenu.items.count {
                mainMenu.insertItem(item, at: insertIndex)
            } else {
                mainMenu.addItem(item)
            }
        }
        return item.submenu
    }

    private func injectFileMenuIfNeeded() {
        let appMenuTitle = NSApp.mainMenu?.items.first?.title
        guard let submenu = ensureTopLevelMenu(title: "File", insertAfterTitle: appMenuTitle) else { return }
        fileMenuForInjection = submenu
        submenu.delegate = self
        rebuildFileMenu(submenu)
    }

    private func injectEditMenuIfNeeded() {
        guard let submenu = ensureTopLevelMenu(title: "Edit", insertAfterTitle: "File") else { return }
        editMenuForInjection = submenu
        submenu.delegate = self
        rebuildEditMenu(submenu)
    }

    /// Finds the View menu and registers self as its NSMenuDelegate.
    /// Also calls rebuildViewMenu immediately so Zoom In/Out keyboard shortcuts
    /// are registered from launch.
    private func injectSortMenuIfNeeded() {
        guard let submenu = ensureTopLevelMenu(title: "View", insertAfterTitle: "Edit") else { return }
        viewMenuForSortInjection = submenu
        submenu.delegate = self
        rebuildViewMenu(submenu)
    }

    private func injectImageMenuIfNeeded() {
        guard let submenu = ensureTopLevelMenu(title: "Image", insertAfterTitle: "View") else { return }
        imageMenuForInjection = submenu
        submenu.delegate = self
        rebuildImageMenu(submenu)
    }

    private func injectHelpMenuIfNeeded() {
        if NSApp.mainMenu?.items.contains(where: { $0.title == "Window" }) == true {
            guard let submenu = ensureTopLevelMenu(title: "Help", insertAfterTitle: "Window") else { return }
            helpMenuForInjection = submenu
            submenu.delegate = self
            rebuildHelpMenu(submenu)
            return
        }
        guard let submenu = ensureTopLevelMenu(title: "Help", insertAfterTitle: "Image") else { return }
        helpMenuForInjection = submenu
        submenu.delegate = self
        rebuildHelpMenu(submenu)
    }

    /// Builds and returns the Sort By NSMenuItem with submenu.
    private func makeSortByMenuItem() -> NSMenuItem {
        let sortMenu = NSMenu(title: "Sort By")
        let nameItem = sortMenu.addItem(withTitle: "Name", action: #selector(sortByNameAction(_:)), keyEquivalent: "1")
        nameItem.keyEquivalentModifierMask = [.command, .control, .option]
        let createdItem = sortMenu.addItem(withTitle: "Date Created", action: #selector(sortByCreatedAction(_:)), keyEquivalent: "2")
        createdItem.keyEquivalentModifierMask = [.command, .control, .option]
        let modifiedItem = sortMenu.addItem(withTitle: "Date Modified", action: #selector(sortByModifiedAction(_:)), keyEquivalent: "3")
        modifiedItem.keyEquivalentModifierMask = [.command, .control, .option]
        let sizeItem = sortMenu.addItem(withTitle: "Size", action: #selector(sortBySizeAction(_:)), keyEquivalent: "4")
        sizeItem.keyEquivalentModifierMask = [.command, .control, .option]
        let kindItem = sortMenu.addItem(withTitle: "Kind", action: #selector(sortByKindAction(_:)), keyEquivalent: "5")
        kindItem.keyEquivalentModifierMask = [.command, .control, .option]
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
        guard menu.items.first?.title.lowercased() != "as gallery" else { return }

        // Collect items we don't own so we can keep them.
        var sidebarMenuItem: NSMenuItem?
        var inspectorMenuItem: NSMenuItem?
        var extraItems: [NSMenuItem] = []
        let ownedTitles: Set<String> = ["as gallery", "as list", "sort by", "zoom in", "zoom out", "show path bar", "hide path bar"]

        for item in menu.items where !item.isSeparatorItem {
            let normalizedTitle = item.title.lowercased()
            switch normalizedTitle {
            case "toggle sidebar": sidebarMenuItem = item
            case "toggle inspector": inspectorMenuItem = item
            case _ where ownedTitles.contains(normalizedTitle): break  // will be recreated
            default: extraItems.append(item)
            }
        }

        // Build fresh injected items with images.
        let galleryItem = NSMenuItem(title: "as Gallery", action: #selector(switchToGalleryAction(_:)), keyEquivalent: "1")
        galleryItem.keyEquivalentModifierMask = .command
        galleryItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)

        let listItem = NSMenuItem(title: "as List", action: #selector(switchToListAction(_:)), keyEquivalent: "2")
        listItem.keyEquivalentModifierMask = .command
        listItem.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)

        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(zoomInAction(_:)), keyEquivalent: "+")
        zoomInItem.keyEquivalentModifierMask = .command
        zoomInItem.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil)

        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(zoomOutAction(_:)), keyEquivalent: "-")
        zoomOutItem.keyEquivalentModifierMask = .command
        zoomOutItem.image = NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: nil)

        if sidebarMenuItem == nil {
            let item = NSMenuItem(title: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            item.keyEquivalentModifierMask = [.command, .option]
            sidebarMenuItem = item
        }
        if inspectorMenuItem == nil {
            let item = NSMenuItem(title: "Toggle Inspector", action: #selector(toggleInspectorAction(_:)), keyEquivalent: "i")
            item.keyEquivalentModifierMask = [.command, .option]
            inspectorMenuItem = item
        }
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
        let pathBarItem = NSMenuItem(
            title: browserController.isPathBarVisible ? "Hide Path Bar" : "Show Path Bar",
            action: #selector(togglePathBarAction(_:)),
            keyEquivalent: "p"
        )
        pathBarItem.keyEquivalentModifierMask = [.command, .option]
        pathBarItem.image = NSImage(systemSymbolName: "square.bottomhalf.filled", accessibilityDescription: nil)
        menu.addItem(pathBarItem)
        if !extraItems.isEmpty {
            menu.addItem(.separator())
            extraItems.forEach { menu.addItem($0) }
        }
    }

    private func rebuildFileMenu(_ menu: NSMenu) {
        let systemItems = menu.items.filter { item in
            item.tag < 9_100 && !item.isSeparatorItem && item.title != "New" && item.title != "Open…" && item.title != "Import" && item.title != "Export"
        }

        menu.removeAllItems()

        let openFolderItem = NSMenuItem(title: "Open Folder…", action: #selector(openFolderAction(_:)), keyEquivalent: "n")
        openFolderItem.keyEquivalentModifierMask = .command
        openFolderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        openFolderItem.tag = MenuTag.fileOpenFolder
        menu.addItem(openFolderItem)

        let importItem = NSMenuItem(title: "Import", action: nil, keyEquivalent: "")
        importItem.image = NSImage(systemSymbolName: "checklist.checked", accessibilityDescription: nil)
        importItem.tag = MenuTag.fileImportRoot
        importItem.submenu = makeImportSubmenu()
        menu.addItem(importItem)

        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        exportItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        exportItem.tag = MenuTag.fileExportRoot
        exportItem.submenu = makeExportSubmenu()
        menu.addItem(exportItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open", action: #selector(openInDefaultAppMenuAction(_:)), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = .command
        openItem.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        openItem.tag = MenuTag.fileOpenSelection
        menu.addItem(openItem)

        let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWithItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        openWithItem.tag = MenuTag.fileOpenWith
        openWithItem.submenu = makeOpenWithSubmenu()
        menu.addItem(openWithItem)

        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealSelectionInFinderMenuAction(_:)), keyEquivalent: "")
        revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        revealItem.tag = MenuTag.fileReveal
        menu.addItem(revealItem)

        let quickLookItem = NSMenuItem(title: "Quick Look", action: #selector(quickLookSelectionMenuAction(_:)), keyEquivalent: "y")
        quickLookItem.keyEquivalentModifierMask = .command
        quickLookItem.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        quickLookItem.tag = MenuTag.fileQuickLook
        menu.addItem(quickLookItem)

        menu.addItem(.separator())

        let pinItem = NSMenuItem(title: "Pin Folder", action: #selector(pinFolderToSidebarAction(_:)), keyEquivalent: "t")
        pinItem.keyEquivalentModifierMask = [.command, .option]
        pinItem.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        pinItem.tag = MenuTag.filePin
        menu.addItem(pinItem)

        let unpinItem = NSMenuItem(title: "Unpin Folder", action: #selector(unpinFolderFromSidebarAction(_:)), keyEquivalent: "")
        unpinItem.image = NSImage(systemSymbolName: "pin.slash", accessibilityDescription: nil)
        unpinItem.tag = MenuTag.fileUnpin
        menu.addItem(unpinItem)

        let moveUpItem = NSMenuItem(title: "Move Folder Up", action: #selector(moveFolderUpInSidebarAction(_:)), keyEquivalent: "")
        moveUpItem.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        moveUpItem.tag = MenuTag.fileMoveUp
        menu.addItem(moveUpItem)

        let moveDownItem = NSMenuItem(title: "Move Folder Down", action: #selector(moveFolderDownInSidebarAction(_:)), keyEquivalent: "")
        moveDownItem.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        moveDownItem.tag = MenuTag.fileMoveDown
        menu.addItem(moveDownItem)

        if !systemItems.isEmpty {
            menu.addItem(.separator())
            systemItems.forEach { menu.addItem($0) }
        }
    }

    private func makeOpenWithSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Open With")
        let files = Array(model.selectedFileURLs).sorted { $0.path < $1.path }
        guard let firstFile = files.first else {
            let item = NSMenuItem(title: "No Compatible Apps", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            return submenu
        }

        let apps = NSWorkspace.shared.urlsForApplications(toOpen: firstFile)
            .map { appURL -> (name: String, url: URL) in
                let fallbackName = appURL.deletingPathExtension().lastPathComponent
                let appName = FileManager.default.displayName(atPath: appURL.path)
                return (appName.isEmpty ? fallbackName : appName, appURL)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if apps.isEmpty {
            let item = NSMenuItem(title: "No Compatible Apps", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            return submenu
        }

        for app in apps {
            let item = NSMenuItem(title: app.name, action: #selector(openSelectionWithSpecificAppAction(_:)), keyEquivalent: "")
            item.representedObject = app.url
            item.target = self
            let appIcon = NSWorkspace.shared.icon(forFile: app.url.path)
            appIcon.size = NSSize(width: 16, height: 16)
            item.image = appIcon
            submenu.addItem(item)
        }
        return submenu
    }

    private func makeImportSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Import")
        submenu.autoenablesItems = false

        let items: [(title: String, action: Selector, symbol: String, tag: Int)] = [
            ("CSV…", #selector(importCSVAction(_:)), "tablecells", MenuTag.fileImportCSV),
            ("GPX…", #selector(importGPXAction(_:)), "location", MenuTag.fileImportGPX),
            ("Reference Folder…", #selector(importReferenceFolderAction(_:)), "folder.badge.questionmark", MenuTag.fileImportReferenceFolder),
            ("Reference Image…", #selector(importReferenceImageAction(_:)), "photo.badge.plus", MenuTag.fileImportReferenceImage),
            ("EOS-1V…", #selector(importEOS1VAction(_:)), "camera", MenuTag.fileImportEOS1V),
        ]

        for descriptor in items {
            let item = NSMenuItem(title: descriptor.title, action: descriptor.action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: descriptor.symbol, accessibilityDescription: nil)
            item.tag = descriptor.tag
            item.isEnabled = !model.browserItems.isEmpty
            submenu.addItem(item)
        }
        return submenu
    }

    private func makeExportSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Export")
        submenu.autoenablesItems = false

        let item = NSMenuItem(title: "Create CSV…", action: #selector(exportExifToolCSVAction(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "tablecells.badge.ellipsis", accessibilityDescription: nil)
        item.tag = MenuTag.fileExportExifToolCSV
        item.isEnabled = !model.browserItems.isEmpty
        submenu.addItem(item)

        let sendToPhotosItem = NSMenuItem(title: "Send to Photos…", action: #selector(sendToPhotosAction(_:)), keyEquivalent: "")
        sendToPhotosItem.target = self
        if let photosAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            let appIcon = NSWorkspace.shared.icon(forFile: photosAppURL.path)
            appIcon.size = NSSize(width: 16, height: 16)
            sendToPhotosItem.image = appIcon
        } else {
            sendToPhotosItem.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)
        }
        sendToPhotosItem.tag = MenuTag.fileExportSendToPhotos
        sendToPhotosItem.isEnabled = !model.browserItems.isEmpty
        submenu.addItem(sendToPhotosItem)

        let sendToLightroomItem = NSMenuItem(title: "Send to Lightroom…", action: #selector(sendToLightroomAction(_:)), keyEquivalent: "")
        sendToLightroomItem.target = self
        let lightroomTargets = model.selectedFileURLs.isEmpty ? model.browserItems.map(\.url) : Array(model.selectedFileURLs)
        if let lightroomAppURL = model.lightroomApplicationURL(for: lightroomTargets) {
            let appIcon = NSWorkspace.shared.icon(forFile: lightroomAppURL.path)
            appIcon.size = NSSize(width: 16, height: 16)
            sendToLightroomItem.image = appIcon
        } else {
            sendToLightroomItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        }
        sendToLightroomItem.tag = MenuTag.fileExportSendToLightroom
        sendToLightroomItem.isEnabled = model.fileActionState(for: .sendToLightroom, targetURLs: lightroomTargets).isEnabled
        submenu.addItem(sendToLightroomItem)

        let sendToLightroomClassicItem = NSMenuItem(title: "Send to Lightroom Classic…", action: #selector(sendToLightroomClassicAction(_:)), keyEquivalent: "")
        sendToLightroomClassicItem.target = self
        if let lightroomAppURL = model.lightroomClassicApplicationURL(for: lightroomTargets) {
            let appIcon = NSWorkspace.shared.icon(forFile: lightroomAppURL.path)
            appIcon.size = NSSize(width: 16, height: 16)
            sendToLightroomClassicItem.image = appIcon
        } else {
            sendToLightroomClassicItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        }
        sendToLightroomClassicItem.tag = MenuTag.fileExportSendToLightroomClassic
        sendToLightroomClassicItem.isEnabled = model.fileActionState(for: .sendToLightroomClassic, targetURLs: lightroomTargets).isEnabled
        submenu.addItem(sendToLightroomClassicItem)
        return submenu
    }

    private func rebuildEditMenu(_ menu: NSMenu) {
        ensureEditMenuBaseline(in: menu)

        menu.items.first(where: { $0.action == #selector(undoMetadataMenuAction(_:)) })?.image =
            NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        menu.items.first(where: { $0.action == #selector(redoMetadataMenuAction(_:)) })?.image =
            NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: nil)

        for item in menu.items where item.tag == MenuTag.editRotate || item.tag == MenuTag.editFlip {
            menu.removeItem(item)
        }
        // Keep separator structure stable across repeated menuWillOpen rebuilds.
        for index in stride(from: menu.items.count - 1, through: 1, by: -1) {
            if menu.items[index].isSeparatorItem && menu.items[index - 1].isSeparatorItem {
                menu.removeItem(at: index)
            }
        }
        while let first = menu.items.first, first.isSeparatorItem {
            menu.removeItem(at: 0)
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(at: menu.items.count - 1)
        }

        let rotateItem = NSMenuItem(title: "Rotate", action: #selector(rotateSelectionMenuAction(_:)), keyEquivalent: "r")
        rotateItem.keyEquivalentModifierMask = .command
        rotateItem.image = NSImage(systemSymbolName: "rotate.left", accessibilityDescription: nil)
        rotateItem.tag = MenuTag.editRotate

        let flipItem = NSMenuItem(title: "Flip", action: #selector(flipSelectionMenuAction(_:)), keyEquivalent: "F")
        flipItem.keyEquivalentModifierMask = [.command, .shift]
        flipItem.image = NSImage(systemSymbolName: "flip.horizontal", accessibilityDescription: nil)
        flipItem.tag = MenuTag.editFlip

        var insertIndex = menu.items.firstIndex(where: { $0.title == "Select All" }).map { $0 + 1 } ?? menu.items.count
        if insertIndex == 0 || !menu.items[insertIndex - 1].isSeparatorItem {
            menu.insertItem(.separator(), at: insertIndex)
            insertIndex += 1
        }
        menu.insertItem(rotateItem, at: insertIndex)
        insertIndex += 1
        menu.insertItem(flipItem, at: insertIndex)

        // Ensure no accidental trailing divider remains at the bottom.
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(at: menu.items.count - 1)
        }
    }

    private func ensureEditMenuBaseline(in menu: NSMenu) {
        let hasUndo = menu.items.contains { $0.action == #selector(undoMetadataMenuAction(_:)) }
        let hasRedo = menu.items.contains { $0.action == #selector(redoMetadataMenuAction(_:)) }
        let hasCut = menu.items.contains { $0.action == #selector(NSText.cut(_:)) }
        let hasCopy = menu.items.contains { $0.action == #selector(NSText.copy(_:)) }
        let hasPaste = menu.items.contains { $0.action == #selector(NSText.paste(_:)) }
        let hasSelectAll = menu.items.contains { $0.action == #selector(NSText.selectAll(_:)) }
        guard !(hasUndo && hasRedo && hasCut && hasCopy && hasPaste && hasSelectAll) else { return }

        menu.removeAllItems()

        let undoItem = NSMenuItem(title: "Undo", action: #selector(undoMetadataMenuAction(_:)), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = .command
        undoItem.target = self
        menu.addItem(undoItem)

        let redoItem = NSMenuItem(title: "Redo", action: #selector(redoMetadataMenuAction(_:)), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = .command
        redoItem.target = self
        menu.addItem(redoItem)

        menu.addItem(.separator())

        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cutItem.keyEquivalentModifierMask = .command
        menu.addItem(cutItem)

        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = .command
        menu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = .command
        menu.addItem(selectAllItem)
    }

    private func rebuildImageMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let applySelectionItem = NSMenuItem(title: "Apply Changes to Selection", action: #selector(applySelectionAction(_:)), keyEquivalent: "s")
        applySelectionItem.keyEquivalentModifierMask = .command
        applySelectionItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        applySelectionItem.tag = MenuTag.imageApplySelection
        applySelectionItem.target = self
        menu.addItem(applySelectionItem)

        let refreshSelectionItem = NSMenuItem(title: "Refresh Metadata for Selection", action: #selector(refreshSelectionMetadataAction(_:)), keyEquivalent: "R")
        refreshSelectionItem.keyEquivalentModifierMask = [.command, .shift]
        refreshSelectionItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshSelectionItem.tag = MenuTag.imageRefreshSelection
        refreshSelectionItem.target = self
        menu.addItem(refreshSelectionItem)

        let clearSelectionItem = NSMenuItem(title: "Clear Changes", action: #selector(clearChangesAction(_:)), keyEquivalent: "k")
        clearSelectionItem.keyEquivalentModifierMask = .command
        clearSelectionItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        clearSelectionItem.tag = MenuTag.imageClearSelection
        clearSelectionItem.target = self
        menu.addItem(clearSelectionItem)

        let restoreSelectionItem = NSMenuItem(title: "Restore from Backup", action: #selector(restoreFromBackupAction(_:)), keyEquivalent: "b")
        restoreSelectionItem.keyEquivalentModifierMask = .command
        restoreSelectionItem.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle", accessibilityDescription: nil)
        restoreSelectionItem.tag = MenuTag.imageRestoreSelection
        restoreSelectionItem.target = self
        menu.addItem(restoreSelectionItem)

        menu.addItem(.separator())

        let applyAllItem = NSMenuItem(title: "Apply Changes to All Images", action: #selector(applyFolderAction(_:)), keyEquivalent: "S")
        applyAllItem.keyEquivalentModifierMask = [.command, .option, .shift]
        applyAllItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        applyAllItem.tag = MenuTag.imageApplyAll
        applyAllItem.target = self
        menu.addItem(applyAllItem)

        let refreshAllItem = NSMenuItem(title: "Refresh Metadata for All Images", action: #selector(refreshAllMetadataAction(_:)), keyEquivalent: "r")
        refreshAllItem.keyEquivalentModifierMask = [.command, .option]
        refreshAllItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshAllItem.tag = MenuTag.imageRefreshAll
        refreshAllItem.target = self
        menu.addItem(refreshAllItem)

        let clearAllItem = NSMenuItem(title: "Clear Changes from All Images", action: #selector(clearAllChangesAction(_:)), keyEquivalent: "k")
        clearAllItem.keyEquivalentModifierMask = [.command, .option]
        clearAllItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        clearAllItem.tag = MenuTag.imageClearAll
        clearAllItem.target = self
        menu.addItem(clearAllItem)

        let restoreAllItem = NSMenuItem(title: "Restore Metadata from Backup for All Images", action: #selector(restoreAllFromBackupAction(_:)), keyEquivalent: "b")
        restoreAllItem.keyEquivalentModifierMask = [.command, .option]
        restoreAllItem.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle", accessibilityDescription: nil)
        restoreAllItem.tag = MenuTag.imageRestoreAll
        restoreAllItem.target = self
        menu.addItem(restoreAllItem)

        menu.addItem(.separator())

        let presetsItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        presetsItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        presetsItem.submenu = makePresetsSubmenu()
        menu.addItem(presetsItem)

        menu.addItem(.separator())

        let batchRenameSelectionItem = NSMenuItem(
            title: "Batch Rename Selection\u{2026}",
            action: #selector(batchRenameSelectionAction(_:)),
            keyEquivalent: ""
        )
        batchRenameSelectionItem.image = NSImage(systemSymbolName: "pencil.and.list.clipboard", accessibilityDescription: nil)
        batchRenameSelectionItem.tag = MenuTag.imageBatchRenameSelection
        batchRenameSelectionItem.target = self
        menu.addItem(batchRenameSelectionItem)

        let batchRenameFolderItem = NSMenuItem(
            title: "Batch Rename Folder\u{2026}",
            action: #selector(batchRenameFolderAction(_:)),
            keyEquivalent: ""
        )
        batchRenameFolderItem.image = NSImage(systemSymbolName: "pencil.and.list.clipboard", accessibilityDescription: nil)
        batchRenameFolderItem.tag = MenuTag.imageBatchRenameFolder
        batchRenameFolderItem.target = self
        menu.addItem(batchRenameFolderItem)
    }

    private func makePresetsSubmenu() -> NSMenu {
        let menu = NSMenu(title: "Presets")
        let applySubmenuItem = NSMenuItem(title: "Apply Preset", action: nil, keyEquivalent: "")
        let applySubmenu = NSMenu(title: "Apply Preset")
        if model.presets.isEmpty {
            let noPresets = NSMenuItem(title: "No Presets", action: nil, keyEquivalent: "")
            noPresets.isEnabled = false
            applySubmenu.addItem(noPresets)
        } else {
            for preset in model.presets {
                let item = NSMenuItem(title: preset.name, action: #selector(applyPresetFromMenuAction(_:)), keyEquivalent: "")
                item.representedObject = preset.id.uuidString
                item.tag = MenuTag.imageApplyPreset
                item.target = self
                applySubmenu.addItem(item)
            }
        }
        applySubmenuItem.submenu = applySubmenu
        menu.addItem(applySubmenuItem)
        menu.addItem(.separator())

        let saveItem = NSMenuItem(title: "Save as Preset…", action: #selector(saveCurrentAsPresetAction(_:)), keyEquivalent: "")
        saveItem.tag = MenuTag.imageSavePreset
        saveItem.image = NSImage(systemSymbolName: "square.and.arrow.down.badge.checkmark", accessibilityDescription: nil)
        saveItem.target = self
        menu.addItem(saveItem)

        let manageItem = NSMenuItem(title: "Manage Presets…", action: #selector(managePresetsAction(_:)), keyEquivalent: "")
        manageItem.tag = MenuTag.imageManagePresets
        manageItem.image = NSImage(systemSymbolName: "slider.horizontal.below.square.filled.and.square", accessibilityDescription: nil)
        manageItem.target = self
        menu.addItem(manageItem)

        return menu
    }

    private func rebuildHelpMenu(_ menu: NSMenu) {
        let existing = menu.items.first { $0.tag == MenuTag.helpExifToolDocs }
        if existing != nil { return }
        menu.addItem(.separator())
        let whatsNewItem = NSMenuItem(title: "What's New in \(AppBrand.displayName)…", action: #selector(openWhatsNewAction(_:)), keyEquivalent: "")
        whatsNewItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        whatsNewItem.tag = MenuTag.helpWhatsNew
        menu.addItem(whatsNewItem)
        let docsItem = NSMenuItem(title: "ExifTool Documentation", action: #selector(openExifToolDocsAction(_:)), keyEquivalent: "")
        docsItem.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        docsItem.tag = MenuTag.helpExifToolDocs
        menu.addItem(docsItem)
    }

    @objc private func openWhatsNewAction(_: Any?) {
        (NSApp.delegate as? AppDelegate)?.showWelcomeScreen()
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        if menu === fileMenuForInjection {
            rebuildFileMenu(menu)
        } else if menu === editMenuForInjection {
            rebuildEditMenu(menu)
        } else if menu === viewMenuForSortInjection {
            rebuildViewMenu(menu)
        } else if menu === imageMenuForInjection {
            rebuildImageMenu(menu)
        } else if menu === helpMenuForInjection {
            rebuildHelpMenu(menu)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let selection = Array(model.selectedFileURLs)
        if menuItem.action == #selector(undoMetadataMenuAction(_:)) {
            return model.canUndoMetadataEdits
        } else if menuItem.action == #selector(redoMetadataMenuAction(_:)) {
            return model.canRedoMetadataEdits
        } else if menuItem.action == #selector(openInDefaultAppMenuAction(_:)) {
            let state = model.fileActionState(for: .openInDefaultApp, targetURLs: selection)
            menuItem.title = state.title
            return state.isEnabled
        } else if menuItem.action == #selector(openSelectionWithSpecificAppAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(revealSelectionInFinderMenuAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(quickLookSelectionMenuAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(importCSVAction(_:))
            || menuItem.action == #selector(importGPXAction(_:))
            || menuItem.action == #selector(importReferenceFolderAction(_:))
            || menuItem.action == #selector(importReferenceImageAction(_:))
            || menuItem.action == #selector(importEOS1VAction(_:)) {
            return !model.browserItems.isEmpty
        } else if menuItem.action == #selector(exportExifToolCSVAction(_:)) {
            return !model.browserItems.isEmpty
        } else if menuItem.action == #selector(sendToPhotosAction(_:)) {
            let targetURLs = model.selectedFileURLs.isEmpty ? model.browserItems.map(\.url) : Array(model.selectedFileURLs)
            let state = model.fileActionState(for: .sendToPhotos, targetURLs: targetURLs)
            menuItem.title = state.title
            return state.isEnabled
        } else if menuItem.action == #selector(sendToLightroomAction(_:)) {
            let targetURLs = model.selectedFileURLs.isEmpty ? model.browserItems.map(\.url) : Array(model.selectedFileURLs)
            let state = model.fileActionState(for: .sendToLightroom, targetURLs: targetURLs)
            menuItem.title = state.title
            return state.isEnabled
        } else if menuItem.action == #selector(sendToLightroomClassicAction(_:)) {
            let targetURLs = model.selectedFileURLs.isEmpty ? model.browserItems.map(\.url) : Array(model.selectedFileURLs)
            let state = model.fileActionState(for: .sendToLightroomClassic, targetURLs: targetURLs)
            menuItem.title = state.title
            return state.isEnabled
        } else if menuItem.action == #selector(pinFolderToSidebarAction(_:)) {
            return model.canPinSelectedSidebarLocation
        } else if menuItem.action == #selector(unpinFolderFromSidebarAction(_:)) {
            return model.canUnpinSelectedSidebarLocation
        } else if menuItem.action == #selector(moveFolderUpInSidebarAction(_:)) {
            return model.canMoveSelectedFavoriteUp
        } else if menuItem.action == #selector(moveFolderDownInSidebarAction(_:)) {
            return model.canMoveSelectedFavoriteDown
        } else if menuItem.action == #selector(rotateSelectionMenuAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(flipSelectionMenuAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(toggleInspectorAction(_:)) {
            menuItem.title = isInspectorCollapsed ? "Show Inspector" : "Hide Inspector"
        } else if menuItem.action == #selector(togglePathBarAction(_:)) {
            menuItem.title = browserController.isPathBarVisible ? "Hide Path Bar" : "Show Path Bar"
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
        } else if menuItem.action == #selector(refreshSelectionMetadataAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(refreshAllMetadataAction(_:)) {
            return !model.browserItems.isEmpty
        } else if menuItem.action == #selector(clearAllChangesAction(_:)) {
            return model.canApplyMetadataChanges
        } else if menuItem.action == #selector(restoreAllFromBackupAction(_:)) {
            return !model.browserItems.isEmpty
        } else if menuItem.action == #selector(saveCurrentAsPresetAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(applyPresetFromMenuAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(batchRenameSelectionAction(_:)) {
            return model.fileActionState(for: .batchRenameSelection, targetURLs: Array(model.selectedFileURLs)).isEnabled
        } else if menuItem.action == #selector(batchRenameFolderAction(_:)) {
            return model.fileActionState(for: .batchRenameFolder, targetURLs: model.browserItems.map(\.url)).isEnabled
        } else if menuItem.action == #selector(zoomInAction(_:)) {
            return model.browserViewMode == .gallery && model.canIncreaseGalleryZoom
        } else if menuItem.action == #selector(zoomOutAction(_:)) {
            return model.browserViewMode == .gallery && model.canDecreaseGalleryZoom
        } else if menuItem.action == #selector(sortByNameAction(_:)) {
            menuItem.state = model.browserSort == .name ? .on : .off
        } else if menuItem.action == #selector(sortByCreatedAction(_:)) {
            menuItem.state = model.browserSort == .created ? .on : .off
        } else if menuItem.action == #selector(sortByModifiedAction(_:)) {
            menuItem.state = model.browserSort == .modified ? .on : .off
        } else if menuItem.action == #selector(sortBySizeAction(_:)) {
            menuItem.state = model.browserSort == .size ? .on : .off
        } else if menuItem.action == #selector(sortByKindAction(_:)) {
            menuItem.state = model.browserSort == .kind ? .on : .off
        }
        return true
    }

    private func focusBrowserPane() {
        guard let window = view.window else { return }
        NotificationCenter.default.post(name: .browserDidRequestFocus, object: nil)
        window.makeFirstResponder(browserController.view)
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
    func importCSVAction(_: Any?) { model.requestImport(sourceKind: .csv) }

    @objc
    func importGPXAction(_: Any?) { model.requestImport(sourceKind: .gpx) }

    @objc
    func importReferenceFolderAction(_: Any?) { model.requestImport(sourceKind: .referenceFolder) }

    @objc
    func importReferenceImageAction(_: Any?) { model.requestImport(sourceKind: .referenceImage) }

    @objc
    func importEOS1VAction(_: Any?) { model.requestImport(sourceKind: .eos1v) }

    @objc
    func exportExifToolCSVAction(_: Any?) {
        pickExportScope(actionTitle: "Export ExifTool CSV") { [weak self] scope, _ in
            guard let self else { return }
            if self.model.hasPendingEdits(inImportScope: scope) {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Prepared changes are not included in ExifTool CSV export."
                alert.informativeText = "Export reads current file metadata from disk. Apply your changes first if you want them included."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Export Anyway")
                var response: NSApplication.ModalResponse = .abort
                alert.runSheetOrModal(for: nil) { response = $0 }
                guard response == .alertSecondButtonReturn else { return }
            }

            let panel = NSSavePanel()
            if let csvType = UTType(filenameExtension: "csv") {
                panel.allowedContentTypes = [csvType]
            }
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "exiftool-export.csv"

            let export: (URL) -> Void = { [weak self] destinationURL in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await self.model.exportExifToolCSV(scope: scope, destinationURL: destinationURL)
                    } catch {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "Export Failed"
                        alert.informativeText = error.localizedDescription
                        alert.addButton(withTitle: "OK")
                        alert.runSheetOrModal(for: self.view.window) { _ in }
                    }
                }
            }

            if let window = self.view.window {
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let destinationURL = panel.url else { return }
                    export(destinationURL)
                }
            } else {
                guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
                export(destinationURL)
            }
        }
    }

    @objc
    func sendToPhotosAction(_: Any?) {
        pickExportScope(actionTitle: "Send to Photos") { [weak self] _, targetURLs in
            self?.model.performFileAction(.sendToPhotos, targetURLs: targetURLs)
        }
    }

    @objc
    func sendToLightroomAction(_: Any?) {
        pickExportScope(actionTitle: "Send to Lightroom") { [weak self] _, targetURLs in
            self?.model.performFileAction(.sendToLightroom, targetURLs: targetURLs)
        }
    }

    @objc
    func sendToLightroomClassicAction(_: Any?) {
        pickExportScope(actionTitle: "Send to Lightroom Classic") { [weak self] _, targetURLs in
            self?.model.performFileAction(.sendToLightroomClassic, targetURLs: targetURLs)
        }
    }

    /// Shows a scope-picker sheet when there is a selection, then calls `completion` with the
    /// resolved scope and target URLs. Falls straight through with folder scope when there is no
    /// selection. `completion` is not called if the user cancels.
    private func pickExportScope(actionTitle: String, completion: @escaping (ImportScope, [URL]) -> Void) {
        let selectionURLs = Array(model.selectedFileURLs)
        let folderURLs = model.browserItems.map(\.url)
        let hasPendingEdits = model.hasPendingEdits(inImportScope: .folder)
        let pendingEditsNote = hasPendingEdits
            ? "\n\nYou have unapplied changes that won't be included. Apply them first if you want them exported."
            : ""

        guard !selectionURLs.isEmpty else {
            // No selection — fall straight through, but warn about pending edits if needed.
            if hasPendingEdits {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = actionTitle
                alert.informativeText = "You have unapplied changes that won't be included. Apply them first if you want them exported."
                alert.addButton(withTitle: "Export Anyway")
                alert.addButton(withTitle: "Cancel")
                alert.runSheetOrModal(for: view.window) { response in
                    guard response == .alertFirstButtonReturn else { return }
                    completion(.folder, folderURLs)
                }
            } else {
                completion(.folder, folderURLs)
            }
            return
        }

        let n = selectionURLs.count
        let alert = NSAlert()
        alert.messageText = actionTitle
        alert.informativeText = "Export the current selection or all images in the folder?\(pendingEditsNote)"
        alert.addButton(withTitle: "Selection (\(n) \(n == 1 ? "file" : "files"))")
        alert.addButton(withTitle: "Folder")
        alert.addButton(withTitle: "Cancel")

        alert.runSheetOrModal(for: view.window) { response in
            switch response {
            case .alertFirstButtonReturn:
                completion(.selection, selectionURLs)
            case .alertSecondButtonReturn:
                completion(.folder, folderURLs)
            default: break
            }
        }
    }

    @objc
    func openInDefaultAppMenuAction(_: Any?) {
        model.performFileAction(.openInDefaultApp, targetURLs: Array(model.selectedFileURLs))
    }

    @objc
    func openSelectionWithSpecificAppAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let appURL = item.representedObject as? URL
        else { return }
        let files = Array(model.selectedFileURLs).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            files,
            withApplicationAt: appURL,
            configuration: config,
            completionHandler: nil
        )
    }

    @objc
    func revealSelectionInFinderMenuAction(_: Any?) {
        model.revealSelectionInFinder()
    }

    @objc
    func quickLookSelectionMenuAction(_: Any?) {
        model.quickLookSelection()
    }

    @objc
    func undoMetadataMenuAction(_: Any?) {
        _ = model.undoLastMetadataEdit()
    }

    @objc
    func redoMetadataMenuAction(_: Any?) {
        _ = model.redoLastMetadataEdit()
    }

    @objc
    func pinFolderToSidebarAction(_: Any?) {
        model.pinSelectedSidebarLocationToFavorites()
    }

    @objc
    func unpinFolderFromSidebarAction(_: Any?) {
        model.unpinSelectedSidebarFavorite()
    }

    @objc
    func moveFolderUpInSidebarAction(_: Any?) {
        model.moveSelectedFavoriteUp()
    }

    @objc
    func moveFolderDownInSidebarAction(_: Any?) {
        model.moveSelectedFavoriteDown()
    }

    @objc
    func rotateSelectionMenuAction(_: Any?) {
        let files = Array(model.selectedFileURLs).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }
        for fileURL in files {
            model.rotateLeft(fileURL: fileURL)
        }
    }

    @objc
    func flipSelectionMenuAction(_: Any?) {
        let files = Array(model.selectedFileURLs).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }
        for fileURL in files {
            model.flipHorizontal(fileURL: fileURL)
        }
    }

    @objc
    func openExifToolDocsAction(_: Any?) {
        guard let url = URL(string: "https://exiftool.org/") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc
    func refreshAction(_: Any?) {
        model.refresh()
    }

    @objc
    func refreshSelectionMetadataAction(_: Any?) {
        model.performFileAction(.refreshMetadata, targetURLs: Array(model.selectedFileURLs))
    }

    @objc
    func refreshAllMetadataAction(_: Any?) {
        let allURLs = model.browserItems.map(\.url)
        model.refreshMetadata(for: allURLs)
    }

    @objc
    func focusInspectorEntryAction(_: Any?) {
        guard !model.selectedFileURLs.isEmpty else { return }
        guard let window = view.window else { return }
        _ = window.makeFirstResponder(inspectorController.view)
    }

    @objc
    func applyChangesAction(_: Any?) {
        let count = model.pendingEditedFileCount
        guard model.confirmBeforeApply || count > 1 else {
            model.applyChanges()
            return
        }
        let images = count == 1 ? "1 image" : "\(count) images"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Apply changes to \(images)?"
        alert.informativeText = "Prepared changes will be written to disk. This can’t be undone."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.runSheetOrModal(for: view.window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.model.applyChanges()
        }
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
    func clearAllChangesAction(_: Any?) {
        let allURLs = model.browserItems.map(\.url)
        model.clearPendingEdits(for: allURLs)
    }

    @objc
    func restoreFromBackupAction(_: Any?) {
        model.performFileAction(.restoreFromLastBackup, targetURLs: Array(model.selectedFileURLs))
    }

    @objc
    func restoreAllFromBackupAction(_: Any?) {
        let allURLs = model.browserItems.map(\.url)
        model.restoreLastOperation(for: allURLs)
    }

    @objc
    func zoomOutAction(_: Any?) {
        guard model.browserViewMode == .gallery else { return }
        model.decreaseGalleryZoom()
        refreshToolbarState()
    }

    @objc
    func zoomInAction(_: Any?) {
        guard model.browserViewMode == .gallery else { return }
        model.increaseGalleryZoom()
        refreshToolbarState()
    }

    @objc
    func switchToGalleryAction(_: Any?) {
        model.browserViewMode = .gallery
        refreshToolbarState()
        NotificationCenter.default.post(name: .browserDidSwitchViewMode, object: nil)
    }

    @objc
    func switchToListAction(_: Any?) {
        model.browserViewMode = .list
        refreshToolbarState()
        NotificationCenter.default.post(name: .browserDidSwitchViewMode, object: nil)
    }

    @objc
    func sortByNameAction(_: Any?) {
        model.browserSort = .name
        refreshToolbarState()
    }

    @objc
    func sortByCreatedAction(_: Any?) {
        model.browserSort = .created
        refreshToolbarState()
    }

    @objc
    func sortByModifiedAction(_: Any?) {
        model.browserSort = .modified
        refreshToolbarState()
    }

    @objc
    func sortBySizeAction(_: Any?) {
        model.browserSort = .size
        refreshToolbarState()
    }

    @objc
    func sortByKindAction(_: Any?) {
        model.browserSort = .kind
        refreshToolbarState()
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

    @objc func batchRenameSelectionAction(_: Any?) {
        model.beginBatchRename(scope: .selection)
    }

    @objc
    func batchRenameFolderAction(_: Any?) {
        model.beginBatchRename(scope: .folder)
    }

    @objc
    private func viewModeChanged(_ sender: NSToolbarItemGroup) {
        model.browserViewMode = sender.selectedIndex == 1 ? .list : .gallery
        refreshToolbarState()
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
        let images = fileCount == 1 ? "1 image" : "\(fileCount) images"
        alert.informativeText = "This will update metadata for \(images). Preset fields will overwrite existing values."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        alert.runSheetOrModal(for: view.window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.model.applyPreset(presetID: preset.id)
        }
    }

    @MainActor
    private final class MainToolbarController: NSObject, ToolbarShellContent {
        private weak var controller: NativeThreePaneSplitViewController?

        private var viewModeGroupItem: NSToolbarItemGroup?
        private var zoomOutItem: NSToolbarItem?
        private var zoomInItem: NSToolbarItem?
        private var applyChangesItem: NSToolbarItem?
        private var inspectorToggleItem: NSToolbarItem?

        private var sortItem: NSMenuToolbarItem?
        private var importItem: NSMenuToolbarItem?
        private var exportItem: NSMenuToolbarItem?
        private var presetsItem: NSMenuToolbarItem?
        private var sortMenu: NSMenu?
        private var importMenu: NSMenu?
        private var exportMenu: NSMenu?
        private var presetsMenu: NSMenu?

        init(controller: NativeThreePaneSplitViewController) {
            self.controller = controller
        }

        func resetCachedToolbarReferences() {
            viewModeGroupItem = nil
            zoomOutItem = nil
            zoomInItem = nil
            applyChangesItem = nil
            inspectorToggleItem = nil
            sortItem = nil
            importItem = nil
            exportItem = nil
            presetsItem = nil
            sortMenu = nil
            importMenu = nil
            exportMenu = nil
            presetsMenu = nil
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
                .importTools,
                .exportTools,
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
                .importTools,
                .exportTools,
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
                    splitView: controller.innerSplitView,
                    dividerIndex: 0
                )
            case .viewMode:
                let galleryImage = NSImage(systemSymbolName: "square.grid.3x2", accessibilityDescription: "Gallery")
                    ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Gallery")
                    ?? NSImage()
                let listImage = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List") ?? NSImage()
                let item = NSToolbarItemGroup(
                    itemIdentifier: itemIdentifier,
                    images: [galleryImage, listImage],
                    selectionMode: .selectOne,
                    labels: ["Gallery", "List"],
                    target: controller,
                    action: #selector(NativeThreePaneSplitViewController.viewModeChanged(_:))
                )
                item.label = "View"
                item.paletteLabel = "View"
                item.toolTip = "Switch browser view"
                viewModeGroupItem = item
                return item
            case .zoomOut:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Zoom Out"
                item.paletteLabel = "Zoom Out"
                item.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Zoom out")
                item.isBordered = true
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
                item.isBordered = true
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.zoomInAction(_:))
                item.toolTip = "Zoom in"
                zoomInItem = item
                return item
            case .sort:
                let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Sort"
                item.paletteLabel = "Sort"
                item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
                item.isBordered = true
                item.toolTip = "Sort images"
                sortItem = item
                updateSortMenu(with: controller.model)
                return item
            case .importTools:
                let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Import"
                item.paletteLabel = "Import"
                item.image = NSImage(systemSymbolName: "checklist.checked", accessibilityDescription: "Import")
                item.isBordered = true
                item.toolTip = "Import metadata"
                importItem = item
                updateImportMenu(with: controller.model)
                return item
            case .exportTools:
                let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Export"
                item.paletteLabel = "Export"
                item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
                item.isBordered = true
                item.toolTip = "Export and handoff"
                exportItem = item
                updateExportMenu(with: controller.model)
                return item
            case .presetTools:
                let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Presets"
                item.paletteLabel = "Presets"
                item.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Presets")
                item.isBordered = true
                item.toolTip = "Presets"
                presetsItem = item
                updatePresetsMenu(with: controller.model)
                return item
            case .openFolder:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Open Folder"
                item.paletteLabel = "Open Folder"
                item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Open Folder")
                item.isBordered = true
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.openFolderAction(_:))
                item.toolTip = "Open a folder"
                return item
            case .applyChanges:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Apply Changes"
                item.paletteLabel = "Apply Changes"
                item.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Save and apply")
                item.isBordered = true
                item.target = controller
                item.action = #selector(NativeThreePaneSplitViewController.applyChangesAction(_:))
                item.toolTip = "Apply metadata changes"
                if #available(macOS 26.0, *) {
                    item.style = controller.model.canApplyMetadataChanges ? .prominent : .plain
                }
                applyChangesItem = item
                return item
            case .toggleInspector:
                let collapsed = controller.isInspectorCollapsed
                let label = collapsed ? "Show Inspector" : "Hide Inspector"
                let item = ToolbarItemFactory.makeInspectorToggleItem(
                    identifier: itemIdentifier,
                    label: label,
                    action: #selector(NativeThreePaneSplitViewController.toggleInspectorAction(_:)),
                    toolTip: label
                )
                inspectorToggleItem = item
                return item
            default:
                return nil
            }
        }

        func syncToolbarState() {
            guard let controller else { return }
            let model = controller.model
            updateViewMode(with: model)
            updateSortMenu(with: model)
            updateImportMenu(with: model)
            updateExportMenu(with: model)
            updatePresetsMenu(with: model)
            updateApplyStyle(with: model)
            updateInspectorLabels(with: model)
        }

        private func updateViewMode(with model: AppModel) {
            viewModeGroupItem?.selectedIndex = model.browserViewMode == .gallery ? 0 : 1
        }

        private func updateSortMenu(with model: AppModel) {
            let menu = makeSortMenu(model: model)
            sortMenu = menu
            sortItem?.menu = menu
            applySortState(model.browserSort, to: menu)
        }

        private func updatePresetsMenu(with model: AppModel) {
            let menu = makePresetsMenu(model: model)
            presetsMenu = menu
            presetsItem?.menu = menu
        }

        private func updateImportMenu(with model: AppModel) {
            let menu = makeImportMenu(model: model)
            importMenu = menu
            importItem?.menu = menu
        }

        private func updateExportMenu(with model: AppModel) {
            let menu = makeExportMenu(model: model)
            exportMenu = menu
            exportItem?.menu = menu
        }

        private func updateApplyStyle(with model: AppModel) {
            if #available(macOS 26.0, *) {
                applyChangesItem?.style = model.canApplyMetadataChanges ? .prominent : .plain
            }
        }

        private func updateInspectorLabels(with model: AppModel) {
            let label = model.isInspectorCollapsed ? "Show Inspector" : "Hide Inspector"
            inspectorToggleItem?.label = label
            inspectorToggleItem?.toolTip = label
        }

        func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
            guard let controller else { return false }
            let model = controller.model

            switch item.itemIdentifier {
            case .zoomOut:
                return model.browserViewMode == .gallery && model.canDecreaseGalleryZoom
            case .zoomIn:
                return model.browserViewMode == .gallery && model.canIncreaseGalleryZoom
            case .applyChanges:
                updateApplyStyle(with: model)
                return model.canApplyMetadataChanges
            case .toggleInspector:
                updateInspectorLabels(with: model)
                return true
            case .sort:
                updateSortMenu(with: model)
                return !model.browserItems.isEmpty
            case .importTools:
                updateImportMenu(with: model)
                return !model.browserItems.isEmpty
            case .exportTools:
                updateExportMenu(with: model)
                return !model.browserItems.isEmpty
            case .presetTools:
                updatePresetsMenu(with: model)
                return true
            case .viewMode, .openFolder, .toggleSidebar, .sidebarTrackingSeparator, .inspectorTrackingSeparator:
                return true
            default:
                return true
            }
        }

        private func makeSortMenu(model: AppModel) -> NSMenu {
            guard let controller else { return NSMenu(title: "Sort") }
            let menu = NSMenu(title: "Sort")
            menu.autoenablesItems = false
            menu.addItem(withTitle: "Name", action: #selector(NativeThreePaneSplitViewController.sortByNameAction(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Date Created", action: #selector(NativeThreePaneSplitViewController.sortByCreatedAction(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Date Modified", action: #selector(NativeThreePaneSplitViewController.sortByModifiedAction(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Size", action: #selector(NativeThreePaneSplitViewController.sortBySizeAction(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Kind", action: #selector(NativeThreePaneSplitViewController.sortByKindAction(_:)), keyEquivalent: "")
            for item in menu.items {
                item.target = controller
            }
            applySortState(model.browserSort, to: menu)
            return menu
        }

        private func applySortState(_ sort: AppModel.BrowserSort, to menu: NSMenu) {
            for item in menu.items {
                item.state = .off
            }
            switch sort {
            case .name:
                menu.item(withTitle: "Name")?.state = .on
            case .created:
                menu.item(withTitle: "Date Created")?.state = .on
            case .modified:
                menu.item(withTitle: "Date Modified")?.state = .on
            case .size:
                menu.item(withTitle: "Size")?.state = .on
            case .kind:
                menu.item(withTitle: "Kind")?.state = .on
            }
        }

        private func makeImportMenu(model: AppModel) -> NSMenu {
            guard let controller else { return NSMenu(title: "Import") }
            let menu = NSMenu(title: "Import")
            menu.autoenablesItems = false
            let isEnabled = !model.browserItems.isEmpty

            func addItem(title: String, action: Selector, imageName: String) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = controller
                item.isEnabled = isEnabled
                item.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
                menu.addItem(item)
            }

            addItem(title: "CSV…", action: #selector(NativeThreePaneSplitViewController.importCSVAction(_:)), imageName: "tablecells")
            addItem(title: "GPX…", action: #selector(NativeThreePaneSplitViewController.importGPXAction(_:)), imageName: "location")
            addItem(title: "Reference Folder…", action: #selector(NativeThreePaneSplitViewController.importReferenceFolderAction(_:)), imageName: "folder.badge.questionmark")
            addItem(title: "Reference Image…", action: #selector(NativeThreePaneSplitViewController.importReferenceImageAction(_:)), imageName: "photo.badge.plus")
            addItem(title: "EOS-1V…", action: #selector(NativeThreePaneSplitViewController.importEOS1VAction(_:)), imageName: "camera")
            return menu
        }

        private func makeExportMenu(model: AppModel) -> NSMenu {
            guard let controller else { return NSMenu(title: "Export") }
            let menu = NSMenu(title: "Export")
            menu.autoenablesItems = false
            let hasBrowserItems = !model.browserItems.isEmpty
            let targetURLs = model.selectedFileURLs.isEmpty ? model.browserItems.map(\.url) : Array(model.selectedFileURLs)

            let createCSVItem = NSMenuItem(
                title: "Create CSV…",
                action: #selector(NativeThreePaneSplitViewController.exportExifToolCSVAction(_:)),
                keyEquivalent: ""
            )
            createCSVItem.target = controller
            createCSVItem.isEnabled = hasBrowserItems
            createCSVItem.image = NSImage(systemSymbolName: "tablecells.badge.ellipsis", accessibilityDescription: nil)
            menu.addItem(createCSVItem)

            let photosState = model.fileActionState(for: .sendToPhotos, targetURLs: targetURLs)
            let sendToPhotosItem = NSMenuItem(
                title: "Send to Photos…",
                action: #selector(NativeThreePaneSplitViewController.sendToPhotosAction(_:)),
                keyEquivalent: ""
            )
            sendToPhotosItem.target = controller
            sendToPhotosItem.isEnabled = photosState.isEnabled
            if let photosAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                let appIcon = NSWorkspace.shared.icon(forFile: photosAppURL.path)
                appIcon.size = NSSize(width: 16, height: 16)
                sendToPhotosItem.image = appIcon
            } else {
                sendToPhotosItem.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)
            }
            menu.addItem(sendToPhotosItem)

            let lightroomState = model.fileActionState(for: .sendToLightroom, targetURLs: targetURLs)
            let sendToLightroomItem = NSMenuItem(
                title: "Send to Lightroom…",
                action: #selector(NativeThreePaneSplitViewController.sendToLightroomAction(_:)),
                keyEquivalent: ""
            )
            sendToLightroomItem.target = controller
            sendToLightroomItem.isEnabled = lightroomState.isEnabled
            if let lightroomAppURL = model.lightroomApplicationURL(for: targetURLs) {
                let appIcon = NSWorkspace.shared.icon(forFile: lightroomAppURL.path)
                appIcon.size = NSSize(width: 16, height: 16)
                sendToLightroomItem.image = appIcon
            } else {
                sendToLightroomItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            }
            menu.addItem(sendToLightroomItem)

            let lightroomClassicState = model.fileActionState(for: .sendToLightroomClassic, targetURLs: targetURLs)
            let sendToLightroomClassicItem = NSMenuItem(
                title: "Send to Lightroom Classic…",
                action: #selector(NativeThreePaneSplitViewController.sendToLightroomClassicAction(_:)),
                keyEquivalent: ""
            )
            sendToLightroomClassicItem.target = controller
            sendToLightroomClassicItem.isEnabled = lightroomClassicState.isEnabled
            if let lightroomAppURL = model.lightroomClassicApplicationURL(for: targetURLs) {
                let appIcon = NSWorkspace.shared.icon(forFile: lightroomAppURL.path)
                appIcon.size = NSSize(width: 16, height: 16)
                sendToLightroomClassicItem.image = appIcon
            } else {
                sendToLightroomClassicItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            }
            menu.addItem(sendToLightroomClassicItem)

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
            saveItem.image = NSImage(systemSymbolName: "square.and.arrow.down.badge.checkmark", accessibilityDescription: nil)
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
    static let importTools = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.Import")
    static let exportTools = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.Export")
    static let presetTools = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.PresetTools")
    static let zoomOut = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.ZoomOut")
    static let zoomIn = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.ZoomIn")
    static let openFolder = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.OpenFolder")
    static let applyChanges = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.ApplyChanges")
    static let toggleInspector = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.ToggleInspector")
    static let inspectorTrackingSeparator = NSToolbarItem.Identifier("\(AppBrand.identifierPrefix).Toolbar.InspectorTrackingSeparator")
}


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
    private let galleryController: BrowserGalleryViewController
    private let listController: BrowserListViewController
    private var overlayView: NSView?
    private var renderObservers: [AnyCancellable] = []
    private var lastOverlayState: OverlayState = .none
    private var lastRenderedMode: AppModel.BrowserViewMode?
    private var isRenderScheduled = false

    // Path bar
    private var pathBarVC: PathBarViewController?
    private var galleryBottomConstraint: NSLayoutConstraint?
    private var listBottomConstraint: NSLayoutConstraint?
    private let pathBarDefaultsKey = "\(AppBrand.identifierPrefix).pathBarVisible"

    var isPathBarVisible: Bool {
        UserDefaults.standard.bool(forKey: pathBarDefaultsKey)
    }

    init(model: AppModel) {
        self.model = model
        galleryController = BrowserGalleryViewController(model: model, items: model.filteredBrowserItems)
        listController = BrowserListViewController(model: model, items: model.filteredBrowserItems)
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
        galleryBottomConstraint = installChild(galleryController)
        listBottomConstraint = installChild(listController)
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
        guard let galleryBottomConstraint, let listBottomConstraint else { return }
        NSLayoutConstraint.deactivate([galleryBottomConstraint, listBottomConstraint])
        if toPathBar, let pathBarVC {
            self.galleryBottomConstraint = galleryController.view.bottomAnchor.constraint(equalTo: pathBarVC.view.topAnchor)
            self.listBottomConstraint = listController.view.bottomAnchor.constraint(equalTo: pathBarVC.view.topAnchor)
        } else {
            self.galleryBottomConstraint = galleryController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            self.listBottomConstraint = listController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        }
        NSLayoutConstraint.activate([self.galleryBottomConstraint!, self.listBottomConstraint!])
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
        observe(model.$browserEnumerationError.map { $0?.localizedDescription ?? "" }.eraseToAnyPublisher())
        observe(model.$isFolderContentLoading)
        observe(model.$isFolderMetadataLoading)
        observe(model.$browserThumbnailInvalidationToken)
        observe(model.$stagedOpsDisplayToken)
        observe(model.$browserSort)
        observe(model.$browserSortAscending)
        observe(model.$galleryGridLevel)
        observe(model.$inspectorRefreshRevision)
    }

    private func scheduleRender() {
        guard !isRenderScheduled else { return }
        isRenderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRenderScheduled = false
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
        galleryController.update(model: model, items: items)
        listController.update(model: model, items: items)

        let nextOverlayState = currentOverlayState()
        if nextOverlayState == lastOverlayState, nextOverlayState != .loading {
            return
        }
        lastOverlayState = nextOverlayState
        applyOverlay(nextOverlayState)
    }

    private func applyBrowserModeIfNeeded(force: Bool) {
        let mode = model.browserViewMode
        if !force, mode == lastRenderedMode { return }
        lastRenderedMode = mode

        if mode == .gallery {
            galleryController.view.isHidden = false
            listController.view.isHidden = true
        } else {
            listController.view.isHidden = false
            galleryController.view.isHidden = true
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

// MARK: - Closure-based NSMenuItem

// Used by buildSidebarContextMenu(for:) to avoid proliferating @objc action methods.
private final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void

    init(title: String, image: NSImage?, _ closure: @escaping () -> Void) {
        self.closure = closure
        super.init(title: title, action: #selector(performClosure), keyEquivalent: "")
        self.target = self
        self.image = image
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func performClosure() { closure() }
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
