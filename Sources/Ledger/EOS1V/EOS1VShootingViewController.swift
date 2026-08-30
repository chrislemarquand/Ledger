import AppKit
import UniformTypeIdentifiers

/// Shooting tab: a flat, multi-select roll table (matching the Figma design)
/// with Preview/Delete/Export actions. Delete is local-only — it hides a
/// roll via EOS1VSessionController's tombstone store, never touches the
/// camera or the downloaded files (see EOS1VDeletedRollsStore).
@MainActor
final class EOS1VShootingViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let session: EOS1VSessionController
    private var rollTable: NSTableView!
    private let showDeletedCheckbox = NSButton(checkboxWithTitle: "Show Deleted", target: nil, action: nil)
    private let previewButton = NSButton(title: "Preview…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private var visibleRolls: [EOS1VFilmRoll] = []

    private static let columns: [(identifier: String, title: String, width: CGFloat)] = [
        ("filmID", "Film ID", 100),
        ("loadedDate", "Loaded Date", 110),
        ("loadedTime", "Loaded Time", 110),
        ("frameCount", "Frames", 70),
        ("isoDX", "ISO (DX)", 80),
    ]

    init(session: EOS1VSessionController) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        for column in Self.columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
            tableColumn.title = column.title
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        rollTable = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        showDeletedCheckbox.target = self
        showDeletedCheckbox.action = #selector(showDeletedChanged)
        showDeletedCheckbox.translatesAutoresizingMaskIntoConstraints = false

        for button in [previewButton, deleteButton, exportButton] {
            button.bezelStyle = .rounded
            button.isEnabled = false
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        previewButton.target = self
        previewButton.action = #selector(previewSelectedRoll)
        deleteButton.target = self
        deleteButton.action = #selector(deleteOrRestoreSelectedRolls)
        exportButton.target = self
        exportButton.action = #selector(exportSelectedRolls)

        let buttonRow = NSStackView(views: [previewButton, deleteButton, exportButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(showDeletedCheckbox)
        root.addSubview(scroll)
        root.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            showDeletedCheckbox.topAnchor.constraint(equalTo: root.topAnchor),
            showDeletedCheckbox.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: showDeletedCheckbox.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),
            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func refresh() {
        // EOS1VDeviceViewController calls refresh() on every tab unconditionally,
        // including tabs the user hasn't switched to yet — force the view (and
        // therefore rollTable) to exist before touching it.
        loadViewIfNeeded()
        rebuildVisibleRolls()
    }

    private func rebuildVisibleRolls() {
        let showDeleted = showDeletedCheckbox.state == .on
        visibleRolls = session.filmRolls.filter { showDeleted || !session.deletedRollIDs.contains($0.id) }
        rollTable.reloadData()
        updateButtonStates()
    }

    func numberOfRows(in _: NSTableView) -> Int { visibleRolls.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleRolls.indices.contains(row), let tableColumn else { return nil }
        let roll = visibleRolls[row]
        let isDeleted = session.deletedRollIDs.contains(roll.id)
        let text: String
        switch tableColumn.identifier.rawValue {
        case "filmID": text = roll.id
        case "loadedDate": text = roll.loadedDate
        case "loadedTime": text = roll.loadedTime
        case "frameCount": text = "\(roll.frames.count)"
        case "isoDX": text = roll.frames.first?.isoDX ?? ""
        default: text = ""
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: isDeleted ? "\(text) (deleted)" : text)
        label.textColor = isDeleted ? .disabledControlTextColor : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
        updateButtonStates()
    }

    private func updateButtonStates() {
        let selected = selectedRolls
        previewButton.isEnabled = selected.count == 1
        exportButton.isEnabled = !selected.isEmpty
        deleteButton.isEnabled = !selected.isEmpty
        deleteButton.title = selected.allSatisfy { session.deletedRollIDs.contains($0.id) } && !selected.isEmpty
            ? "Restore" : "Delete…"
    }

    private var selectedRolls: [EOS1VFilmRoll] {
        rollTable.selectedRowIndexes.compactMap { visibleRolls.indices.contains($0) ? visibleRolls[$0] : nil }
    }

    @objc private func showDeletedChanged() {
        rebuildVisibleRolls()
    }

    @objc private func previewSelectedRoll() {
        guard let roll = selectedRolls.first else { return }
        presentAsSheet(EOS1VFramePreviewViewController(roll: roll))
    }

    @objc private func deleteOrRestoreSelectedRolls() {
        let selected = selectedRolls
        guard !selected.isEmpty else { return }
        let restoring = deleteButton.title == "Restore"
        for roll in selected {
            if restoring {
                session.restoreRoll(roll.id)
            } else {
                session.markRollDeleted(roll.id)
            }
        }
        rebuildVisibleRolls()
    }

    @objc private func exportSelectedRolls() {
        let selected = selectedRolls
        guard !selected.isEmpty, let window = view.window else { return }
        let recordedItemNames = Set(
            (session.recordedItems?.items ?? []).filter(\.enabled).map(\.name)
        )
        if selected.count == 1, let roll = selected.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(roll.id).csv"
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                try? EOS1VRollCSVExporter.canonCSV(for: roll, recordedItemNames: recordedItemNames).write(to: url)
            }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let directory = panel.url else { return }
            for roll in selected {
                let url = directory.appendingPathComponent("\(roll.id).csv")
                try? EOS1VRollCSVExporter.canonCSV(for: roll, recordedItemNames: recordedItemNames).write(to: url)
            }
        }
    }
}
