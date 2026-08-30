import AppKit
import Combine

@MainActor
final class EOS1VDeviceViewController: NSViewController {
    let session: EOS1VSessionController

    private let tabViewController = EOS1VTabViewController()
    private let connectController: EOS1VConnectViewController
    private let personalController: EOS1VPersonalFunctionsViewController
    private let customController: EOS1VCustomFunctionsViewController
    private let shootingController: EOS1VShootingViewController
    private let propertiesController: EOS1VPropertiesViewController
    private var observations: Set<AnyCancellable> = []

    init(session: EOS1VSessionController) {
        self.session = session
        connectController = EOS1VConnectViewController(session: session)
        personalController = EOS1VPersonalFunctionsViewController(session: session)
        customController = EOS1VCustomFunctionsViewController(session: session)
        shootingController = EOS1VShootingViewController(session: session)
        propertiesController = EOS1VPropertiesViewController(session: session)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = EOS1VBackgroundView()
        root.translatesAutoresizingMaskIntoConstraints = false

        // NSTabViewController owns child-view loading/lifecycle/appearance
        // transitions natively — this replaces the hand-written show()/
        // removeFromSuperview()/removeFromParent() dance (and the bugs that
        // came with getting that lifecycle management right by hand).
        tabViewController.tabStyle = .segmentedControlOnTop
        tabViewController.isSwitchingAllowed = { [weak self] index in
            guard let self else { return true }
            return index == 0 || self.session.tabsEnabled
        }
        // Personal/Custom Functions are hidden for now — Ledger's own use is
        // reading shooting data and the camera clock, not the P.Fn/C.Fn
        // settings screens. The controllers themselves are untouched and
        // still kept up to date via refresh() below, so re-adding these two
        // tab items is all reactivating them later takes.
        for (title, controller) in [
            ("Connect", connectController as NSViewController),
            // ("Personal", personalController),
            // ("Custom", customController),
            ("Shooting Data", shootingController),
            ("Date and Time", propertiesController),
        ] {
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            tabViewController.addTabViewItem(item)
        }
        addChild(tabViewController)

        let tabView = tabViewController.view
        tabView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 24),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 48),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -48),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -32),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &observations)
        refresh()
    }

    private func refresh() {
        personalController.refresh()
        customController.refresh()
        shootingController.refresh()
        propertiesController.refresh()

        if !session.tabsEnabled, tabViewController.selectedTabViewItemIndex != 0 {
            tabViewController.selectedTabViewItemIndex = 0
        }
    }
}

/// NSTabViewController's built-in `.segmentedControlOnTop` style doesn't
/// expose a way to grey out an individual segment, so unavailable tabs are
/// vetoed (silently refuse to switch) rather than shown disabled — a real,
/// known visual trade-off versus the old hand-built segmented control, which
/// could grey those segments out directly.
@MainActor
private final class EOS1VTabViewController: NSTabViewController {
    var isSwitchingAllowed: ((Int) -> Bool)?

    override func tabView(_ tabView: NSTabView, shouldSelect tabViewItem: NSTabViewItem?) -> Bool {
        guard let tabViewItem, let index = tabViewItems.firstIndex(of: tabViewItem) else { return true }
        return isSwitchingAllowed?(index) ?? true
    }
}

private final class EOS1VBackgroundView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

@MainActor
private final class EOS1VConnectViewController: NSViewController {
    private let session: EOS1VSessionController
    private let card = NSBox()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDot = NSTextField(labelWithString: "●")
    private let instructions = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "Search", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var observations: Set<AnyCancellable> = []

    init(session: EOS1VSessionController) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        card.boxType = .custom
        card.cornerRadius = 12
        // .controlBackgroundColor is plain white in light mode — indistinguishable
        // from the white canvas behind it, which is why no card was visible at
        // all regardless of the contentView/border fixes below. quaternarySystemFill
        // is AppKit's actual semantic color for "a subtle tinted fill with no
        // border", designed for exactly this card-on-canvas pattern.
        card.fillColor = .quaternarySystemFill
        card.borderWidth = 0
        card.borderColor = .clear
        card.titlePosition = .noTitle
        card.translatesAutoresizingMaskIntoConstraints = false

        let camera = NSImageView()
        camera.image = NSImage(named: "EOS1VBody")
        camera.imageScaling = .scaleProportionallyUpOrDown
        camera.setAccessibilityLabel("Canon EOS-1V camera")
        camera.translatesAutoresizingMaskIntoConstraints = false

        statusTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        statusTitle.translatesAutoresizingMaskIntoConstraints = false
        statusDot.font = .systemFont(ofSize: 17)
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        instructions.font = .systemFont(ofSize: NSFont.systemFontSize)
        instructions.maximumNumberOfLines = 4
        instructions.translatesAutoresizingMaskIntoConstraints = false

        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r"
        actionButton.target = self
        actionButton.action = #selector(performAction(_:))
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        progress.style = .bar
        progress.isIndeterminate = true
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false

