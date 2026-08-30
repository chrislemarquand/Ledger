import AppKit
import SwiftUI
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
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
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
        // Not using usesAlternatingRowBackgroundColors: that flag stripes the
        // table view's entire frame/clip height, including empty space below
        // the last real row, rather than stopping at the actual row count.
        // Striping colors are applied manually per real row in
        // tableView(_:didAdd:forRow:) instead, so the banding stops exactly
        // where the data does.
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(previewSelectedRoll)
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

        // Preview…/Show Deleted form a left-aligned leading cluster; Delete…/
        // Export… form a right-aligned trailing cluster, both on one row.
        let leadingRow = NSStackView(views: [previewButton, showDeletedCheckbox])
        leadingRow.orientation = .horizontal
        leadingRow.alignment = .centerY
        leadingRow.spacing = 12
        leadingRow.translatesAutoresizingMaskIntoConstraints = false

        let trailingRow = NSStackView(views: [deleteButton, exportButton])
        trailingRow.orientation = .horizontal
        trailingRow.alignment = .centerY
        trailingRow.spacing = 8
        trailingRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scroll)
        root.addSubview(leadingRow)
        root.addSubview(trailingRow)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: leadingRow.topAnchor, constant: -12),
            leadingRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            leadingRow.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            trailingRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            trailingRow.centerYAnchor.constraint(equalTo: leadingRow.centerYAnchor),
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
        let label = NSTextField(labelWithString: text)
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

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        let colors = NSColor.alternatingContentBackgroundColors
        rowView.backgroundColor = colors[row % colors.count]
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
            ? "Restore" : "Delete"
    }

    private var selectedRolls: [EOS1VFilmRoll] {
        rollTable.selectedRowIndexes.compactMap { visibleRolls.indices.contains($0) ? visibleRolls[$0] : nil }
    }

    @objc private func showDeletedChanged() {
        rebuildVisibleRolls()
    }

    @objc private func previewSelectedRoll() {
        guard let roll = selectedRolls.first else { return }
        let hostingController = NSHostingController(
            rootView: EOS1VRollDetailSheetView(roll: roll, onDone: { [weak self] in
                self?.dismissRollDetailSheet()
            })
        )
        presentAsSheet(hostingController)
    }

    private func dismissRollDetailSheet() {
        guard let presented = presentedViewControllers?.first else { return }
        dismiss(presented)
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
