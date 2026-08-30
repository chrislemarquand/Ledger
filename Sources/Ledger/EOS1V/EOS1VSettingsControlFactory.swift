import AppKit

/// Shared, always-disabled control builders for the EOS-1V settings tabs.
/// Every control here is laid out exactly as the writable ES-E1 UI would be —
/// just `isEnabled = false` — so enabling writes later only means flipping
/// that flag, not redesigning the screen.
enum EOS1VControlFactory {
    static func bodyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }

    static func checkbox(title: String, checked: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = checked ? .on : .off
        button.isEnabled = false
        return button
    }

    static func radio(title: String, selected: Bool) -> NSButton {
        let button = NSButton(radioButtonWithTitle: title, target: nil, action: nil)
        button.state = selected ? .on : .off
        button.isEnabled = false
        return button
    }

    static func popUp(items: [String], selectedIndex: Int?) -> NSPopUpButton {
        let button = NSPopUpButton()
        button.addItems(withTitles: items)
        if let selectedIndex, items.indices.contains(selectedIndex) {
            button.selectItem(at: selectedIndex)
        }
        button.isEnabled = false
        return button
    }

    static func disabledField(_ text: String) -> NSTextField {
        let field = NSTextField(string: text)
        field.isEditable = false
        field.isEnabled = false
        return field
    }

    static func button(title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.isEnabled = false
        return button
    }

    static func indented(_ view: NSView, by amount: CGFloat = 20) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: amount),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    static func buttonRow(_ titles: [String]) -> NSStackView {
        let row = NSStackView(views: titles.map { button(title: $0) })
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// A vertically-scrolling form: a stack of arbitrary rows inside a scroll view.
    static func scrollableForm(rows: [NSView]) -> (scrollView: NSScrollView, stack: NSStackView) {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Flipped so an unscrolled position shows the TOP of the form, not the
        // bottom — a non-flipped document view's origin (0,0) is its bottom-left,
        // so a fresh NSScrollView over one opens scrolled to the bottom.
        let clipView = FlippedView()
        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
        ])

        let scroll = NSScrollView()
        scroll.documentView = clipView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        NSLayoutConstraint.activate([
            clipView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return (scroll, stack)
    }

    /// Wraps a row in a bordered card, matching the Figma design's per-function
    /// group boxes for Personal/Custom Functions.
    ///
    /// Deliberately does NOT use NSBox.contentView: that API sizes its content
    /// via the legacy autoresizing-mask model, which clashes with content that
    /// (like every row here) is itself Auto Layout/NSStackView-based, and
    /// produces exactly the garbled, overlapping, zero-spacing layout this
    /// replaced. Adding `content` as a plain subview with explicit constraints
    /// keeps everything on one layout system.
    static func groupBoxCard(_ content: NSView) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.titlePosition = .noTitle
        box.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
        ])
        return box
    }
}

/// A plain flipped NSView, used as scrollableForm's document view so a fresh
/// scroll position shows the top of the content instead of the bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
