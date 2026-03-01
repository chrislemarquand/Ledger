@preconcurrency import AppKit
import ExifEditCore
import SwiftUI

struct BrowserListView: View {
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
    private var isApplyingProgrammaticSort = false
    private var lastThumbnailInvalidationToken = UUID()
    private var pendingInvalidatedThumbnailURLs: Set<URL> = []
    private var isRenderingState = false
    private var lastRenderedItemURLs: [URL] = []
    private var contextMenuTargetURLs: [URL] = []
    private var didApplyInitialColumnFit = false
    private var browserFocusObserver: NSObjectProtocol?
    private var viewModeObserver: NSObjectProtocol?
    private var thumbnailUpdateObserver: NSObjectProtocol?

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
        viewModeObserver = NotificationCenter.default.addObserver(
            forName: .browserDidSwitchViewMode,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scrollSelectionIntoView()
            }
        }
        thumbnailUpdateObserver = NotificationCenter.default.addObserver(
            forName: .thumbnailCoordinatorDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let url = note.userInfo?["url"] as? URL
            else { return }
            Task { @MainActor [weak self] in
                self?.reloadThumbnailRow(for: url)
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let browserFocusObserver {
            NotificationCenter.default.removeObserver(browserFocusObserver)
            self.browserFocusObserver = nil
        }
        if let viewModeObserver {
            NotificationCenter.default.removeObserver(viewModeObserver)
            self.viewModeObserver = nil
        }
        if let thumbnailUpdateObserver {
            NotificationCenter.default.removeObserver(thumbnailUpdateObserver)
            self.thumbnailUpdateObserver = nil
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
                ThumbnailCoordinator.shared.invalidateAll()
            } else {
                ThumbnailCoordinator.shared.invalidate(urls: invalidated)
            }
        }

        syncTableWidthToViewportIfNeeded()
        applyInitialColumnFitIfNeeded()
        updateListPresentationState(hasItems: !items.isEmpty)
        if hasListChanged() {
            // Clear stale row selection before reloading. NSTableView preserves
            // selection by row index across reloadData(), so a prior row 0 selection
            // survives into the new folder's data. Combined with selectedFileURLs
            // being empty (cleared by clearLoadedContentState), this causes
            // shouldAdoptTableSelectionIntoModel() to return true and call
            // setSelectionFromList() synchronously inside updateNSViewController — B14.
            isApplyingProgrammaticSelection = true
            tableView.selectRowIndexes([], byExtendingSelection: false)
            isApplyingProgrammaticSelection = false
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
                // Defer out of the SwiftUI update cycle. setSelectionFromList mutates
                // @Published selectedFileURLs which causes B14 when called synchronously
                // from updateNSViewController (inside SwiftUI's render pass).
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.model.setSelectionFromList(urls, focusedURL: focusedURL)
                    self.updateQuickLookSourceFrameFromCurrentSelection()
                }
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
        syncSortIndicator()
        updateQuickLookSourceFrameFromCurrentSelection()
        prefetchVisibleNeighborhood()
    }

    private func syncSortIndicator() {
        let expected = NSSortDescriptor(key: model.browserSort.rawValue, ascending: model.browserSortAscending)
        guard tableView.sortDescriptors.first != expected else { return }
        isApplyingProgrammaticSort = true
        tableView.sortDescriptors = [expected]
        isApplyingProgrammaticSort = false
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

    private func scrollSelectionIntoView() {
        guard model.browserViewMode == .list else { return }
        guard let primary = model.primarySelectionURL,
              let row = items.firstIndex(where: { $0.url == primary }) else { return }
        tableView.scrollRowToVisible(row)
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
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: AppModel.BrowserSort.name.rawValue, ascending: true)

        let createdColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("created"))
        createdColumn.title = "Date Created"
        createdColumn.minWidth = 84
        createdColumn.width = 160
        createdColumn.resizingMask = .userResizingMask
        createdColumn.sortDescriptorPrototype = NSSortDescriptor(key: AppModel.BrowserSort.created.rawValue, ascending: true)

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Size"
        sizeColumn.minWidth = 64
        sizeColumn.width = 90
        sizeColumn.resizingMask = .userResizingMask
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: AppModel.BrowserSort.size.rawValue, ascending: true)

        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kindColumn.title = "Kind"
        kindColumn.minWidth = 84
        kindColumn.width = 120
        kindColumn.resizingMask = .userResizingMask
        kindColumn.sortDescriptorPrototype = NSSortDescriptor(key: AppModel.BrowserSort.kind.rawValue, ascending: true)

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(createdColumn)
        tableView.addTableColumn(sizeColumn)
        tableView.addTableColumn(kindColumn)

        // Set initial sort indicator to match persisted model state.
        tableView.sortDescriptors = [NSSortDescriptor(key: model.browserSort.rawValue, ascending: model.browserSortAscending)]

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
                let pendingDot = NSImageView(frame: .zero)
                pendingDot.identifier = NSUserInterfaceItemIdentifier("pending-dot")
                pendingDot.translatesAutoresizingMaskIntoConstraints = false
                pendingDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
                pendingDot.contentTintColor = .systemOrange
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

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
        guard !isApplyingProgrammaticSort else { return }
        guard let descriptor = tableView.sortDescriptors.first,
              let sort = AppModel.BrowserSort(rawValue: descriptor.key ?? "") else { return }
        model.browserSort = sort
        model.browserSortAscending = descriptor.ascending
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
        let applyTitle = model.applyMetadataSelectionTitle(for: targetURLs)

        func makeItem(title: String, action: Selector, symbolName: String, isEnabled: Bool) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = isEnabled
            item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            return item
        }

        let openItem = makeItem(
            title: openState.title,
            action: #selector(openFromContextMenu(_:)),
            symbolName: openState.symbolName,
            isEnabled: openState.isEnabled
        )
        menu.addItem(openItem)

        let revealItem = makeItem(
            title: "Reveal in Finder",
            action: #selector(revealInFinderFromContextMenu(_:)),
            symbolName: "folder",
            isEnabled: !targetURLs.isEmpty
        )
        menu.addItem(revealItem)

        menu.addItem(.separator())

        let applyItem = makeItem(
            title: applyTitle,
            action: #selector(applyFromContextMenu(_:)),
            symbolName: applyState.symbolName,
            isEnabled: applyState.isEnabled
        )
        menu.addItem(applyItem)

        let refreshItem = makeItem(
            title: refreshState.title,
            action: #selector(refreshFromContextMenu(_:)),
            symbolName: refreshState.symbolName,
            isEnabled: refreshState.isEnabled
        )
        menu.addItem(refreshItem)

        let clearItem = makeItem(
            title: clearState.title,
            action: #selector(clearFromContextMenu(_:)),
            symbolName: clearState.symbolName,
            isEnabled: clearState.isEnabled
        )
        menu.addItem(clearItem)

        let restoreItem = makeItem(
            title: restoreState.title,
            action: #selector(restoreFromContextMenu(_:)),
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
            requestListThumbnailIfNeeded(for: item, forceRefresh: false)
            return
        }

        iconView.image = ThumbnailPipeline.fallbackIcon(for: item.url, side: 16)

        requestListThumbnailIfNeeded(for: item, forceRefresh: false)
    }

    private func requestListThumbnailIfNeeded(for item: AppModel.BrowserItem, forceRefresh: Bool) {
        let requiredSide: CGFloat = 64
        ThumbnailCoordinator.shared.ensureThumbnail(
            url: item.url,
            targetSide: requiredSide,
            policy: .list,
            forceRefresh: forceRefresh
        )
    }

    private func reloadThumbnailRow(for url: URL) {
        guard let row = items.firstIndex(where: { $0.url == url }) else { return }
        let nameColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard nameColumn >= 0 else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: nameColumn)
        )
    }

    private func prefetchVisibleNeighborhood() {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.length > 0 else { return }
        let minVisible = max(0, visibleRows.location)
        let maxVisible = min(items.count - 1, visibleRows.location + visibleRows.length - 1)
        guard minVisible <= maxVisible else { return }
        let prefetchLower = max(0, minVisible - 10)
        let prefetchUpper = min(items.count - 1, maxVisible + 20)
        guard prefetchLower <= prefetchUpper else { return }
        let visibleSet = Set(minVisible...maxVisible)
        let prefetchURLs = (prefetchLower...prefetchUpper).compactMap { index -> URL? in
            guard !visibleSet.contains(index) else { return nil }
            return items[index].url
        }
        guard !prefetchURLs.isEmpty else { return }
        ThumbnailCoordinator.shared.prefetch(
            urls: prefetchURLs,
            targetSide: 64,
            policy: .list
        )
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
