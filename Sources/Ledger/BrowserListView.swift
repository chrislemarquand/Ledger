@preconcurrency import AppKit
import ExifEditCore
import SharedUI

@MainActor
final class BrowserListViewController: NSViewController, SharedBrowserListHosting {
    private var model: AppModel
    private var items: [AppModel.BrowserItem]

    private let sharedListController: SharedBrowserListViewController
    private var scrollView: NSScrollView { sharedListController.scrollView }
    private var tableView: SharedBrowserListTableView { sharedListController.tableView }

    private var isApplyingProgrammaticSelection = false
    private var lastThumbnailInvalidationToken = UUID()
    private var pendingInvalidatedThumbnailURLs: Set<URL> = []
    private var pendingThumbnailRefreshURLs: Set<URL> = []
    private var isRenderingState = false
    private var lastRenderedItemURLs: [URL] = []
    private var lastRenderedNameSignatures: [RowNameSignature] = []
    private var lastRenderedDetailSignatures: [RowDetailSignature] = []
    private var lastRenderedViewMode: AppModel.BrowserViewMode?
    private var contextMenuTargetURLs: [URL] = []
    private var browserFocusObserver: NSObjectProtocol?
    private var viewModeObserver: NSObjectProtocol?
    private var pendingSelectionAdoptionTask: Task<Void, Never>?

    private struct RowNameSignature: Equatable {
        let url: URL
        let displayName: String
        let isPendingRename: Bool
        let hasPendingEdits: Bool
        let imageOperations: [AppModel.StagedImageOperation]
    }

    private struct RowDetailSignature: Equatable {
        let url: URL
        let values: [String]
    }

