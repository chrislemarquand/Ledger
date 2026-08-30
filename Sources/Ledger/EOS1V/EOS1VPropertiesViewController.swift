import AppKit

/// Properties tab: Information (Camera ID), Recorded Items (the "Shooting
/// Data Items to be Recorded" checkbox list from the manual), and Date and
/// Time — matching the manual's Properties window (pages 87-92). Every
/// control is disabled — Ledger is read-only for now — but laid out and
/// populated exactly as the writable UI would be.
@MainActor
final class EOS1VPropertiesViewController: NSViewController {
    private let session: EOS1VSessionController
    private let tabs: NSSegmentedControl
    private let scroll: NSScrollView
    private let stack: NSStackView

    private static let tabTitles = ["Information", "Recorded Items", "Date and Time"]

    /// Item names whose next-listed sibling is a nested sub-item in the
    /// manual's layout (AF mode → Focusing point achieving focus; Shutter
    /// speed → Bulb exposure time). Presentation-only grouping — the data
    /// itself (`EOS1VRecordedItem`) is a flat list.
    private static let nestingParents: Set<String> = ["AF mode", "Shutter speed"]

    init(session: EOS1VSessionController) {
        self.session = session
        tabs = NSSegmentedControl(labels: Self.tabTitles, trackingMode: .selectOne, target: nil, action: nil)
        (scroll, stack) = EOS1VControlFactory.scrollableForm(rows: [])
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false

        // One persistent scroll view whose content is swapped when the tab
        // changes, rather than prebuilding one per tab and hiding all but
        // one — the hidden ones were never laid out until revealed, which is
        // what forced the earlier viewWillAppear/layoutSubtreeIfNeeded
        // workarounds. There's nothing to work around when there's only
        // ever one view.
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let okRow = EOS1VControlFactory.buttonRow(["OK", "Cancel", "Apply"])
        okRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(tabs)
        root.addSubview(scroll)
        root.addSubview(okRow)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: okRow.topAnchor, constant: -12),
            okRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            okRow.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func refresh() {
        showTab(tabs.selectedSegment)
    }

    private func informationRows() -> [NSView] {
        let modelRow = labeledRow("Model name:", EOS1VControlFactory.disabledField(session.camera?.model ?? "—"))
        let numberRow = labeledRow("User-settable No.:", EOS1VControlFactory.disabledField("—"))
        return [EOS1VControlFactory.sectionLabel("Camera ID"), modelRow, numberRow]
    }

    private func recordedItemsRows() -> [NSView] {
        guard let items = session.recordedItems?.items, !items.isEmpty else {
            return [EOS1VControlFactory.bodyLabel("No recorded-items data available.")]
        }

        var rows: [NSView] = []
        var index = 0
        while index < items.count {
            let item = items[index]
            let title = item.mandatory ? "\(item.name) (mandatory)" : item.name
            let checkbox = EOS1VControlFactory.checkbox(title: title, checked: item.enabled)
            if Self.nestingParents.contains(item.name), index + 1 < items.count {
                let child = items[index + 1]
                let childCheckbox = EOS1VControlFactory.checkbox(title: child.name, checked: child.enabled)
                let stack = NSStackView(views: [checkbox, EOS1VControlFactory.indented(childCheckbox)])
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 4
                rows.append(stack)
                index += 2
            } else {
                rows.append(checkbox)
                index += 1
            }
        }
        return rows
    }

    private func dateTimeRows() -> [NSView] {
        let clock = [session.camera?.clockDate, session.camera?.clockTime].compactMap { $0 }.joined(separator: " ")
        let dateField = EOS1VControlFactory.disabledField(session.camera?.clockDate ?? "—")
        let timeField = EOS1VControlFactory.disabledField(session.camera?.clockTime ?? "—")
        let fieldsRow = NSStackView(views: [dateField, timeField])
        fieldsRow.orientation = .horizontal
        fieldsRow.spacing = 8

        return [
            EOS1VControlFactory.bodyLabel(clock.isEmpty ? "Camera clock unknown." : "Current camera clock: \(clock)"),
            EOS1VControlFactory.radio(title: "Do not change camera date and time settings", selected: true),
            EOS1VControlFactory.radio(title: "Copy computer's date and time settings to camera", selected: false),
            EOS1VControlFactory.radio(title: "Set date and time manually", selected: false),
            EOS1VControlFactory.indented(fieldsRow),
        ]
    }

    private func labeledRow(_ label: String, _ field: NSView) -> NSView {
        let row = NSStackView(views: [EOS1VControlFactory.bodyLabel(label), field])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func tabChanged() {
        showTab(tabs.selectedSegment)
    }

    private func showTab(_ index: Int) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let rows: [NSView]
        switch index {
        case 0: rows = informationRows()
        case 1: rows = recordedItemsRows()
        case 2: rows = dateTimeRows()
        default: rows = []
        }
        for row in rows {
            stack.addArrangedSubview(row)
        }
    }
}
