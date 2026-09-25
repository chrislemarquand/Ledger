@preconcurrency import AppKit
import Combine
import LedgerCore
import MapKit
import SharedUI
import SwiftUI
import UniformTypeIdentifiers

final class NativeThreePaneSplitViewController: ThreePaneSplitViewController, NSMenuItemValidation, NSMenuDelegate {
    // v1.4 Phase 4.0: `model`, `browserController`, `isEOS1VSelected`, and the `*ForInjection`
    // menu references were `private` until the menu-construction code moved to
    // MainContentView+Menus.swift — Swift's `private` extends to same-file scope only, not
    // same-type-different-file, so these need at least `internal` visibility now. Same
    // convention already used throughout AppModel's own `AppModel+*.swift` split.
    var model: AppModel

    private let sidebarController: AppKitSidebarController<LedgerSidebarSection, LedgerSidebarItem>
    let browserController: BrowserContainerViewController
    private let inspectorController: NSHostingController<AnyView>
    private let eos1vSessionController: EOS1VSessionController
    private let eos1vDeviceController: EOS1VDeviceViewController
    private let eos1vDeviceMonitor = EOS1VDeviceMonitor()

    private var didConfigureWindow = false
    private var mainToolbarController: MainToolbarController?
    private var toolbarShellController: ToolbarShellController?
    weak var fileMenuForInjection: NSMenu?
    weak var editMenuForInjection: NSMenu?
    weak var viewMenuForSortInjection: NSMenu?
    weak var imageMenuForInjection: NSMenu?
    weak var folderMenuForInjection: NSMenu?
    weak var helpMenuForInjection: NSMenu?
    private var uiRefreshObservers: [AnyCancellable] = []
    private var browserFocusRequestObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var lastWindowTitleText = ""
    private var lastWindowSubtitleText = ""
    private let modelUIRefreshCoalescer = MainActorCoalescer()
    private let sidebarReloadCoalescer = MainActorCoalescer()
    private let sidebarSelectionSyncCoalescer = MainActorCoalescer()
    private var inspectorStateBeforeDeviceSelection: Bool?
    init(model: AppModel) {
        self.model = model

        let sc = AppKitSidebarController(
            sections: Self.buildSidebarSections(from: model),
            items: Self.buildSidebarItems(from: model),
            initialSelectionBehavior: .noInitialSelection
        )
        let bc = BrowserContainerViewController(model: model)
        let ic = NSHostingController(rootView: AnyView(InspectorView(model: model)))
        // Prevent inspector content from forcing pane expansion during SwiftUI view updates.
        ic.sizingOptions = []
        let eosSession = EOS1VSessionController()
        let eosController = EOS1VDeviceViewController(session: eosSession)

        self.sidebarController = sc
        self.browserController = bc
        self.inspectorController = ic
        self.eos1vSessionController = eosSession
        self.eos1vDeviceController = eosController

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
        sc.onItemPromotedToSection = { [weak self] item, targetSection in
            guard let self,
                  let sidebarItem = self.model.sidebarItems.first(where: { $0.id == item.id })
            else { return }
            switch targetSection {
            case .pinned:   self.model.pinSidebarItem(sidebarItem)
            case .recents:  self.model.unpinSidebarItem(sidebarItem)
            case .sources, .devices: break
            }
        }

        onPaneStateChanged = { [weak self] in
            guard let self else { return }
            let sc = self.isSidebarCollapsed
            let ic = self.isInspectorCollapsed
            let sidebarChanged = self.model.isSidebarCollapsed != sc
            let inspectorChanged = self.model.isInspectorCollapsed != ic
            if sidebarChanged { self.model.isSidebarCollapsed = sc }
            if inspectorChanged { self.model.isInspectorCollapsed = ic }
            if sidebarChanged || inspectorChanged {
                self.refreshToolbarState()
            }
        }

        installUIRefreshObservers()
        eos1vDeviceMonitor.onPresenceChanged = { [weak self] connected in
            guard let self else { return }
            self.model.setEOS1VCableConnected(connected)
            if !connected {
                self.eos1vSessionController.cableDidDisconnect()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        eos1vDeviceMonitor.start()
        configureWindowIfNeeded()
        // v1.4 follow-up: `configureWindowIfNeeded()`'s body only ever runs once
        // (`didConfigureWindow` latches permanently) — the two lines below used to only be
        // reachable through it, so if `teardownObserversAndMonitors()` (below, on disappear)
        // cleared them, a second appearance of this same, still-retained view controller (main
        // window closed while an auxiliary window like Settings/Console kept the app alive,
        // then reopened via the Dock) never got them back. Both are already idempotent
        // (`guard ... == nil`), so calling them unconditionally on every appearance is safe.
        installBrowserFocusRequestObserverIfNeeded()
        installKeyMonitorIfNeeded()
        if uiRefreshObservers.isEmpty {
            installUIRefreshObservers()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        eos1vDeviceMonitor.stop()
        teardownObserversAndMonitors()
    }

    private func teardownObserversAndMonitors() {
        uiRefreshObservers.removeAll()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let browserFocusRequestObserver {
            NotificationCenter.default.removeObserver(browserFocusRequestObserver)
            self.browserFocusRequestObserver = nil
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

        eos1vSessionController.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.scheduleModelDrivenUIRefresh()
                }
            }
            .store(in: &uiRefreshObservers)

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
        modelUIRefreshCoalescer.schedule { [weak self] in
            guard let self else { return }
            self.refreshToolbarState()
            self.refreshWindowTitleSubtitleIfNeeded()
            self.updateEOS1VVisibilityIfNeeded()
        }
    }

    var isEOS1VSelected: Bool {
        model.selectedSidebarItem?.kind == .eos1vDevice
    }

    /// The only thing that ever changes here is `eos1vDeviceController.view.isHidden`.
    /// `browserController.view` is never touched — see `installEOS1VDeviceOverlay()`.
    private func updateEOS1VVisibilityIfNeeded() {
        eos1vDeviceController.view.isHidden = !isEOS1VSelected
        if isEOS1VSelected {
            if inspectorStateBeforeDeviceSelection == nil {
                inspectorStateBeforeDeviceSelection = isInspectorCollapsed
            }
            if !isInspectorCollapsed {
                isInspectorCollapsed = true
                schedulePaneStateSync()
            }
        } else if let prior = inspectorStateBeforeDeviceSelection {
            inspectorStateBeforeDeviceSelection = nil
            if isInspectorCollapsed != prior {
                isInspectorCollapsed = prior
                schedulePaneStateSync()
            }
        }
    }

    private func scheduleSidebarReload() {
        sidebarReloadCoalescer.schedule { [weak self] in
            guard let self else { return }
            self.sidebarController.sections = Self.buildSidebarSections(from: self.model)
            self.sidebarController.items = Self.buildSidebarItems(from: self.model)
            self.sidebarController.reloadData()
        }
    }

    private func scheduleSidebarSelectionSync() {
        sidebarSelectionSyncCoalescer.schedule { [weak self] in
            guard let self else { return }
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
        installEOS1VDeviceOverlay()
    }

    /// Mounts the EOS-1V device screen as a plain sibling of the browser's view, drawn
    /// above it — never as a child of it (the browser's own "No Supported Images"/"No
    /// Selection" overlay paints unconditionally inside its own view whenever
    /// `browserItems` is empty, which it always is while the device is selected; a child
    /// view would get painted over) and never by reparenting or hiding the browser's view
    /// itself (AppKit sends viewWillAppear/viewWillDisappear on any such change, and
    /// BrowserContainerViewController tears down its render subscriptions on
    /// viewWillDisappear with no reinstall path — that combination is what caused the
    /// stale-browser regression previously). BrowserContainerViewController is not
    /// touched by this at all: its parentage and lifecycle stay exactly as they are for
    /// every other sidebar kind.
    ///
    /// Done here in viewDidLoad, not init — browserController.view.superview must
    /// already exist, which is only guaranteed once the normal AppKit view-loading
    /// bootstrap (triggered by NSWindow(contentViewController:)) has run.
    ///
    /// addChild is called on browserController (a plain NSViewController), never on
    /// `self` — self is an NSSplitViewController subclass, and addChild there
    /// implicitly creates an extra, empty arranged subview in the split.
    private func installEOS1VDeviceOverlay() {
        guard let browserSuperview = browserController.view.superview else {
            assertionFailure("browserController.view has no superview yet")
            return
        }
        browserController.addChild(eos1vDeviceController)
        eos1vDeviceController.view.translatesAutoresizingMaskIntoConstraints = false
        eos1vDeviceController.view.isHidden = true
        browserSuperview.addSubview(eos1vDeviceController.view, positioned: .above, relativeTo: browserController.view)
        NSLayoutConstraint.activate([
            eos1vDeviceController.view.leadingAnchor.constraint(equalTo: browserController.view.leadingAnchor),
            eos1vDeviceController.view.trailingAnchor.constraint(equalTo: browserController.view.trailingAnchor),
            eos1vDeviceController.view.topAnchor.constraint(equalTo: browserController.view.topAnchor),
            eos1vDeviceController.view.bottomAnchor.constraint(equalTo: browserController.view.bottomAnchor),
        ])
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

    // v1.4 Phase 4.3: internal (was private) so MainWindowController can install the toolbar
    // on the window before assigning self as its contentViewController — see the init comment
    // in LedgerApp.swift for why: NSWindow(contentViewController:) forces this controller's
    // view through a real, geometry-bearing layout pass immediately, and if the toolbar isn't
    // attached yet at that point, NSScrollView.automaticallyAdjustsContentInsets computes a
    // zero top inset for the sidebar and never retroactively corrects it once the toolbar
    // later appears — the root cause of the sidebar's launch-time scroll snap.
    func installMainToolbar(on window: NSWindow, resetDelegateState: Bool) {
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

        // v1.4 Phase 4.3: configureWindowForToolbar(window) and installMainToolbar(on:) now run
        // in MainWindowController.init, before this controller is attached to the window at
        // all — see installMainToolbar's doc comment. Only the toolbar's per-appearance
        // revalidation belongs here.
        toolbarShellController?.syncAndValidate(window: window)
        if isSidebarCollapsed { isSidebarCollapsed = false }
        schedulePaneStateSync()
        refreshWindowTitleSubtitleIfNeeded()
        installBrowserFocusRequestObserverIfNeeded()
        installKeyMonitorIfNeeded()
        // v1.4 Phase 4.1: menu injection used to happen here, deferred by one run-loop tick
        // and re-registered defensively on every menu-bar click (NSMenu.didBeginTrackingNotification)
        // because SwiftUI could mutate NSApp.mainMenu after this point, invalidating the
        // *ForInjection weak references. AppDelegate now builds the menu shells before any
        // NSHostingController exists and populates their content immediately after
        // MainWindowController is constructed — see LedgerApp.swift's applicationDidFinishLaunching
        // — so injection here would just be redundant, not defensive. focusBrowserPane still
        // needs its own run-loop-tick defer (unrelated to the menu timing issue): the window
        // isn't necessarily key/able to accept first responder yet at this exact point in the
        // view lifecycle.
        DispatchQueue.main.async { [weak self] in
            self?.focusBrowserPane()
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

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option, .function])
            let isTabWithoutCommand = event.keyCode == KeyCode.tab && (modifiers.isEmpty || modifiers == [.shift])

            if isTabWithoutCommand && shouldHandlePaneTabSwitch() {
                togglePaneFocus()
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

            // Zoom shortcuts work anywhere in the key window (including inspector focus)
            // when gallery mode is active and zoom can change.
            if let window = view.window ?? NSApp.keyWindow,
               KeyboardShortcutSupport.canHandleWindowShortcuts(in: window) {
                if event.keyCode == KeyCode.equal || event.keyCode == KeyCode.numpadPlus {
                    guard modifiers == [.command] || modifiers == [.command, .shift] else { return event }
                    guard model.browserViewMode == .icon else { return nil }
                    guard model.canIncreaseGalleryZoom else { return nil }
                    model.increaseGalleryZoom()
                    refreshToolbarState()
                    return nil
                }
                if event.keyCode == KeyCode.minus || event.keyCode == KeyCode.numpadMinus {
                    guard modifiers == [.command] || modifiers == [.command, .shift] else { return event }
                    guard model.browserViewMode == .icon else { return nil }
                    guard model.canDecreaseGalleryZoom else { return nil }
                    model.decreaseGalleryZoom()
                    refreshToolbarState()
                    return nil
                }
            }

            if event.keyCode == KeyCode.space,
               modifiers.intersection([.command, .control, .option, .function]).isEmpty,
               !event.isARepeat {
                guard shouldHandleBrowserKeyCommands() else { return event }
                model.quickLookSelection()
                return nil
            }

            guard shouldHandleBrowserKeyCommands() else { return event }

            switch event.keyCode {
            case 36, 76:
                guard modifiers.isEmpty else { return event }
                guard !model.selectedFileURLs.isEmpty else { return nil }
                self.focusInspectorEntryAction(nil)
                return nil
            case KeyCode.escape:
                guard modifiers.isEmpty else { return event }
                self.browserController.clearActiveBrowserSelectionUI()
                model.clearSelection()
                return nil
            case _ where event.characters == "a":
                guard modifiers == [.command] else { return event }
                model.selectAllFilteredFiles()
                return nil
            case _ where event.characters == "d":
                guard modifiers == [.command] else { return event }
                model.clearSelection()
                return nil
            case KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.downArrow, KeyCode.upArrow:
                guard let direction = moveDirection(forKeyCode: event.keyCode) else { return event }
                if modifiers.isEmpty {
                    switch model.browserViewMode {
                    case .icon:
                        model.moveSelectionInIconGrid(direction: direction, extendingSelection: false)
                        return nil
                    case .gallery:
                        model.moveSelectionInFilmstrip(direction: direction, extendingSelection: false)
                        return nil
                    case .list:
                        if direction == .up || direction == .down {
                            model.moveSelectionInList(direction: direction, extendingSelection: false)
                            return nil
                        }
                        return event
                    }
                }
                guard modifiers == [.shift] else { return event }
                switch model.browserViewMode {
                case .icon:
                    model.moveSelectionInIconGrid(direction: direction, extendingSelection: true)
                case .gallery:
                    model.moveSelectionInFilmstrip(direction: direction, extendingSelection: true)
                case .list:
                    model.moveSelectionInList(direction: direction, extendingSelection: true)
                }
                return nil
            default:
                return event
            }
        }
    }

    private func shouldHandlePaneTabSwitch() -> Bool {
        KeyboardShortcutSupport.shouldHandlePaneTabSwitch(
            in: view.window,
            sidebarView: sidebarController.view,
            contentView: browserController.view
        )
    }

    private func shouldHandleInspectorTabCommands() -> Bool {
        guard let window = view.window else { return false }
        guard KeyboardShortcutSupport.canHandleWindowShortcuts(in: window) else { return false }
        guard let responderView = window.firstResponder as? NSView else { return false }
        return responderView === inspectorController.view || responderView.isDescendant(of: inspectorController.view)
    }

    private func shouldHandleBrowserKeyCommands() -> Bool {
        guard let window = view.window else { return false }
        guard KeyboardShortcutSupport.canHandleWindowShortcuts(in: window) else { return false }
        if let textView = window.firstResponder as? NSTextView, textView.isEditable { return false }
        guard let responderView = window.firstResponder as? NSView else { return false }
        return responderView === browserController.view || responderView.isDescendant(of: browserController.view)
    }

    private func togglePaneFocus() {
        KeyboardShortcutSupport.togglePaneFocus(
            in: view.window,
            sidebarView: sidebarController.view,
            contentView: browserController.view,
            focusSidebar: { [weak self] in self?.sidebarController.focusSidebar() },
            focusContent: { [weak self] in self?.focusBrowserPane() }
        )
    }

    private func moveDirection(forKeyCode keyCode: UInt16) -> SharedUI.MoveCommandDirection? {
        switch keyCode {
        case KeyCode.leftArrow: return .left
        case KeyCode.rightArrow: return .right
        case KeyCode.downArrow: return .down
        case KeyCode.upArrow: return .up
        default: return nil
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

    @objc func toggleInspectorAction(_ sender: Any?) {
        guard !isEOS1VSelected else { return }
        toggleInspector(sender)
    }
    @objc func togglePathBarAction(_ sender: Any?) { browserController.setPathBarVisible(!browserController.isPathBarVisible) }

    private func focusBrowserPane() {
        guard view.window != nil else { return }
        browserController.focusCurrentBrowserView()
    }

    private func toolbarTitleText() -> String {
        guard let item = model.selectedSidebarItem else { return AppBrand.displayName }
        switch item.kind {
        case .pictures, .desktop, .downloads, .mountedVolume, .favorite:
            return item.title
        case .eos1vDevice:
            return "Canon EOS-1V"
        case let .folder(url):
            return url.lastPathComponent
        }
    }

    private func toolbarSubtitleText() -> String {
        // The Connect tab's own status card already shows this same state
        // ("ES-E1 cable connected", "Searching…", etc.) — the toolbar
        // subtitle was just duplicating it.
        if isEOS1VSelected {
            return ""
        }
        // ExifTool reads (and therefore folderMetadataLoadCompleted) skip iCloud placeholders,
        // so "Loading X of Y…" can never reach Y while any are present — reads as permanently
        // stuck. Surface the iCloud count instead whenever placeholders exist.
        let placeholderCount = model.browserItems.filter { $0.cloudState.isPlaceholder }.count

        if model.isApplyingMetadata {
            let total = max(model.applyMetadataTotal, 0)
            let done = min(max(model.applyMetadataCompleted, 0), total)
            return "Applying \(done) of \(total)…"
        }
        if model.isFolderMetadataLoading {
            if placeholderCount > 0 {
                return placeholderCount == 1
                    ? "Loading… (1 image not downloaded from iCloud)"
                    : "Loading… (\(placeholderCount) images not downloaded from iCloud)"
            }
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
        let baseText = selected > 0 && selected < total
            ? "\(selected) of \(total) images"
            : (total == 1 ? "1 image" : "\(total) images")
        guard placeholderCount > 0 else { return baseText }
        return placeholderCount == 1
            ? "\(baseText) · 1 not downloaded"
            : "\(baseText) · \(placeholderCount) not downloaded"
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
                        alert.messageText = "Couldn\u{2019}t export."
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

        guard !selectionURLs.isEmpty else {
            // No selection — fall straight through, but warn about pending edits if needed.
            guard hasPendingEdits else {
                completion(.folder, folderURLs)
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "You have unapplied changes."
            alert.informativeText = "They won\u{2019}t be included unless you apply them first."
            alert.addButton(withTitle: actionTitle)
            alert.addButton(withTitle: "Cancel")
            alert.runSheetOrModal(for: view.window) { response in
                guard response == .alertFirstButtonReturn else { return }
                completion(.folder, folderURLs)
            }
            return
        }

        // Which files to include is a routine choice, not a warning — HIG: alert buttons
        // should be verbs describing what happens to something at risk, not a stand-in for
        // an options picker. An accessory segmented control carries the choice; the alert's
        // two buttons stay a real action-verb + Cancel.
        let n = selectionURLs.count
        let scopeControl = NSSegmentedControl(labels: ["Selection (\(n))", "Folder"], trackingMode: .selectOne, target: nil, action: nil)
        scopeControl.selectedSegment = 0
        scopeControl.translatesAutoresizingMaskIntoConstraints = false

        let alert = NSAlert()
        if hasPendingEdits {
            alert.alertStyle = .warning
            alert.messageText = "You have unapplied changes."
            alert.informativeText = "They won\u{2019}t be included unless you apply them first. Choose which files to include below."
        } else {
            alert.messageText = "Choose which files to include."
            alert.informativeText = "\(n) \(n == 1 ? "file is" : "files are") selected, or you can include the whole folder."
        }
        alert.accessoryView = scopeControl
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "Cancel")

        alert.runSheetOrModal(for: view.window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if scopeControl.selectedSegment == 0 {
                completion(.selection, selectionURLs)
            } else {
                completion(.folder, folderURLs)
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
    func rotateSelectionAnticlockwiseAction(_: Any?) {
        let files = Array(model.selectedFileURLs).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }
        for fileURL in files {
            model.rotateLeft(fileURL: fileURL)
        }
    }

    @objc
    func rotateSelectionClockwiseAction(_: Any?) {
        let files = Array(model.selectedFileURLs).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }
        for fileURL in files {
            model.rotateRight(fileURL: fileURL)
        }
    }

    @objc
    func flipSelectionHorizontalAction(_: Any?) {
        let files = Array(model.selectedFileURLs).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }
        for fileURL in files {
            model.flipHorizontal(fileURL: fileURL)
        }
    }

    @objc
    func flipSelectionVerticalAction(_: Any?) {
        let files = Array(model.selectedFileURLs).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }
        for fileURL in files {
            model.flipVertical(fileURL: fileURL)
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
        NotificationCenter.default.post(
            name: .inspectorDidRequestFieldNavigation,
            object: nil,
            userInfo: ["backward": false]
        )
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
        guard model.browserViewMode == .icon else { return }
        model.decreaseGalleryZoom()
        refreshToolbarState()
    }

    @objc
    func zoomInAction(_: Any?) {
        guard model.browserViewMode == .icon else { return }
        model.increaseGalleryZoom()
        refreshToolbarState()
    }

    @objc
    func switchToIconAction(_: Any?) {
        model.browserViewMode = .icon
        refreshToolbarState()
        NotificationCenter.default.post(name: .browserDidSwitchViewMode, object: nil)
        focusBrowserPane()
    }

    @objc
    func switchToListAction(_: Any?) {
        model.browserViewMode = .list
        refreshToolbarState()
        NotificationCenter.default.post(name: .browserDidSwitchViewMode, object: nil)
        focusBrowserPane()
    }

    @objc
    func switchToGalleryAction(_: Any?) {
        model.browserViewMode = .gallery
        refreshToolbarState()
        NotificationCenter.default.post(name: .browserDidSwitchViewMode, object: nil)
        focusBrowserPane()
    }

    @objc
    func setIconSubtitleAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        model.iconSubtitleColumnID = item.representedObject as? String
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

    @objc func adjustDateTimeAction(_: Any?) {
        let scope: DateTimeAdjustScope = model.selectedFileURLs.count > 1 ? .selection : .single
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.beginDateTimeAdjust(scope: scope, launchTag: .dateTimeOriginal, launchContext: .menu)
        }
    }

    @objc
    func setLocationAction(_: Any?) {
        guard model.canOpenLocationAdjustSheet() else { return }
        model.beginLocationAdjust()
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
        switch sender.selectedIndex {
        case 1: model.browserViewMode = .list
        case 2: model.browserViewMode = .gallery
        default: model.browserViewMode = .icon
        }
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
                let iconImage = NSImage(systemSymbolName: "square.grid.3x2", accessibilityDescription: "Icon")
                    ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icon")
                    ?? NSImage()
                let listImage = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List") ?? NSImage()
                let galleryImage = NSImage(systemSymbolName: "squares.below.rectangle", accessibilityDescription: "Gallery") ?? NSImage()
                let item = NSToolbarItemGroup(
                    itemIdentifier: itemIdentifier,
                    images: [iconImage, listImage, galleryImage],
                    selectionMode: .selectOne,
                    labels: ["Icons", "List", "Gallery"],
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
            updateZoomItems(with: model)
            updateSortMenu(with: model)
            updateImportMenu(with: model)
            updateExportMenu(with: model)
            updatePresetsMenu(with: model)
            updateApplyStyle(with: model)
            updateInspectorLabels(with: model)
        }

        private func updateViewMode(with model: AppModel) {
            switch model.browserViewMode {
            case .icon: viewModeGroupItem?.selectedIndex = 0
            case .list: viewModeGroupItem?.selectedIndex = 1
            case .gallery: viewModeGroupItem?.selectedIndex = 2
            }
        }

        private func updateZoomItems(with model: AppModel) {
            let inIconGrid = model.browserViewMode == .icon
            zoomOutItem?.isEnabled = inIconGrid && model.canDecreaseGalleryZoom
            zoomInItem?.isEnabled = inIconGrid && model.canIncreaseGalleryZoom
        }

        private func updateSortMenu(with model: AppModel) {
            let menu = makeSortMenu(model: model)
            sortMenu = menu
            sortItem?.menu = menu
            applySortState(model.browserSort, to: menu)
            // NSMenuToolbarItem doesn't reliably grey itself out from the
            // NSToolbarItemValidation return value alone — see updateZoomItems,
            // which has always driven zoom's enabled state directly for the same
            // reason. Mirror that proven approach here rather than relying solely
            // on validateToolbarItem for this item.
            sortItem?.isEnabled = controller?.isEOS1VSelected != true && !model.browserItems.isEmpty
        }

        private func updatePresetsMenu(with model: AppModel) {
            let menu = makePresetsMenu(model: model)
            presetsMenu = menu
            presetsItem?.menu = menu
            presetsItem?.isEnabled = controller?.isEOS1VSelected != true
        }

        private func updateImportMenu(with model: AppModel) {
            let menu = makeImportMenu(model: model)
            importMenu = menu
            importItem?.menu = menu
            importItem?.isEnabled = controller?.isEOS1VSelected != true && !model.browserItems.isEmpty
        }

        private func updateExportMenu(with model: AppModel) {
            let menu = makeExportMenu(model: model)
            exportMenu = menu
            exportItem?.menu = menu
            exportItem?.isEnabled = controller?.isEOS1VSelected != true && !model.browserItems.isEmpty
        }

        private func updateApplyStyle(with model: AppModel) {
            if #available(macOS 26.0, *) {
                applyChangesItem?.style = model.canApplyMetadataChanges ? .prominent : .plain
            }
            applyChangesItem?.isEnabled = controller?.isEOS1VSelected != true && model.canApplyMetadataChanges
        }

        private func updateInspectorLabels(with model: AppModel) {
            let label = model.isInspectorCollapsed ? "Show Inspector" : "Hide Inspector"
            inspectorToggleItem?.label = label
            inspectorToggleItem?.toolTip = label
            inspectorToggleItem?.isEnabled = controller?.isEOS1VSelected != true
        }

        func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
            guard let controller else { return false }
            let model = controller.model

            if controller.isEOS1VSelected { return false }

            switch item.itemIdentifier {
            case .zoomOut:
                updateZoomItems(with: model)
                return model.browserViewMode == .icon && model.canDecreaseGalleryZoom
            case .zoomIn:
                updateZoomItems(with: model)
                return model.browserViewMode == .icon && model.canIncreaseGalleryZoom
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
            return NativeThreePaneSplitViewController.buildImportMenu(controller: controller, model: model)
        }

        private func makeExportMenu(model: AppModel) -> NSMenu {
            guard let controller else { return NSMenu(title: "Export") }
            return NativeThreePaneSplitViewController.buildExportMenu(
                controller: controller,
                model: model
            )
        }

        private func makePresetsMenu(model: AppModel) -> NSMenu {
            guard let controller else { return NSMenu(title: "Presets") }
            return controller.makeSharedPresetsMenu(model: model)
        }
    }
}

extension NativeThreePaneSplitViewController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        mainToolbarController?.validateToolbarItem(item) ?? true
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