    init(model: AppModel, items: [AppModel.BrowserItem]) {
        self.model = model
        self.items = items
        self.lastThumbnailInvalidationToken = model.browserThumbnailInvalidationToken
        self.sharedListController = SharedBrowserListViewController(
            columns: Self.sharedColumns(from: ListColumnDefinition.all),
            persistence: SharedListPersistenceConfig(
                autosaveName: "\(AppBrand.identifierPrefix).BrowserList",
                visibilityDefaultsKey: "\(AppBrand.identifierPrefix).listColumns.visible",
                initialFitDefaultsKey: "\(AppBrand.identifierPrefix).listColumns.initialFitApplied"
            ),
            layoutConfig: SharedListLayoutConfig(
                primaryColumnID: ListColumnDefinition.idName,
                rowHeight: UIMetrics.List.rowHeight,
                hasHorizontalScroller: true
            )
        )
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
        browserFocusObserver = NotificationCenter.default.addObserver(
            forName: .browserDidRequestFocus,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.focusListForKeyboardNavigation()
            }
        }
        viewModeObserver = NotificationCenter.default.addObserver(
            forName: .browserDidSwitchViewMode,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scrollSelectionIntoView()
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        pendingSelectionAdoptionTask?.cancel()
        pendingSelectionAdoptionTask = nil
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        if visibleRows.length > 0 {
            let nameColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            if nameColumn >= 0 {
                let start = max(visibleRows.location, 0)
                let end = min(visibleRows.location + visibleRows.length, tableView.numberOfRows)
                if start < end {
                    for row in start ..< end {
                        (tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: false) as? BrowserListNameCellView)?
                            .cancelThumbnailRequest()
                    }
                }
            }
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
        guard model.browserViewMode == .list else {
            lastRenderedViewMode = model.browserViewMode
            return
        }

        let justBecameActive = lastRenderedViewMode != .list
        lastRenderedViewMode = model.browserViewMode

        if lastThumbnailInvalidationToken != model.browserThumbnailInvalidationToken {
            lastThumbnailInvalidationToken = model.browserThumbnailInvalidationToken
            let invalidated = model.browserThumbnailInvalidatedURLs
            pendingInvalidatedThumbnailURLs = invalidated
            if invalidated.isEmpty {
                ThumbnailPipeline.invalidateAllCachedImages()
                pendingThumbnailRefreshURLs.removeAll()
            } else {
                pendingThumbnailRefreshURLs.formUnion(invalidated)
            }
        }

        let currentURLs = items.map(\.url)
        let detailColumnIDs = visibleDetailColumnIDs()
        let currentNameSignatures = items.map { makeNameSignature(for: $0) }
        let currentDetailSignatures = items.map { makeDetailSignature(for: $0, detailColumnIDs: detailColumnIDs) }

        if hasListChanged(currentURLs) {
            // Clear stale row selection before reloading. NSTableView preserves
            // selection by row index across reloadData(), so a prior row 0 selection
            // survives into the new folder's data. Combined with selectedFileURLs
            // being empty (cleared by clearLoadedContentState), this causes
            // shouldAdoptTableSelectionIntoModel() to return true and call
            // setSelectionFromList() synchronously inside updateNSViewController — B14.
            isApplyingProgrammaticSelection = true
            tableView.selectRowIndexes([], byExtendingSelection: false)
            isApplyingProgrammaticSelection = false
            sharedListController.reloadData()
        } else {
            let rowsNeedingNameReload = IndexSet(items.enumerated().compactMap { index, item in
                if pendingInvalidatedThumbnailURLs.contains(item.url) || pendingThumbnailRefreshURLs.contains(item.url) {
                    return index
                }
                guard index < lastRenderedNameSignatures.count else { return index }
                return currentNameSignatures[index] != lastRenderedNameSignatures[index] ? index : nil
            })
            let rowsNeedingDetailReload = IndexSet(items.indices.compactMap { index in
                guard index < lastRenderedDetailSignatures.count else { return index }
                return currentDetailSignatures[index] != lastRenderedDetailSignatures[index] ? index : nil
            })

            if !rowsNeedingNameReload.isEmpty {
                let nameColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
                if nameColumn >= 0 {
                    tableView.reloadData(forRowIndexes: rowsNeedingNameReload, columnIndexes: IndexSet(integer: nameColumn))
                } else {
                    tableView.reloadData()
                }
            }
            if !rowsNeedingDetailReload.isEmpty && !detailColumnIDs.isEmpty {
                let detailColumnIndexes = IndexSet(detailColumnIDs.compactMap { columnID in
                    let index = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(columnID))
                    return index >= 0 ? index : nil
                })
                if !detailColumnIndexes.isEmpty {
                    tableView.reloadData(forRowIndexes: rowsNeedingDetailReload, columnIndexes: detailColumnIndexes)
                }
            }
        }
        pendingInvalidatedThumbnailURLs = []
        lastRenderedNameSignatures = currentNameSignatures
        lastRenderedDetailSignatures = currentDetailSignatures

