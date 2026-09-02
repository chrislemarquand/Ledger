import AppKit

// v1.4 Phase 4.0: extracted from MainContentView.swift's NativeThreePaneSplitViewController,
// which was mixing menu wiring, split-view shell, observers, and context-menu actions in one
// 2,598-line file — exactly the structure docs/menu-bar-architecture-audit-2026-08.md and
// docs/v1.4-architecture-plan-2026-08.md point to as what made the metadata-copy/paste
// regression (two timing contracts silently sharing one function) easy to cause. This is a
// pure move, no behavior change — isolates the menu-bar construction/population/validation
// code so Phase 4.1's actual rewrite (owning the static menu before hosted UI, removing the
// deferred-injection/reinjection mechanism still in MainContentView.swift's
// configureWindowIfNeeded()) has a smaller, dedicated file to work in.
extension NativeThreePaneSplitViewController {
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

        static let imageApplySelection = 9_301
        static let imageRefreshSelection = 9_302
        static let imageClearSelection = 9_303
        static let imageRestoreSelection = 9_304
        static let folderApply = 9_305
        static let folderRefresh = 9_306
        static let folderClear = 9_307
        static let folderRestore = 9_308
        static let imageSavePreset = 9_309
        static let imageManagePresets = 9_310
        static let imageApplyPreset = 9_311
        static let imageBatchRenameSelection = 9_312
        static let imageAdjustDateTime = 9_314
        static let imageSetLocation = 9_315
        static let imageRotateAnticlockwise = 9_316
        static let imageRotateClockwise = 9_317
        static let imageFlipHorizontal = 9_318
        static let imageFlipVertical = 9_319
        static let folderBatchRename = 9_320

