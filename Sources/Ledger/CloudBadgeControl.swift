import AppKit

/// Icon + native spinner control for iCloud download state, reused by both the gallery
/// thumbnail overlay and the list "cloud status" column. Hidden entirely for `.local`.
/// Click starts a download for `.notDownloaded`; while `.downloading` the icon is replaced
/// by a system `NSProgressIndicator` spinner, matching Finder — no custom animation.
@MainActor
final class CloudBadgeControl: NSView {
    var onTap: (() -> Void)?

    private let iconView = NSImageView(frame: .zero)
    private let spinner = NSProgressIndicator(frame: .zero)
    private var state: CloudFileState = .local

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViewHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureViewHierarchy() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "Download from iCloud")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .secondaryLabelColor
        addSubview(iconView)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalTo: widthAnchor),
            spinner.heightAnchor.constraint(equalTo: heightAnchor)
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleClick)))
        applyState()
    }

    /// Tint for the idle cloud icon. Callers on a plain background (list rows) should use the
    /// default `.secondaryLabelColor`; callers overlaying a photo thumbnail (gallery) should
    /// use `.white` for legibility.
    func setIconTintColor(_ color: NSColor) {
        iconView.contentTintColor = color
    }

    func configure(state: CloudFileState) {
        guard self.state != state else { return }
        self.state = state
        applyState()
    }

    private func applyState() {
        switch state {
        case .local:
            isHidden = true
            spinner.stopAnimation(nil)
        case .notDownloaded:
            isHidden = false
            iconView.isHidden = false
            spinner.stopAnimation(nil)
        case .downloading:
            isHidden = false
            iconView.isHidden = true
            spinner.startAnimation(nil)
        }
    }

    @objc
    private func handleClick() {
        guard state == .notDownloaded else { return }
        onTap?()
    }
}
