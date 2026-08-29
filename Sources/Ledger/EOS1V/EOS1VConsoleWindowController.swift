import AppKit
import SwiftUI

/// Standalone auxiliary window for the EOS-1V read-only tool console. Same lifecycle as
/// `ExifToolConsoleWindowController` — created once and kept alive for the app's lifetime,
/// brought to front on repeat invocation rather than recreated.
@MainActor
final class EOS1VConsoleWindowController: NSWindowController {
    init() {
        let hostingController = NSHostingController(rootView: EOS1VConsoleView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "EOS-1V Console"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 560))
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("\(AppBrand.identifierPrefix).EOS1VConsoleWindow")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showWindowAndActivate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