        static let helpWhatsNew = 9_400
        static let helpExifToolDocs = 9_401
    }

    // v1.4 Phase 4.1: static (was an instance method that never touched `self`) so
    // AppDelegate can build the top-level menu shells before any view controller exists.
    static func ensureTopLevelMenu(title: String, insertAfterTitle: String? = nil) -> NSMenu? {
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

    func injectFileMenuIfNeeded() {
        let appMenuTitle = NSApp.mainMenu?.items.first?.title
        guard let submenu = Self.ensureTopLevelMenu(title: "File", insertAfterTitle: appMenuTitle) else { return }
        fileMenuForInjection = submenu
        submenu.delegate = self
        rebuildFileMenu(submenu)
    }

    func injectEditMenuIfNeeded() {
        guard let submenu = Self.ensureTopLevelMenu(title: "Edit", insertAfterTitle: "File") else { return }
        editMenuForInjection = submenu
        submenu.delegate = self
        rebuildEditMenu(submenu)
    }

    /// Finds the View menu and registers self as its NSMenuDelegate.
    /// Also calls rebuildViewMenu immediately so Zoom In/Out keyboard shortcuts
    /// are registered from launch.
    func injectSortMenuIfNeeded() {
        guard let submenu = Self.ensureTopLevelMenu(title: "View", insertAfterTitle: "Edit") else { return }
        viewMenuForSortInjection = submenu
        submenu.delegate = self
        rebuildViewMenu(submenu)
    }

    func injectImageMenuIfNeeded() {
        guard let submenu = Self.ensureTopLevelMenu(title: "Image", insertAfterTitle: "View") else { return }
        imageMenuForInjection = submenu
        submenu.delegate = self
        rebuildImageMenu(submenu)
    }

    func injectFolderMenuIfNeeded() {
        guard let submenu = Self.ensureTopLevelMenu(title: "Folder", insertAfterTitle: "Image") else { return }
        folderMenuForInjection = submenu
        submenu.delegate = self
        rebuildFolderMenu(submenu)
    }

    func injectHelpMenuIfNeeded() {
        if NSApp.mainMenu?.items.contains(where: { $0.title == "Window" }) == true {
            guard let submenu = Self.ensureTopLevelMenu(title: "Help", insertAfterTitle: "Window") else { return }
            helpMenuForInjection = submenu
            submenu.delegate = self
            rebuildHelpMenu(submenu)
            return
        }
        guard let submenu = Self.ensureTopLevelMenu(title: "Help", insertAfterTitle: "Folder") else { return }
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

    /// Icon-view-only: a single-select subtitle field shown below each thumbnail's filename.
    /// Reuses `ListColumnDefinition`'s existing field list and `AppModel.listColumnValue` so
    /// this can never disagree with List view's column picker about how a field is formatted.
    private func makeSubtitleMenuItem() -> NSMenuItem {
        let subtitleMenu = NSMenu(title: "Subtitle")

        let noneItem = NSMenuItem(title: "None", action: #selector(setIconSubtitleAction(_:)), keyEquivalent: "")
        subtitleMenu.addItem(noneItem)
        subtitleMenu.addItem(.separator())

        for column in ListColumnDefinition.toggleable {
            let columnItem = NSMenuItem(title: column.label, action: #selector(setIconSubtitleAction(_:)), keyEquivalent: "")
            columnItem.representedObject = column.id
            subtitleMenu.addItem(columnItem)
        }

        let item = NSMenuItem(title: "Subtitle", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "text.below.photo", accessibilityDescription: nil)
        item.submenu = subtitleMenu
        return item
    }

    /// Rebuilds the View menu in the desired order with SF Symbol images.
    /// Collects SwiftUI-managed items (Toggle Sidebar, Toggle Inspector) and any
    /// unrecognised AppKit items (Enter Full Screen), clears the menu, then re-adds
    /// everything in order: As Gallery, As List, Sort By, Zoom In/Out,
    /// Toggle Sidebar, Toggle Inspector, other (Enter Full Screen).
    private func rebuildViewMenu(_ menu: NSMenu) {
        // Early exit if already in the correct order.
        guard menu.items.first?.title.lowercased() != "as icons" else { return }

        // Collect items we don't own so we can keep them.
        var sidebarMenuItem: NSMenuItem?
        var inspectorMenuItem: NSMenuItem?
        var extraItems: [NSMenuItem] = []
        let ownedTitles: Set<String> = ["as icons", "as gallery", "as list", "sort by", "zoom in", "zoom out", "show path bar", "hide path bar", "show exiftool console"]

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
        // macOS 27 has AppKit hide menu-item SF Symbol images by default; opt these three back
        // in explicitly via `makeImagePreferredVisible()` (SharedUI's KVC-based wrapper around
        // `preferredImageVisibility`, since that property's SDK declaration is macOS-27-only —
        // see MenuBuilders.swift) so they render the same on 27 as they already do on 26.
        // `.image` alone isn't enough there.
        let iconItem = NSMenuItem(title: "as Icons", action: #selector(switchToIconAction(_:)), keyEquivalent: "1")
        iconItem.keyEquivalentModifierMask = .command
        iconItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        iconItem.makeImagePreferredVisible()

        let listItem = NSMenuItem(title: "as List", action: #selector(switchToListAction(_:)), keyEquivalent: "2")
        listItem.keyEquivalentModifierMask = .command
        listItem.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
        listItem.makeImagePreferredVisible()

        let galleryItem = NSMenuItem(title: "as Gallery", action: #selector(switchToGalleryAction(_:)), keyEquivalent: "3")
        galleryItem.keyEquivalentModifierMask = .command
        galleryItem.image = NSImage(systemSymbolName: "squares.below.rectangle", accessibilityDescription: nil)
        galleryItem.makeImagePreferredVisible()

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
        menu.addItem(iconItem)
        menu.addItem(listItem)
        menu.addItem(galleryItem)
        menu.addItem(.separator())
        menu.addItem(makeSubtitleMenuItem())
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
        let exifToolConsoleItem = NSMenuItem(
            title: "Show ExifTool Console",
            action: #selector(AppDelegate.showExifToolConsoleAction(_:)),
            keyEquivalent: ""
        )
        exifToolConsoleItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        menu.addItem(exifToolConsoleItem)
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
            let appIcon = NSWorkspace.shared.icon(forFile: app.url.path)
            appIcon.size = NSSize(width: 16, height: 16)
            item.image = appIcon
            submenu.addItem(item)
        }
        return submenu
    }

    private func makeImportSubmenu() -> NSMenu {
        Self.buildImportMenu(controller: self, model: model)
    }

    static func buildImportMenu(
        controller: NativeThreePaneSplitViewController,
        model: AppModel
    ) -> NSMenu {
        let menu = NSMenu(title: "Import")
        menu.autoenablesItems = false
        let isEnabled = !model.browserItems.isEmpty

        let items: [(title: String, action: Selector, symbol: String, tag: Int)] = [
            ("CSV…", #selector(importCSVAction(_:)), "tablecells", MenuTag.fileImportCSV),
            ("GPX…", #selector(importGPXAction(_:)), "location", MenuTag.fileImportGPX),
            ("Reference Folder…", #selector(importReferenceFolderAction(_:)), "folder.badge.questionmark", MenuTag.fileImportReferenceFolder),
            ("Reference Image…", #selector(importReferenceImageAction(_:)), "photo.badge.plus", MenuTag.fileImportReferenceImage),
            ("EOS-1V…", #selector(importEOS1VAction(_:)), "camera", MenuTag.fileImportEOS1V),
        ]

        for descriptor in items {
            let item = NSMenuItem(title: descriptor.title, action: descriptor.action, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: descriptor.symbol, accessibilityDescription: nil)
            item.tag = descriptor.tag
            item.isEnabled = isEnabled
            menu.addItem(item)
        }
        return menu
    }

    private func makeExportSubmenu() -> NSMenu {
        Self.buildExportMenu(controller: self, model: model)
    }

    static func buildExportMenu(
        controller: NativeThreePaneSplitViewController,
        model: AppModel
    ) -> NSMenu {
        let menu = NSMenu(title: "Export")
        menu.autoenablesItems = false

        let hasBrowserItems = !model.browserItems.isEmpty
        let targetURLs = model.selectedFileURLs.isEmpty ? model.browserItems.map(\.url) : Array(model.selectedFileURLs)

        let createCSVItem = NSMenuItem(
            title: "Create CSV…",
            action: #selector(NativeThreePaneSplitViewController.exportExifToolCSVAction(_:)),
            keyEquivalent: ""
        )
        createCSVItem.tag = MenuTag.fileExportExifToolCSV
        createCSVItem.isEnabled = hasBrowserItems
        createCSVItem.image = NSImage(systemSymbolName: "tablecells.badge.ellipsis", accessibilityDescription: nil)
        menu.addItem(createCSVItem)

        let photosState = model.fileActionState(for: .sendToPhotos, targetURLs: targetURLs)
        let sendToPhotosItem = NSMenuItem(
            title: "Send to Photos…",
            action: #selector(NativeThreePaneSplitViewController.sendToPhotosAction(_:)),
            keyEquivalent: ""
        )
        sendToPhotosItem.tag = MenuTag.fileExportSendToPhotos
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
        sendToLightroomItem.tag = MenuTag.fileExportSendToLightroom
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
        sendToLightroomClassicItem.tag = MenuTag.fileExportSendToLightroomClassic
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

    private func rebuildEditMenu(_ menu: NSMenu) {
        ensureEditMenuBaseline(in: menu)

        menu.items.first(where: { $0.action == #selector(undoMetadataMenuAction(_:)) })?.image =
            NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        menu.items.first(where: { $0.action == #selector(redoMetadataMenuAction(_:)) })?.image =
            NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: nil)
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
        menu.addItem(undoItem)

        let redoItem = NSMenuItem(title: "Redo", action: #selector(redoMetadataMenuAction(_:)), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = .command
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

        let adjustDateTimeItem = NSMenuItem(
            title: "Adjust Date and Time\u{2026}",
            action: #selector(adjustDateTimeAction(_:)),
            keyEquivalent: ""
        )
        adjustDateTimeItem.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: nil)
        adjustDateTimeItem.tag = MenuTag.imageAdjustDateTime
        menu.addItem(adjustDateTimeItem)

        let setLocationItem = NSMenuItem(
            title: "Set Location\u{2026}",
            action: #selector(setLocationAction(_:)),
            keyEquivalent: ""
        )
        setLocationItem.image = NSImage(systemSymbolName: "mappin.and.ellipse", accessibilityDescription: nil)
        setLocationItem.tag = MenuTag.imageSetLocation
        menu.addItem(setLocationItem)
        menu.addItem(.separator())

        let rotateAnticlockwiseItem = NSMenuItem(
            title: "Rotate Anticlockwise",
            action: #selector(rotateSelectionAnticlockwiseAction(_:)),
            keyEquivalent: ""
        )
        rotateAnticlockwiseItem.image = NSImage(systemSymbolName: "rotate.left", accessibilityDescription: nil)
        rotateAnticlockwiseItem.tag = MenuTag.imageRotateAnticlockwise
        rotateAnticlockwiseItem.makeImagePreferredVisible()
        menu.addItem(rotateAnticlockwiseItem)

        let rotateClockwiseItem = NSMenuItem(
            title: "Rotate Clockwise",
            action: #selector(rotateSelectionClockwiseAction(_:)),
            keyEquivalent: ""
        )
        rotateClockwiseItem.image = NSImage(systemSymbolName: "rotate.right", accessibilityDescription: nil)
        rotateClockwiseItem.tag = MenuTag.imageRotateClockwise
        rotateClockwiseItem.makeImagePreferredVisible()
        menu.addItem(rotateClockwiseItem)

        let flipHorizontalItem = NSMenuItem(
            title: "Flip Horizontal",
            action: #selector(flipSelectionHorizontalAction(_:)),
            keyEquivalent: ""
        )
        flipHorizontalItem.image = NSImage(systemSymbolName: "flip.horizontal", accessibilityDescription: nil)
        flipHorizontalItem.tag = MenuTag.imageFlipHorizontal
        flipHorizontalItem.makeImagePreferredVisible()
        menu.addItem(flipHorizontalItem)

        let flipVerticalItem = NSMenuItem(
            title: "Flip Vertical",
            action: #selector(flipSelectionVerticalAction(_:)),
            keyEquivalent: ""
        )
        flipVerticalItem.image = NSImage(
            systemSymbolName: "arrow.trianglehead.up.and.down.righttriangle.up.righttriangle.down",
            accessibilityDescription: nil
        )
        flipVerticalItem.tag = MenuTag.imageFlipVertical
        flipVerticalItem.makeImagePreferredVisible()
        menu.addItem(flipVerticalItem)
        menu.addItem(.separator())

        let applySelectionItem = NSMenuItem(title: "Apply Changes", action: #selector(applySelectionAction(_:)), keyEquivalent: "s")
        applySelectionItem.keyEquivalentModifierMask = .command
        applySelectionItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        applySelectionItem.tag = MenuTag.imageApplySelection
        menu.addItem(applySelectionItem)

        let clearSelectionItem = NSMenuItem(title: "Clear Changes", action: #selector(clearChangesAction(_:)), keyEquivalent: "k")
        clearSelectionItem.keyEquivalentModifierMask = .command
        clearSelectionItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        clearSelectionItem.tag = MenuTag.imageClearSelection
        menu.addItem(clearSelectionItem)

        let refreshSelectionItem = NSMenuItem(title: "Refresh Metadata", action: #selector(refreshSelectionMetadataAction(_:)), keyEquivalent: "R")
        refreshSelectionItem.keyEquivalentModifierMask = [.command, .shift]
        refreshSelectionItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshSelectionItem.tag = MenuTag.imageRefreshSelection
        menu.addItem(refreshSelectionItem)

        let restoreSelectionItem = NSMenuItem(title: "Restore from Backup", action: #selector(restoreFromBackupAction(_:)), keyEquivalent: "b")
        restoreSelectionItem.keyEquivalentModifierMask = .command
        restoreSelectionItem.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle", accessibilityDescription: nil)
        restoreSelectionItem.tag = MenuTag.imageRestoreSelection
        menu.addItem(restoreSelectionItem)

        menu.addItem(.separator())

        let applyPresetItem = NSMenuItem(title: "Apply Preset", action: nil, keyEquivalent: "")
        applyPresetItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        let applySubmenu = NSMenu(title: "Apply Preset")
        if model.presets.isEmpty {
            let noPresetsItem = NSMenuItem(title: "No Presets", action: nil, keyEquivalent: "")
            noPresetsItem.isEnabled = false
            applySubmenu.addItem(noPresetsItem)
        } else {
            for preset in model.presets {
                let item = NSMenuItem(title: preset.name, action: #selector(applyPresetFromMenuAction(_:)), keyEquivalent: "")
                item.representedObject = preset.id.uuidString
                item.tag = MenuTag.imageApplyPreset
                applySubmenu.addItem(item)
            }
        }
        applyPresetItem.submenu = applySubmenu
        menu.addItem(applyPresetItem)

        let savePresetItem = NSMenuItem(title: "Save Metadata as Preset…", action: #selector(saveCurrentAsPresetAction(_:)), keyEquivalent: "")
        savePresetItem.tag = MenuTag.imageSavePreset
        savePresetItem.image = NSImage(systemSymbolName: "square.and.arrow.down.badge.checkmark", accessibilityDescription: nil)
        menu.addItem(savePresetItem)

        let managePresetsItem = NSMenuItem(title: "Manage Presets…", action: #selector(managePresetsAction(_:)), keyEquivalent: "")
        managePresetsItem.tag = MenuTag.imageManagePresets
        managePresetsItem.image = NSImage(systemSymbolName: "slider.horizontal.below.square.filled.and.square", accessibilityDescription: nil)
        menu.addItem(managePresetsItem)

        menu.addItem(.separator())

        let batchRenameSelectionItem = NSMenuItem(
            title: "Batch Rename\u{2026}",
            action: #selector(batchRenameSelectionAction(_:)),
            keyEquivalent: ""
        )
        batchRenameSelectionItem.image = NSImage(systemSymbolName: "pencil.and.list.clipboard", accessibilityDescription: nil)
        batchRenameSelectionItem.tag = MenuTag.imageBatchRenameSelection
        menu.addItem(batchRenameSelectionItem)
    }

    private func rebuildFolderMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let applyFolderItem = NSMenuItem(
            title: "Apply Changes to Folder",
            action: #selector(applyFolderAction(_:)),
            keyEquivalent: "S"
        )
        applyFolderItem.keyEquivalentModifierMask = [.command, .option, .shift]
        applyFolderItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        applyFolderItem.tag = MenuTag.folderApply
        menu.addItem(applyFolderItem)

        let clearFolderItem = NSMenuItem(
            title: "Clear Changes from Folder",
            action: #selector(clearAllChangesAction(_:)),
            keyEquivalent: "k"
        )
        clearFolderItem.keyEquivalentModifierMask = [.command, .option]
        clearFolderItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        clearFolderItem.tag = MenuTag.folderClear
        menu.addItem(clearFolderItem)

        let refreshFolderItem = NSMenuItem(
            title: "Refresh Metadata for Folder",
            action: #selector(refreshAllMetadataAction(_:)),
            keyEquivalent: "r"
        )
        refreshFolderItem.keyEquivalentModifierMask = [.command, .option]
        refreshFolderItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshFolderItem.tag = MenuTag.folderRefresh
        menu.addItem(refreshFolderItem)

        let restoreFolderItem = NSMenuItem(
            title: "Restore from Backup for Folder",
            action: #selector(restoreAllFromBackupAction(_:)),
            keyEquivalent: "b"
        )
        restoreFolderItem.keyEquivalentModifierMask = [.command, .option]
        restoreFolderItem.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle", accessibilityDescription: nil)
        restoreFolderItem.tag = MenuTag.folderRestore
        menu.addItem(restoreFolderItem)

        menu.addItem(.separator())

        let batchRenameFolderItem = NSMenuItem(
            title: "Batch Rename Folder\u{2026}",
            action: #selector(batchRenameFolderAction(_:)),
            keyEquivalent: ""
        )
        batchRenameFolderItem.image = NSImage(systemSymbolName: "pencil.and.list.clipboard", accessibilityDescription: nil)
        batchRenameFolderItem.tag = MenuTag.folderBatchRename
        menu.addItem(batchRenameFolderItem)
    }

    func makeSharedPresetsMenu(model: AppModel) -> NSMenu {
        let menu = NSMenu(title: "Presets")
        menu.autoenablesItems = false
        let hasSelection = !model.selectedFileURLs.isEmpty

        if !model.presets.isEmpty {
            for preset in model.presets {
                let item = NSMenuItem(title: preset.name, action: #selector(applyPresetFromMenuAction(_:)), keyEquivalent: "")
                item.representedObject = preset.id.uuidString
                item.tag = MenuTag.imageApplyPreset
                item.isEnabled = hasSelection
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let saveItem = NSMenuItem(title: "Save Metadata as Preset…", action: #selector(saveCurrentAsPresetAction(_:)), keyEquivalent: "")
        saveItem.tag = MenuTag.imageSavePreset
        saveItem.image = NSImage(systemSymbolName: "square.and.arrow.down.badge.checkmark", accessibilityDescription: nil)
        saveItem.isEnabled = hasSelection
        menu.addItem(saveItem)

        let manageItem = NSMenuItem(title: "Manage Presets…", action: #selector(managePresetsAction(_:)), keyEquivalent: "")
        manageItem.tag = MenuTag.imageManagePresets
        manageItem.image = NSImage(systemSymbolName: "slider.horizontal.below.square.filled.and.square", accessibilityDescription: nil)
        manageItem.isEnabled = true
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
        } else if menu === folderMenuForInjection {
            rebuildFolderMenu(menu)
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
        } else if menuItem.action == #selector(rotateSelectionAnticlockwiseAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(rotateSelectionClockwiseAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(flipSelectionHorizontalAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(flipSelectionVerticalAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(toggleInspectorAction(_:)) {
            menuItem.title = isInspectorCollapsed ? "Show Inspector" : "Hide Inspector"
            return !isEOS1VSelected
        } else if menuItem.action == #selector(togglePathBarAction(_:)) {
            menuItem.title = browserController.isPathBarVisible ? "Hide Path Bar" : "Show Path Bar"
        } else if menuItem.action == #selector(switchToIconAction(_:)) {
            menuItem.state = model.browserViewMode == .icon ? .on : .off
        } else if menuItem.action == #selector(switchToListAction(_:)) {
            menuItem.state = model.browserViewMode == .list ? .on : .off
        } else if menuItem.action == #selector(switchToGalleryAction(_:)) {
            menuItem.state = model.browserViewMode == .gallery ? .on : .off
        } else if menuItem.action == #selector(setIconSubtitleAction(_:)) {
            menuItem.state = model.iconSubtitleColumnID == menuItem.representedObject as? String ? .on : .off
            return model.browserViewMode == .icon
        } else if menuItem.action == #selector(applySelectionAction(_:)) {
            return model.fileActionState(for: .applyMetadataChanges, targetURLs: selection).isEnabled
        } else if menuItem.action == #selector(applyFolderAction(_:)) {
            menuItem.title = "Apply Changes to Folder"
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
            return model.hasAnyRestorableBackup(for: model.browserItems.map(\.url))
        } else if menuItem.action == #selector(saveCurrentAsPresetAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(applyPresetFromMenuAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(adjustDateTimeAction(_:)) {
            return !selection.isEmpty
        } else if menuItem.action == #selector(setLocationAction(_:)) {
            return model.canOpenLocationAdjustSheet()
        } else if menuItem.action == #selector(batchRenameSelectionAction(_:)) {
            return model.fileActionState(for: .batchRenameSelection, targetURLs: Array(model.selectedFileURLs)).isEnabled
        } else if menuItem.action == #selector(batchRenameFolderAction(_:)) {
            return model.fileActionState(for: .batchRenameFolder, targetURLs: model.browserItems.map(\.url)).isEnabled
        } else if menuItem.action == #selector(zoomInAction(_:)) {
            return model.browserViewMode == .icon && model.canIncreaseGalleryZoom
        } else if menuItem.action == #selector(zoomOutAction(_:)) {
            return model.browserViewMode == .icon && model.canDecreaseGalleryZoom
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

}
