import AppKit

/// Custom Functions tab: one labeled dropdown per C.Fn, grouped into category
/// tabs matching the ES-E1 Remote manual (page 49). Every control is
/// disabled — Ledger is read-only for now — but laid out and populated
/// exactly as the writable UI would be.
@MainActor
final class EOS1VCustomFunctionsViewController: NSViewController {
    private let session: EOS1VSessionController
    private let categories: NSSegmentedControl
    private let scroll: NSScrollView
    private let stack: NSStackView

    // C.Fn category membership, matching the manual's overview page. C.Fn-0
    // is body-level/read-only and hidden here too, matching ES-E1 itself.
    private static let categoryTitles = ["Exposure", "AF", "Film Transport", "Flash", "Other"]
    private static let categoryNumbers: [[Int]] = [
        [3, 5, 6, 9, 16],
        [4, 10, 11, 13, 17, 18],
        [1, 2, 8],
        [14, 15],
        [7, 12, 19],
    ]

    private var settingsByNumber: [Int: EOS1VSetting] = [:]

    init(session: EOS1VSessionController) {
        self.session = session
        categories = NSSegmentedControl(labels: Self.categoryTitles, trackingMode: .selectOne, target: nil, action: nil)
        (scroll, stack) = EOS1VControlFactory.scrollableForm(rows: [])
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        categories.selectedSegment = 0
        categories.target = self
        categories.action = #selector(categoryChanged)
        categories.translatesAutoresizingMaskIntoConstraints = false

        // One persistent scroll view whose content is swapped when the
        // category changes, rather than prebuilding one per category and
        // hiding all but one — the hidden ones were never laid out until
        // revealed, which is what forced the earlier viewWillAppear/
        // layoutSubtreeIfNeeded workarounds. There's nothing to work around
        // when there's only ever one view.
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let buttons = EOS1VControlFactory.buttonRow(["Load Settings", "Copy C.Fn", "Paste C.Fn", "Reset C.Fn"])
        let okRow = EOS1VControlFactory.buttonRow(["OK", "Cancel", "Apply"])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        okRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(categories)
        root.addSubview(scroll)
        root.addSubview(buttons)
        root.addSubview(okRow)
        NSLayoutConstraint.activate([
            categories.topAnchor.constraint(equalTo: root.topAnchor),
            categories.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: categories.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: okRow.topAnchor, constant: -8),
            okRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            okRow.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func refresh() {
        settingsByNumber = Dictionary(uniqueKeysWithValues: session.customSettings.map { ($0.number, $0) })
        showCategory(categories.selectedSegment)
    }

    private func makeRow(for setting: EOS1VSetting) -> NSView {
        let label = EOS1VControlFactory.bodyLabel("(\(setting.id)) \(setting.name)")
        let choiceTitles = (setting.choices ?? []).map { "\($0.value): \($0.label)" }
        let selectedIndex = setting.choices?.firstIndex { setting.value.hasPrefix($0.value + ":") }
        let popUp = EOS1VControlFactory.popUp(items: choiceTitles, selectedIndex: selectedIndex)
        let row = NSStackView(views: [label, popUp])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        return row
    }

    @objc private func categoryChanged() {
        showCategory(categories.selectedSegment)
    }

    private func showCategory(_ index: Int) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard Self.categoryNumbers.indices.contains(index) else { return }
        for number in Self.categoryNumbers[index] {
            guard let setting = settingsByNumber[number] else { continue }
            stack.addArrangedSubview(EOS1VControlFactory.groupBoxCard(makeRow(for: setting)))
        }
    }
}
