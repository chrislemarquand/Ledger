import AppKit

/// Personal Functions tab: a parent enable-checkbox per P.Fn, unlocking
/// type-specific children (checkbox list / radio group / range field) built
/// by `parsePersonalFunction`, grouped into category tabs matching the ES-E1
/// Remote manual (page 17). Every control is disabled — Ledger is read-only
/// for now — but laid out and populated exactly as the writable UI would be.
@MainActor
final class EOS1VPersonalFunctionsViewController: NSViewController {
    private let session: EOS1VSessionController
    private let categories: NSSegmentedControl
    private let scroll: NSScrollView
    private let stack: NSStackView

    private static let categoryTitles = ["Exposure", "AF", "Film Transport", "Other"]
    private static let categoryNumbers: [[Int]] = [
        Array(1...11),
        Array(12...18),
        Array(19...22),
        Array(23...30),
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

        let buttons = EOS1VControlFactory.buttonRow(["Load Settings", "Reset"])
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
        settingsByNumber = Dictionary(uniqueKeysWithValues: session.personalSettings.map { ($0.number, $0) })
        showCategory(categories.selectedSegment)
    }

    private func makeRow(for setting: EOS1VSetting) -> NSView {
        let display = parsePersonalFunction(setting)
        let parent = EOS1VControlFactory.checkbox(title: "(\(setting.id)) \(setting.name)", checked: display.isEnabled)

        var rowViews: [NSView] = [parent]
        switch display.kind {
        case .toggleOnly:
            break
        case let .disableList(items):
            let checkboxes = items.map { item in
                EOS1VControlFactory.checkbox(title: "Disables \(item.label)", checked: item.isDisabled)
            }
            let stack = NSStackView(views: checkboxes)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            rowViews.append(EOS1VControlFactory.indented(stack))
        case let .singleChoice(options, selectedIndex):
            let radios = options.map { option in
                EOS1VControlFactory.radio(title: option.label, selected: option.index == selectedIndex)
            }
            let stack = NSStackView(views: radios)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            rowViews.append(EOS1VControlFactory.indented(stack))
        case let .range(description):
            let field = EOS1VControlFactory.disabledField(setting.value)
            field.toolTip = description
            rowViews.append(EOS1VControlFactory.indented(field))
        }

        let row = NSStackView(views: rowViews)
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
