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

@MainActor
final class InspectorSettingsViewController: NSViewController {
    private unowned let model: AppModel
    private var embedded: InspectorFieldSettingsViewController?

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
        let controller = InspectorFieldSettingsViewController(
            sectionsProvider: { [weak self] in
                guard let self else { return [] }
                return self.model.inspectorFieldSections.map { grouped in
                    InspectorFieldSettingsSection(
                        title: grouped.section,
                        fields: grouped.fields.map { field in
                            InspectorFieldSettingsField(id: field.id, label: field.label, isEnabled: field.isEnabled)
                        }
                    )
                }
            },
            onToggleSection: { [weak self] section, isEnabled in
                self?.model.setInspectorSectionEnabled(section: section, isEnabled: isEnabled)
            },
            onToggleField: { [weak self] fieldID, isEnabled in
                self?.model.setInspectorFieldEnabled(fieldID: fieldID, isEnabled: isEnabled)
            }
        )
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        embedded = controller
    }
}
