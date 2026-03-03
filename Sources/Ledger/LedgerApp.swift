import AppKit

@MainActor
@main
enum LedgerMain {
    private static var appDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var isShowingTerminateConfirmation = false
    private var allowImmediateTermination = false
    var appModel: AppModel? { mainWindowController?.appModel }

    func showAboutPanel() {
        let bundle = Bundle.main
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? AppBrand.displayName
        let shortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
        let buildVersion = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
        let combinedVersion = "\(shortVersion) (\(buildVersion))"
        let exifToolVersion = bundledExifToolVersion() ?? "Unknown"

        let purpose = "Edit photo metadata — EXIF, IPTC, and XMP — powered by ExifTool."
        let nativeFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let nativeColor = NSColor.secondaryLabelColor
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: nativeFont,
            .foregroundColor: nativeColor,
            .paragraphStyle: centred
        ]
        let credits = NSMutableAttributedString(
            string: "\(purpose)\n\nUses ExifTool \(exifToolVersion) by Phil Harvey\n",
            attributes: baseAttributes
        )
        let linkText = "https://exiftool.org/"
        let linkRange = NSRange(location: credits.length, length: (linkText as NSString).length)
        credits.append(NSAttributedString(
            string: linkText,
            attributes: baseAttributes
        ))
        credits.addAttributes(
            [
                .link: linkText,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ],
            range: linkRange
        )

        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: appName,
            .applicationVersion: combinedVersion,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Chris Le Marquand",
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    func showAboutPanelMenuAction(_: Any?) {
        showAboutPanel()
    }

    private func bundledExifToolVersion() -> String? {
        guard let executablePath = Bundle.main.path(forResource: "exiftool/bin/exiftool", ofType: nil) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-ver"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        } catch {
            return nil
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // If a folder is selected but the browser is empty (e.g. a TCC permission
        // prompt blocked the initial enumeration), retry now that the app is active
        // and the user may have just approved access.
        appModel?.reloadFilesIfBrowserEmpty()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // Belt-and-braces: disable system "Reopen windows when logging back in"
        // behavior for this app so stale restoration metadata is ignored.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        let model = AppModel()
        let windowController = MainWindowController(model: model)
        mainWindowController = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowImmediateTermination {
            allowImmediateTermination = false
            return .terminateNow
        }

        guard let appModel, appModel.hasUnsavedEdits else {
            return .terminateNow
        }

        guard !isShowingTerminateConfirmation else {
            return .terminateCancel
        }
        isShowingTerminateConfirmation = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "You have unsaved changes."
        alert.informativeText = "Do you want to quit and discard your changes?"
        alert.addButton(withTitle: "Quit and Discard")
        alert.addButton(withTitle: "Cancel")

        let keyWindow = NSApp.keyWindow ?? mainWindowController?.window
        if let keyWindow {
            alert.beginSheetModal(for: keyWindow) { [weak self] response in
                guard let self else { return }
                self.isShowingTerminateConfirmation = false
                if response == .alertFirstButtonReturn {
                    self.allowImmediateTermination = true
                    sender.terminate(nil)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let response = alert.runModal()
                self.isShowingTerminateConfirmation = false
                if response == .alertFirstButtonReturn {
                    self.allowImmediateTermination = true
                    sender.terminate(nil)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        return .terminateCancel
    }
}

@MainActor
final class MainWindowController: NSWindowController {
    let appModel: AppModel

    init(model: AppModel) {
        appModel = model
        let contentController = NativeThreePaneSplitViewController(model: model)
        let window = NSWindow(contentViewController: contentController)
        window.setContentSize(NSSize(width: 1320, height: 860))
        window.minSize = NSSize(width: 1200, height: 720)
        window.title = AppBrand.displayName
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.restorationClass = nil
        super.init(window: window)
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
