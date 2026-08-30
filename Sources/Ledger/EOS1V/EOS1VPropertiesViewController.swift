import AppKit
import SwiftUI

/// Date and Time tab: a frozen snapshot of the camera's clock against the
/// macOS clock, both as of the moment the camera was last read (see
/// `EOS1VSessionController.cameraClockSnapshotDate`) — not a live comparison.
/// The camera's clock doesn't change between visits to this tab, so neither
/// should the macOS time or difference shown against it; both stay fixed
/// until the next successful connect. The comparison here will also back a
/// future feature to correct exported CSV timestamps against the
/// camera/computer clock drift, but for now it's display only.
///
/// "Change Date and Time…" (`EOS1VSetClockSheetView`,
/// `EOS1VSessionController.writeClock(_:completion:)`, and the `set-clock`
/// addition to eos1v-serial's `machine` interface) is built and wired below
/// but deliberately DISABLED again, 2026-08-30: real-hardware testing hit
/// "camera did not answer the wake" even with the camera freshly in PC
/// mode, and the root cause (Ledger-side timing vs. an eos1v-serial/camera
/// issue vs. a real PC-mode window shorter than the 12-second wake retry)
/// hasn't been isolated yet. All the code is left in place, ready to
/// re-enable (`changeButton.isEnabled = true`, already wired below) once
/// that's diagnosed — see docs/eos1v-set-clock-review-2026-08.md.
@MainActor
final class EOS1VPropertiesViewController: NSViewController {
    private let session: EOS1VSessionController
    private let card = NSBox()
    private let cameraValue = NSTextField(labelWithString: "")
    private let systemValue = NSTextField(labelWithString: "")
    private let differenceValue = NSTextField(labelWithString: "")
    private let changeButton = EOS1VControlFactory.button(title: "Change Date and Time…")

    // Matches eos1v-serial's bcd6()-produced "YYYY-MM-DD"/"HH:MM:SS" strings
    // (EOS1VSessionController.camera?.clockDate/clockTime), combined here.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(session: EOS1VSessionController) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        // Same card styling/position/width as the Connect screen's card —
        // .quaternarySystemFill is AppKit's semantic "subtle tinted fill, no
        // border" color, chosen there after .controlBackgroundColor proved
        // invisible against the white canvas.
        card.boxType = .custom
        card.cornerRadius = 12
        card.fillColor = .quaternarySystemFill
        card.borderWidth = 0
        card.borderColor = .clear
        card.titlePosition = .noTitle
        card.translatesAutoresizingMaskIntoConstraints = false

        let rows = NSStackView(views: [
            makeRow(title: "EOS-1V:", valueField: cameraValue),
            makeRow(title: "macOS:", valueField: systemValue),
            makeRow(title: "Difference:", valueField: differenceValue),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 14
        rows.translatesAutoresizingMaskIntoConstraints = false

        changeButton.translatesAutoresizingMaskIntoConstraints = false
        // Disabled again, 2026-08-30 (see class doc comment) — target/action
        // stay wired so re-enabling is a one-line change once the real-
        // hardware wake failure is diagnosed.
        changeButton.isEnabled = false
        changeButton.target = self
        changeButton.action = #selector(changeDateAndTimeClicked)

        // NSBox.contentView sizes content via the legacy autoresizing-mask
        // model, which clashes with Auto Layout content — added as plain
        // subviews instead, matching the fix already applied elsewhere.
        card.addSubview(rows)
        card.addSubview(changeButton)
        root.addSubview(card)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            card.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            card.widthAnchor.constraint(equalToConstant: 620),
            card.heightAnchor.constraint(equalToConstant: 196),

            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            rows.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            rows.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -24),

            changeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            changeButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Re-render on appearance (e.g. switching back to this tab), but
        // this only re-displays the frozen snapshot below — it never reads
        // Date() itself, so revisiting this tab can't advance the display.
        refresh()
    }

    func refresh() {
        guard let cameraDate = parsedCameraDate(), let snapshotAt = session.cameraClockSnapshotDate else {
            cameraValue.stringValue = "—"
            systemValue.stringValue = "—"
            differenceValue.stringValue = "—"
            return
        }
        cameraValue.stringValue = Self.clockFormatter.string(from: cameraDate)
        systemValue.stringValue = Self.clockFormatter.string(from: snapshotAt)
        differenceValue.stringValue = Self.differenceDescription(from: cameraDate, to: snapshotAt)
    }

    @objc private func changeDateAndTimeClicked() {
        let hostingController = NSHostingController(
            rootView: EOS1VSetClockSheetView(session: session, onDone: { [weak self] in
                self?.dismissSetClockSheet()
            })
        )
        presentAsSheet(hostingController)
    }

    private func dismissSetClockSheet() {
        guard let presented = presentedViewControllers?.first else { return }
        dismiss(presented)
    }

    private func makeRow(title: String, valueField: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        valueField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let row = NSStackView(views: [label, valueField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        return row
    }

    private func parsedCameraDate() -> Date? {
        guard let date = session.camera?.clockDate, let time = session.camera?.clockTime else { return nil }
        return Self.clockFormatter.date(from: "\(date) \(time)")
    }

    private static func differenceDescription(from cameraDate: Date, to systemDate: Date) -> String {
        let totalSeconds = Int(systemDate.timeIntervalSince(cameraDate).rounded())
        if totalSeconds == 0 { return "No difference" }

        let sign = totalSeconds > 0 ? "+" : "-"
        var remaining = abs(totalSeconds)
        let days = remaining / 86400
        remaining %= 86400
        let hours = remaining / 3600
        remaining %= 3600
        let minutes = remaining / 60
        remaining %= 60
        let seconds = remaining

        var parts: [String] = []
        if days > 0 { parts.append(pluralized(days, "day")) }
        if hours > 0 { parts.append(pluralized(hours, "hour")) }
        if minutes > 0 { parts.append(pluralized(minutes, "minute")) }
        if seconds > 0 || parts.isEmpty { parts.append(pluralized(seconds, "second")) }
        return "\(sign)\(parts.joined(separator: " "))"
    }

    private static func pluralized(_ value: Int, _ unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s")"
    }
}