        // NSBox.contentView sizes its content via the legacy autoresizing-mask
        // model, which clashes with Auto-Layout-based content — this is the
        // same bug that made the Personal Functions cards render garbled
        // earlier in this session (see EOS1VSettingsControlFactory's
        // groupBoxCard). Adding children directly to `card` instead keeps
        // everything on one layout system.
        for child in [camera, statusTitle, statusDot, instructions, progress, actionButton] {
            card.addSubview(child)
        }
        root.addSubview(card)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.topAnchor),
            card.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            card.widthAnchor.constraint(equalToConstant: 620),
            card.heightAnchor.constraint(equalToConstant: 196),

            camera.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            camera.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            camera.widthAnchor.constraint(equalToConstant: 160),
            camera.heightAnchor.constraint(equalToConstant: 126),

            statusTitle.leadingAnchor.constraint(equalTo: camera.trailingAnchor, constant: 20),
            statusTitle.topAnchor.constraint(equalTo: card.topAnchor, constant: 27),
            statusDot.leadingAnchor.constraint(equalTo: statusTitle.trailingAnchor, constant: 8),
            statusDot.centerYAnchor.constraint(equalTo: statusTitle.centerYAnchor),
            statusDot.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -20),

            instructions.leadingAnchor.constraint(equalTo: statusTitle.leadingAnchor),
            instructions.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            instructions.topAnchor.constraint(equalTo: statusTitle.bottomAnchor, constant: 12),

            progress.leadingAnchor.constraint(equalTo: statusTitle.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            progress.topAnchor.constraint(equalTo: instructions.bottomAnchor, constant: 12),

            actionButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            actionButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &observations)
        refresh()
    }

    private func refresh() {
        progress.isHidden = true
        progress.stopAnimation(nil)
        actionButton.isHidden = false
        actionButton.isEnabled = true

        switch session.state {
        case .cableConnected:
            apply(title: "ES-E1 cable connected", colour: .systemBlue,
                  instructions: "Connect cable to camera and activate PC mode.\nClick search to detect the camera.",
                  button: "Search")
        case .searching:
            apply(title: "Searching for EOS-1V…", colour: .systemOrange,
                  instructions: "Do not disconnect the camera from your computer.", button: "Search")
            showProgress()
            actionButton.isEnabled = false
        case .notFound:
            apply(title: "EOS-1V not found", colour: .systemRed,
                  instructions: "Make sure the camera is in PC mode and the cable is connected.",
                  button: "Search")
        case .connected:
            apply(title: "Connected to EOS-1V", colour: .systemGreen,
                  instructions: "Click Download to download data and settings from the camera.",
                  button: "Download")
        case .downloading:
            apply(title: "Downloading data from EOS-1V…", colour: .systemOrange,
                  instructions: "Do not disconnect the camera from your computer.", button: "Download")
            showProgress()
            actionButton.isEnabled = false
        case let .loaded(films, frames):
            apply(title: "Data loaded from EOS-1V", colour: .systemGreen,
                  instructions: "Camera settings cannot be edited in Ledger. \(films) films and \(frames) frames were downloaded.",
                  button: "Download")
            actionButton.isEnabled = false
        case let .failed(message):
            apply(title: "Download failed", colour: .systemRed,
                  instructions: message, button: "Search")
        }
    }

    private func apply(title: String, colour: NSColor, instructions text: String, button: String) {
        statusTitle.stringValue = title
        statusDot.textColor = colour
        instructions.stringValue = text
        actionButton.title = button
        statusTitle.setAccessibilityLabel(title)
    }

    private func showProgress() {
        progress.isHidden = false
        progress.startAnimation(nil)
    }

    @objc private func performAction(_: Any?) {
        switch session.state {
        case .connected: session.download()
        default: session.search()
        }
    }
}

@MainActor
final class EOS1VRowsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var rows: [(String, String)] = [] {
        didSet { tableView?.reloadData() }
    }

    private var tableView: NSTableView!

    override func loadView() {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .medium
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.headerView = nil
        table.dataSource = self
        table.delegate = self

        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = "Setting"
        name.width = 280
        name.minWidth = 180
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        value.title = "Value"
        value.width = 420
        value.minWidth = 220
        table.addTableColumn(name)
        table.addTableColumn(value)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view = scroll
        tableView = table
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let tableColumn else { return nil }
        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeCell(identifier: identifier)
        cell.textField?.stringValue = identifier.rawValue == "name" ? rows[row].0 : rows[row].1
        cell.textField?.textColor = identifier.rawValue == "name" ? .labelColor : .secondaryLabelColor
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(wrappingLabelWithString: "")
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