        if shouldAdoptTableSelectionIntoModel() {
            let urls = currentTableSelectionURLs()
            if !urls.isEmpty {
                let focusedURL = currentFocusedTableSelectionURL()
                pendingSelectionAdoptionTask?.cancel()
                // Defer out of the SwiftUI update cycle. setSelectionFromList mutates
                // @Published selectedFileURLs which causes B14 when called synchronously
                // from updateNSViewController (inside SwiftUI's render pass).
                pendingSelectionAdoptionTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.pendingSelectionAdoptionTask = nil }
                    guard !Task.isCancelled else { return }
                    guard self.model.selectedFileURLs.isEmpty else { return }
                    guard self.currentTableSelectionURLs() == urls else { return }
                    guard self.currentFocusedTableSelectionURL() == focusedURL else { return }
                    self.model.setSelectionFromList(urls, focusedURL: focusedURL)
                    self.updateQuickLookSourceFrameFromCurrentSelection()
                }
            }
            return
        }

        pendingSelectionAdoptionTask?.cancel()
        pendingSelectionAdoptionTask = nil

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
        syncSortIndicator()
        updateQuickLookSourceFrameFromCurrentSelection()

        if justBecameActive {
            // update() is called from render(), which runs after applyBrowserModeIfNeeded()
            // has already made the list view visible. makeFirstResponder succeeds here
            // because the table view's parent is no longer hidden.
            focusListForKeyboardNavigation()
        }
    }

    private func syncSortIndicator() {
        let expected = NSSortDescriptor(key: model.browserSort.rawValue, ascending: model.browserSortAscending)
        sharedListController.setSortDescriptor(expected)
    }

    private func shouldAdoptTableSelectionIntoModel() -> Bool {
        guard model.selectedFileURLs.isEmpty else { return false }
        guard !tableView.selectedRowIndexes.isEmpty else { return false }
        guard let window = view.window else { return false }
        guard let responderView = window.firstResponder as? NSView else { return false }
        return responderView === tableView || responderView.isDescendant(of: tableView)
    }

    private func currentTableSelectionURLs() -> Set<URL> {
        Set(
            tableView.selectedRowIndexes.compactMap { row -> URL? in
                guard row >= 0, row < items.count else { return nil }
                return items[row].url
            }
        )
    }

    private func currentFocusedTableSelectionURL() -> URL? {
        guard tableView.selectedRow >= 0, tableView.selectedRow < items.count else { return nil }
        return items[tableView.selectedRow].url
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

    private func focusListForKeyboardNavigation() {
        guard model.browserViewMode == .list else { return }
        guard let window = view.window else { return }
        window.makeFirstResponder(tableView)
    }

    func clearVisualSelection() {
        pendingSelectionAdoptionTask?.cancel()
        pendingSelectionAdoptionTask = nil
        isApplyingProgrammaticSelection = true
        tableView.selectRowIndexes([], byExtendingSelection: false)
        isApplyingProgrammaticSelection = false
    }

    private func scrollSelectionIntoView() {
        guard model.browserViewMode == .list else { return }
        guard let primary = model.primarySelectionURL,
              let row = items.firstIndex(where: { $0.url == primary }) else { return }
        tableView.scrollRowToVisible(row)
    }

    private func configureList() {
        sharedListController.host = self
        addChild(sharedListController)
        let sharedView = sharedListController.view
        sharedView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sharedView)
        NSLayoutConstraint.activate([
            sharedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sharedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sharedView.topAnchor.constraint(equalTo: view.topAnchor),
            sharedView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.target = self

        tableView.onActivateSelection = { [weak self] in
            self?.focusInspectorFromBrowser()
        }
        sharedListController.contextMenuProvider = { [weak self] row in
            self?.menuForRow(row)
        }
        sharedListController.setSortDescriptor(
            NSSortDescriptor(key: model.browserSort.rawValue, ascending: model.browserSortAscending)
        )
    }

    private static func sharedColumns(from definitions: [ListColumnDefinition]) -> [SharedListColumnDefinition] {
        let builtInIDs = Set(ListColumnDefinition.builtIn.map(\.id))
        return definitions.map { definition in
            SharedListColumnDefinition(
                id: definition.id,
                title: definition.label,
                defaultWidth: definition.defaultWidth,
                minWidth: definition.minWidth,
                defaultIsVisible: definition.defaultIsVisible,
                isSortable: definition.isSortable,
                isToggleable: definition.id != ListColumnDefinition.idName,
                group: builtInIDs.contains(definition.id) ? .builtIn : .metadata
            )
        }
    }

    func numberOfRows(in controller: SharedBrowserListViewController) -> Int {
        _ = controller
        return items.count
    }

    func sharedBrowserList(
        _ controller: SharedBrowserListViewController,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        _ = controller
        guard row >= 0, row < items.count else { return nil }
        let item = items[row]
        let columnID = tableColumn?.identifier.rawValue ?? ""

        if columnID == "name" {
            let cellID = NSUserInterfaceItemIdentifier("cell-name")
            let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? BrowserListNameCellView)
                ?? BrowserListNameCellView(reuseIdentifier: cellID)
            configureNameCell(cell, for: item)
            return cell
        } else {
            let cellID = NSUserInterfaceItemIdentifier("cell-\(columnID)")
            let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView) ?? {
                let view = NSTableCellView(frame: .zero)
                view.identifier = cellID
                let textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(textField)
                view.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: UIMetrics.List.cellHorizontalInset),
                    textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -UIMetrics.List.cellHorizontalInset),
                    textField.centerYAnchor.constraint(equalTo: view.centerYAnchor)
                ])
                return view
            }()
            cell.textField?.lineBreakMode = .byTruncatingTail
            cell.textField?.stringValue = model.listColumnValue(for: item.url, columnID: columnID, fallbackItem: item)
            return cell
        }
    }

    func sharedBrowserListSelectionDidChange(
        _ controller: SharedBrowserListViewController,
        selectedRows: IndexSet,
        focusedRow: Int?
    ) {
        _ = controller
        pendingSelectionAdoptionTask?.cancel()
        pendingSelectionAdoptionTask = nil
        guard !isApplyingProgrammaticSelection else {
            return
        }

        let urls = Set(
            selectedRows.compactMap { row -> URL? in
                guard row >= 0, row < items.count else { return nil }
                return items[row].url
            }
        )
        let focusedURL: URL?
        if let focusedRow, focusedRow >= 0, focusedRow < items.count {
            focusedURL = items[focusedRow].url
        } else {
            focusedURL = nil
        }
        model.setSelectionFromList(urls, focusedURL: focusedURL)
        updateQuickLookSourceFrameFromCurrentSelection()
    }

    func sharedBrowserListSortDidChange(
        _ controller: SharedBrowserListViewController,
        descriptor: NSSortDescriptor?
    ) {
        _ = controller
        guard let descriptor,
              let sort = AppModel.BrowserSort(rawValue: descriptor.key ?? "") else { return }
        model.browserSort = sort
        model.browserSortAscending = descriptor.ascending
    }

    func sharedBrowserListColumnVisibilityDidChange(
        _ controller: SharedBrowserListViewController,
        columnID _: String,
        isVisible _: Bool
    ) {
        _ = controller
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
        let selectedURLs = model.selectedFileURLs
        let orderedURLs = items.map(\.url)

        if !selectedURLs.contains(clickedURL) {
            model.setSelectionFromList([clickedURL], focusedURL: clickedURL)
            isApplyingProgrammaticSelection = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isApplyingProgrammaticSelection = false
        }
        let targetURLs = ContextMenuSupport.targetSelection(
            clicked: clickedURL,
            selected: selectedURLs,
            orderedItems: orderedURLs
        )
        contextMenuTargetURLs = targetURLs
        let menu = NSMenu()
        menu.autoenablesItems = false
        let openState = model.fileActionState(for: .openInDefaultApp, targetURLs: targetURLs)
        let photosState = model.fileActionState(for: .sendToPhotos, targetURLs: targetURLs)
        let lightroomState = model.fileActionState(for: .sendToLightroom, targetURLs: targetURLs)
        let lightroomClassicState = model.fileActionState(for: .sendToLightroomClassic, targetURLs: targetURLs)
        let refreshState = model.fileActionState(for: .refreshMetadata, targetURLs: targetURLs)
        let applyState = model.fileActionState(for: .applyMetadataChanges, targetURLs: targetURLs)
        let clearState = model.fileActionState(for: .clearMetadataChanges, targetURLs: targetURLs)
        let restoreState = model.fileActionState(for: .restoreFromLastBackup, targetURLs: targetURLs)
        let applyTitle = model.applyMetadataSelectionTitle(for: targetURLs)

        let openItem = ContextMenuSupport.makeMenuItem(
            title: openState.title,
            action: #selector(openFromContextMenu(_:)),
            target: self,
            symbolName: openState.symbolName,
            isEnabled: openState.isEnabled
        )
        menu.addItem(openItem)

        let photosItem = ContextMenuSupport.makeMenuItem(
            title: photosState.title,
            action: #selector(sendToPhotosFromContextMenu(_:)),
            target: self,
            symbolName: photosState.symbolName,
            isEnabled: photosState.isEnabled
        )
        menu.addItem(photosItem)

        let lightroomItem = ContextMenuSupport.makeMenuItem(
            title: lightroomState.title,
            action: #selector(sendToLightroomFromContextMenu(_:)),
            target: self,
            symbolName: lightroomState.symbolName,
            isEnabled: lightroomState.isEnabled
        )
        menu.addItem(lightroomItem)

        let lightroomClassicItem = ContextMenuSupport.makeMenuItem(
            title: lightroomClassicState.title,
            action: #selector(sendToLightroomClassicFromContextMenu(_:)),
            target: self,
            symbolName: lightroomClassicState.symbolName,
            isEnabled: lightroomClassicState.isEnabled
        )
        menu.addItem(lightroomClassicItem)

        let revealItem = ContextMenuSupport.makeMenuItem(
            title: "Reveal in Finder",
            action: #selector(revealInFinderFromContextMenu(_:)),
            target: self,
            symbolName: "folder",
            isEnabled: !targetURLs.isEmpty
        )
        menu.addItem(revealItem)

        menu.addItem(.separator())

        let applyItem = ContextMenuSupport.makeMenuItem(
            title: applyTitle,
            action: #selector(applyFromContextMenu(_:)),
            target: self,
            symbolName: applyState.symbolName,
            isEnabled: applyState.isEnabled
        )
        menu.addItem(applyItem)

        let refreshItem = ContextMenuSupport.makeMenuItem(
            title: refreshState.title,
            action: #selector(refreshFromContextMenu(_:)),
            target: self,
            symbolName: refreshState.symbolName,
            isEnabled: refreshState.isEnabled
        )
        menu.addItem(refreshItem)

        let clearItem = ContextMenuSupport.makeMenuItem(
            title: clearState.title,
            action: #selector(clearFromContextMenu(_:)),
            target: self,
            symbolName: clearState.symbolName,
            isEnabled: clearState.isEnabled
        )
        menu.addItem(clearItem)

        let restoreItem = ContextMenuSupport.makeMenuItem(
            title: restoreState.title,
            action: #selector(restoreFromContextMenu(_:)),
            target: self,
            symbolName: restoreState.symbolName,
            isEnabled: restoreState.isEnabled
        )
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

    private func hasListChanged(_ currentURLs: [URL]) -> Bool {
        guard currentURLs != lastRenderedItemURLs else { return false }
        lastRenderedItemURLs = currentURLs
        return true
    }

    private func visibleDetailColumnIDs() -> [String] {
        tableView.tableColumns
            .map(\.identifier.rawValue)
            .filter { $0 != ListColumnDefinition.idName }
    }

    private func makeNameSignature(for item: AppModel.BrowserItem) -> RowNameSignature {
        RowNameSignature(
            url: item.url,
            displayName: model.listColumnValue(for: item.url, columnID: ListColumnDefinition.idName, fallbackItem: item),
            isPendingRename: model.pendingRenameByFile[item.url] != nil,
            hasPendingEdits: model.hasPendingEdits(for: item.url),
            imageOperations: model.effectiveImageOperations(for: item.url)
        )
    }

    private func makeDetailSignature(
        for item: AppModel.BrowserItem,
        detailColumnIDs: [String]
    ) -> RowDetailSignature {
        RowDetailSignature(
            url: item.url,
            values: detailColumnIDs.map { columnID in
                model.listColumnValue(for: item.url, columnID: columnID, fallbackItem: item)
            }
        )
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
           ) as? BrowserListNameCellView {
            let iconView = nameCell.iconView
            let iconRectInTable = iconView.convert(iconView.bounds, to: tableView)
            let iconRectInWindow = tableView.convert(iconRectInTable, to: nil)
            let iconRectOnScreen = window.convertToScreen(iconRectInWindow)
            model.setQuickLookSourceFrame(for: item.url, rectOnScreen: iconRectOnScreen)
        }
    }

    private func configureNameCell(_ cell: BrowserListNameCellView, for item: AppModel.BrowserItem) {
        cell.textField?.lineBreakMode = .byTruncatingMiddle
        cell.textField?.stringValue = model.listColumnValue(for: item.url, columnID: "name", fallbackItem: item)
        if model.pendingRenameByFile[item.url] != nil {
            cell.textField?.textColor = .systemOrange
        } else {
            cell.textField?.textColor = nil
        }
        cell.applyPending(hasPendingEdits: model.hasPendingEdits(for: item.url))

        let iconView = cell.iconView
        iconView.toolTip = item.url.path
        let isActiveListView = model.browserViewMode == .list

        if isActiveListView, model.selectedFileURLs.contains(item.url), let window = tableView.window {
            let iconRectInTable = iconView.convert(iconView.bounds, to: tableView)
            let iconRectInWindow = tableView.convert(iconRectInTable, to: nil)
            let iconRectOnScreen = window.convertToScreen(iconRectInWindow)
            model.setQuickLookSourceFrame(for: item.url, rectOnScreen: iconRectOnScreen)
        }

        let forceRefresh = pendingThumbnailRefreshURLs.contains(item.url)
        // Skip the image update when reconfiguring a cell that is already showing this URL.
        // Every selection change triggers reloadData across all visible rows. The inspector
        // preview (700 px) overwrites the list thumbnail (64 px) in NSCache, so subsequent
        // calls get a different NSImage object and setImageWithTransition fires a CATransition
        // fade on every row — the flash. Guarding on configuredURL prevents this; configuredURL
        // is reset to nil in prepareForReuse so cell reuse always gets a fresh image update.
        if cell.configuredURL != item.url || forceRefresh {
            if let cached = ThumbnailPipeline.cachedImage(for: item.url, minRenderedSide: 1) {
                iconView.setImageWithTransition(model.displayImageForCurrentStagedState(cached, fileURL: item.url))
            } else {
                iconView.setImageWithTransition(ThumbnailPipeline.fallbackIcon(for: item.url, side: 16))
            }
        }
        cell.configuredURL = item.url
        requestListThumbnail(for: item, in: cell, forceRefresh: forceRefresh)
    }

    private func requestListThumbnail(for item: AppModel.BrowserItem, in cell: BrowserListNameCellView, forceRefresh: Bool) {
        let requiredSide: CGFloat = 64
        cell.iconView.requestThumbnail(
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
}

private final class BrowserListNameCellView: NSTableCellView {
    let pendingDot = NSImageView(frame: .zero)
    let iconView = BrowserListIconView(frame: .zero)
    var configuredURL: URL?

    init(reuseIdentifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = reuseIdentifier
        configureViewHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconView.cancelThumbnailRequest()
        iconView.image = nil
        iconView.toolTip = nil
        configuredURL = nil
    }

    func applyPending(hasPendingEdits: Bool) {
        pendingDot.isHidden = !hasPendingEdits
    }

    func cancelThumbnailRequest() {
        iconView.cancelThumbnailRequest()
    }

    private func configureViewHierarchy() {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        textField = label
        addSubview(label)

        pendingDot.translatesAutoresizingMaskIntoConstraints = false
        pendingDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        pendingDot.contentTintColor = .systemOrange
        addSubview(pendingDot)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        addSubview(iconView)

        NSLayoutConstraint.activate([
            pendingDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UIMetrics.List.cellHorizontalInset),
            pendingDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            pendingDot.widthAnchor.constraint(equalToConstant: UIMetrics.List.pendingDotSize),
            pendingDot.heightAnchor.constraint(equalToConstant: UIMetrics.List.pendingDotSize),

            iconView.leadingAnchor.constraint(equalTo: pendingDot.trailingAnchor, constant: UIMetrics.List.iconGap),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: UIMetrics.List.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: UIMetrics.List.iconSize),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: UIMetrics.List.iconGap),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -UIMetrics.List.cellHorizontalInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

private final class BrowserListIconView: NSImageView {
    private var representedURL: URL?
    private var requestToken = UUID()
    private var requestTask: Task<Void, Never>?

    func cancelThumbnailRequest() {
        requestTask?.cancel()
        requestTask = nil
        requestToken = UUID()
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
           ThumbnailPipeline.cachedImage(for: url, minRenderedSide: requiredSide) != nil {
            return
        }

        cancelThumbnailRequest()
        let token = UUID()
        requestToken = token

        requestTask = Task { [weak self] in
            guard let self else { return }
            let image = await ThumbnailService.request(
                url: url,
                requiredSide: requiredSide,
                forceRefresh: forceRefresh
            )
            guard let image else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.requestToken == token else { return }
                guard self.representedURL == url else { return }
                self.setImageWithTransition(displayTransform(image, url))
                onImageApplied(url)
            }
        }
    }

    func setImageWithTransition(_ nextImage: NSImage?) {
        guard image !== nextImage else { return }
        alphaValue = 1
        image = nextImage
    }
}
