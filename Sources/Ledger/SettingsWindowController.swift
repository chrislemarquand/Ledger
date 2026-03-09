import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabsController: SettingsTabViewController
    private let contentWidth: CGFloat = 620

    init(model: AppModel) {
        tabsController = SettingsTabViewController(model: model)
        let window = NSWindow(contentViewController: tabsController)
        window.title = "General"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: contentWidth, height: 100))
        window.minSize = NSSize(width: contentWidth, height: 100)
        window.maxSize = NSSize(width: contentWidth, height: 1200)
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        tabsController.refreshWindowForSelectedTab(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindowAndActivate() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class SettingsTabViewController: NSTabViewController {
    private let generalController: GeneralSettingsViewController
    private let inspectorController: InspectorSettingsViewController

    private let inspectorHeight: CGFloat = 620

    init(model: AppModel) {
        generalController = GeneralSettingsViewController(model: model)
        inspectorController = InspectorSettingsViewController(model: model)
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        generalController.title = "General"
        let generalItem = NSTabViewItem(viewController: generalController)
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")

        inspectorController.title = "Inspector"
        let inspectorItem = NSTabViewItem(viewController: inspectorController)
        inspectorItem.label = "Inspector"
        inspectorItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Inspector")

        addTabViewItem(generalItem)
        addTabViewItem(inspectorItem)
        selectedTabViewItemIndex = 0
        title = "General"
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshWindowForSelectedTab(animated: false)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        refreshWindowForSelectedTab(animated: true)
    }

    func refreshWindowForSelectedTab(animated: Bool) {
        guard let window = view.window else { return }
        let selected = tabViewItems.indices.contains(selectedTabViewItemIndex) ? tabViewItems[selectedTabViewItemIndex] : nil
        let selectedTitle = selected?.label ?? "Settings"
        selected?.viewController?.title = selectedTitle
        title = selectedTitle
        window.title = selectedTitle

        let targetContentHeight: CGFloat
        switch selected?.label {
        case "Inspector":
            targetContentHeight = inspectorHeight
        default:
            if let vc = selected?.viewController {
                vc.view.layoutSubtreeIfNeeded()
                targetContentHeight = vc.view.fittingSize.height
            } else {
                return
            }
        }

        let frame = window.frame
        let currentContentRect = window.contentRect(forFrameRect: frame)
        let chromeHeight = frame.height - currentContentRect.height
        let maxContentHeight = (window.screen?.visibleFrame.height ?? 800) - chromeHeight
        let clampedContentHeight = min(targetContentHeight, maxContentHeight)
        let delta = clampedContentHeight - currentContentRect.height
        guard abs(delta) > 0.5 else { return }

        var targetFrame = frame
        targetFrame.size.height += delta
        targetFrame.origin.y -= delta
        let constrainedFrame = window.constrainFrameRect(targetFrame, to: window.screen)
        window.setFrame(constrainedFrame, display: true, animate: animated)
    }
}

@MainActor
private final class GeneralSettingsViewController: NSViewController {
    private unowned let model: AppModel

    private lazy var confirmBeforeApplyButton = makeCheckbox(
        title: "Confirm before Apply",
        action: #selector(confirmBeforeApplyToggled(_:))
    )

    private lazy var autoRefreshAfterApplyButton = makeCheckbox(
        title: "Auto-refresh metadata after Apply",
        action: #selector(autoRefreshAfterApplyToggled(_:))
    )

    private lazy var keepBackupsButton = makeCheckbox(
        title: "Keep backups",
        action: #selector(keepBackupsToggled(_:))
    )

    private lazy var clearBackupsButton = makeActionButton(
        title: "Clear backups...",
        action: #selector(clearBackupsAction(_:))
    )

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        refreshFromModel()
    }

    private func buildUI() {
        let applyLabel = makeCategoryLabel(title: "Apply:")
        let backupsLabel = makeCategoryLabel(title: "Backups:")
        let blankLabel = makeCategoryLabel(title: "")
        let blankLabel2 = makeCategoryLabel(title: "")

        let grid = NSGridView(views: [
            [applyLabel, confirmBeforeApplyButton],
            [blankLabel, autoRefreshAfterApplyButton],
            [backupsLabel, keepBackupsButton],
            [blankLabel2, clearBackupsButton],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 14
        grid.yPlacement = .center
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        view.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
        ])
    }

    private func makeCheckbox(title: String, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        return button
    }

    private func makeActionButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        return button
    }

    private func makeCategoryLabel(title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.textColor = .labelColor
        return label
    }

    private func refreshFromModel() {
        confirmBeforeApplyButton.state = model.confirmBeforeApply ? .on : .off
        autoRefreshAfterApplyButton.state = model.autoRefreshMetadataAfterApply ? .on : .off
        keepBackupsButton.state = model.keepBackups ? .on : .off
    }

    @objc
    private func confirmBeforeApplyToggled(_ sender: NSButton) {
        model.confirmBeforeApply = (sender.state == .on)
    }

    @objc
    private func autoRefreshAfterApplyToggled(_ sender: NSButton) {
        model.autoRefreshMetadataAfterApply = (sender.state == .on)
    }

    @objc
    private func keepBackupsToggled(_ sender: NSButton) {
        model.keepBackups = (sender.state == .on)
    }

    @objc
    private func clearBackupsAction(_: Any?) {
        let trashName = AppBrand.localizedTrashDisplayName
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move all backups to \(trashName)?"
        alert.informativeText = "This moves all saved backups to \(trashName)."
        let deleteButton = alert.addButton(withTitle: "Move to \(trashName)")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                _ = try self.model.clearAllBackups()
            } catch {
                self.model.statusMessage = "Couldn’t clear backups. \(error.localizedDescription)"
            }
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class InspectorSettingsViewController: NSViewController {
    private unowned let model: AppModel

    private let scrollView = NSScrollView()
    private let contentView = FlippedView()
    private let contentStack = NSStackView()

    private var fieldByButtonID: [ObjectIdentifier: String] = [:]
    private var sectionByButtonID: [ObjectIdentifier: String] = [:]

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        rebuildContent()
    }

    private func buildUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16

        contentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            contentStack.widthAnchor.constraint(equalTo: contentView.widthAnchor, constant: -48),
        ])

        scrollView.documentView = contentView
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func rebuildContent() {
        fieldByButtonID.removeAll()
        sectionByButtonID.removeAll()

        for arranged in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }

        for grouped in model.inspectorFieldSections {
            let sectionToggle = NSButton(checkboxWithTitle: grouped.section, target: self, action: #selector(sectionToggled(_:)))
            sectionToggle.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            sectionToggle.translatesAutoresizingMaskIntoConstraints = false

            let enabledCount = grouped.fields.reduce(into: 0) { partial, field in
                if model.isInspectorFieldEnabled(field.id) { partial += 1 }
            }
            sectionToggle.allowsMixedState = true
            if enabledCount == 0 {
                sectionToggle.state = .off
            } else if enabledCount == grouped.fields.count {
                sectionToggle.state = .on
            } else {
                sectionToggle.state = .mixed
            }

            sectionByButtonID[ObjectIdentifier(sectionToggle)] = grouped.section

            let fieldStack = NSStackView()
            fieldStack.orientation = .vertical
            fieldStack.alignment = .leading
            fieldStack.spacing = 8
            fieldStack.translatesAutoresizingMaskIntoConstraints = false

            for field in grouped.fields {
                let fieldToggle = NSButton(checkboxWithTitle: field.label, target: self, action: #selector(fieldToggled(_:)))
                fieldToggle.state = model.isInspectorFieldEnabled(field.id) ? .on : .off
                fieldToggle.translatesAutoresizingMaskIntoConstraints = false
                fieldByButtonID[ObjectIdentifier(fieldToggle)] = field.id
                fieldStack.addArrangedSubview(fieldToggle)
            }

            let sectionGroup = NSStackView(views: [sectionToggle, fieldStack])
            sectionGroup.orientation = .vertical
            sectionGroup.alignment = .leading
            sectionGroup.spacing = 8
            sectionGroup.translatesAutoresizingMaskIntoConstraints = false
            sectionGroup.setCustomSpacing(6, after: sectionToggle)

            fieldStack.leadingAnchor.constraint(equalTo: sectionGroup.leadingAnchor, constant: 20).isActive = true

            contentStack.addArrangedSubview(sectionGroup)
        }
    }

    @objc
    private func sectionToggled(_ sender: NSButton) {
        guard let section = sectionByButtonID[ObjectIdentifier(sender)] else { return }
        model.setInspectorSectionEnabled(section: section, isEnabled: sender.state != .off)
        rebuildContent()
    }

    @objc
    private func fieldToggled(_ sender: NSButton) {
        guard let fieldID = fieldByButtonID[ObjectIdentifier(sender)] else { return }
        model.setInspectorFieldEnabled(fieldID: fieldID, isEnabled: sender.state == .on)
        rebuildContent()
    }
}
