import AppKit
import SharedUI

@MainActor
final class GeneralSettingsViewController: SettingsGridViewController {
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
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        refreshFromModel()
    }

    override func makeRows() -> [[NSView]] {
        [
            [makeCategoryLabel(title: "Apply:"),   confirmBeforeApplyButton],
            [makeCategoryLabel(title: ""),          autoRefreshAfterApplyButton],
            [makeCategoryLabel(title: "Backups:"),  keepBackupsButton],
            [makeCategoryLabel(title: ""),          clearBackupsButton],
        ]
    }

    private func refreshFromModel() {
        confirmBeforeApplyButton.state = model.confirmBeforeApply ? .on : .off
        autoRefreshAfterApplyButton.state = model.autoRefreshMetadataAfterApply ? .on : .off
        keepBackupsButton.state = model.keepBackups ? .on : .off
    }

    @objc private func confirmBeforeApplyToggled(_ sender: NSButton) {
        model.confirmBeforeApply = (sender.state == .on)
    }

    @objc private func autoRefreshAfterApplyToggled(_ sender: NSButton) {
        model.autoRefreshMetadataAfterApply = (sender.state == .on)
    }

    @objc private func keepBackupsToggled(_ sender: NSButton) {
        model.keepBackups = (sender.state == .on)
    }

    @objc private func clearBackupsAction(_: Any?) {
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
                self.model.statusMessage = "Couldn't clear backups. \(error.localizedDescription)"
            }
        }

        alert.runSheetOrModal(for: view.window, completion: handleResponse)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class InspectorSettingsViewController: NSViewController {
    private unowned let model: AppModel

    private let scrollView = NSScrollView()
    private let contentView = FlippedView()
    private let contentStack = NSStackView()

    private var fieldByButtonID: [ObjectIdentifier: String] = [:]
    private var sectionByButtonID: [ObjectIdentifier: String] = [:]
    private var sectionToggleBySection: [String: NSButton] = [:]
    private var fieldTogglesBySection: [String: [NSButton]] = [:]
    private var sectionForFieldID: [String: String] = [:]

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
        sectionToggleBySection.removeAll()
        fieldTogglesBySection.removeAll()
        sectionForFieldID.removeAll()

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
            sectionToggleBySection[grouped.section] = sectionToggle

            let fieldStack = NSStackView()
            fieldStack.orientation = .vertical
            fieldStack.alignment = .leading
            fieldStack.spacing = 8
            fieldStack.translatesAutoresizingMaskIntoConstraints = false

            var togglesForSection: [NSButton] = []
            for field in grouped.fields {
                let fieldToggle = NSButton(checkboxWithTitle: field.label, target: self, action: #selector(fieldToggled(_:)))
                fieldToggle.state = model.isInspectorFieldEnabled(field.id) ? .on : .off
                fieldToggle.translatesAutoresizingMaskIntoConstraints = false
                fieldByButtonID[ObjectIdentifier(fieldToggle)] = field.id
                sectionForFieldID[field.id] = grouped.section
                togglesForSection.append(fieldToggle)
                fieldStack.addArrangedSubview(fieldToggle)
            }
            fieldTogglesBySection[grouped.section] = togglesForSection

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

    private func recalculateSectionToggleState(for section: String) {
        guard let sectionToggle = sectionToggleBySection[section],
              let toggles = fieldTogglesBySection[section] else { return }
        let enabledCount = toggles.reduce(into: 0) { count, toggle in
            if toggle.state == .on { count += 1 }
        }
        if enabledCount == 0 {
            sectionToggle.state = .off
        } else if enabledCount == toggles.count {
            sectionToggle.state = .on
        } else {
            sectionToggle.state = .mixed
        }
    }

    @objc private func sectionToggled(_ sender: NSButton) {
        guard let section = sectionByButtonID[ObjectIdentifier(sender)] else { return }
        let enable = sender.state != .off
        model.setInspectorSectionEnabled(section: section, isEnabled: enable)
        if let toggles = fieldTogglesBySection[section] {
            for toggle in toggles {
                toggle.state = enable ? .on : .off
            }
        }
        recalculateSectionToggleState(for: section)
    }

    @objc private func fieldToggled(_ sender: NSButton) {
        guard let fieldID = fieldByButtonID[ObjectIdentifier(sender)] else { return }
        model.setInspectorFieldEnabled(fieldID: fieldID, isEnabled: sender.state == .on)
        if let section = sectionForFieldID[fieldID] {
            recalculateSectionToggleState(for: section)
        }
    }
}
