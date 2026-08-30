import AppKit

/// A sheet showing one roll's frame list — presented via `presentAsSheet(_:)`
/// from EOS1VShootingViewController, matching the visual/UX chrome of
/// Ledger's other sheets (e.g. ImportSheetView) via AppKit's native sheet
/// presentation rather than a SwiftUI bridge, since the EOS-1V device screen
/// is deliberately pure AppKit throughout.
@MainActor
final class EOS1VFramePreviewViewController: NSViewController {
    private let roll: EOS1VFilmRoll
    private let frameList = EOS1VRowsViewController()

    init(roll: EOS1VFilmRoll) {
        self.roll = roll
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "\(roll.id) · \(roll.frames.count) frames")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(title: "Close", target: self, action: #selector(close))
        closeButton.bezelStyle = .rounded
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let frameView = frameList.view
        frameView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(frameView)
        root.addSubview(closeButton)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            frameView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            frameView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            frameView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            frameView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -12),
            frameView.heightAnchor.constraint(equalToConstant: 360),
            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            closeButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            root.widthAnchor.constraint(equalToConstant: 480),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(frameList)
        frameList.rows = roll.frames.map { frame in
            ("Frame \(frame.frameNumber)", "\(frame.date) \(frame.time) — \(frame.tv) f/\(frame.av) \(frame.focalLength)")
        }
    }

    @objc private func close() {
        dismiss(self)
    }
}
