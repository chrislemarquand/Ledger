import AppKit
import SharedUI

@MainActor
@main
enum LedgerMain {
    // v1.4 Phase 4.1 slice 1: NSApplicationMain loads MainMenu.xib (NSMainNibFile in
    // Config/Ledger-Info.plist) -- which establishes NSApp.mainMenu and connects
    // AppDelegate via the nib's own delegate outlet -- before applicationWillFinishLaunching
    // is even sent, materially earlier than anything reachable from delegate-method code.
    // This replaces a manual NSApplication.shared/app.delegate=/app.run() bootstrap that
    // built the menu bar entirely from inside applicationDidFinishLaunching, which had a
    // measured, intermittent race against the WindowServer's menu-bar-activation handoff
    // (window visible, menu bar still showing only the app name, for up to several
    // seconds) -- not reproducible with nib-loaded menus (confirmed against Photos.app,
    // whose menu appears even while its own window is still a blank loading spinner).
    // AppDelegate needs no code changes: it has no custom init, and nib-instantiated
    // top-level objects loaded via the specific NSMainNibFile pathway are retained
    // automatically by that mechanism -- the same reason every classic Xcode "Cocoa
    // Application" template's App Delegate has never needed an explicit retaining
    // reference anywhere in code. .regular activation policy needs no explicit call
    // either -- it's already the default for a normal app bundle (no LSUIElement/
    // LSBackgroundOnly set).
    static func main() {
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var exifToolConsoleWindowController: ExifToolConsoleWindowController?
    private var updateService: UpdateService?
    private var isShowingTerminateConfirmation = false
    private var allowImmediateTermination = false
    var appModel: AppModel? { mainWindowController?.appModel }

    func showAboutPanel() {
        let exifToolVersion = bundledExifToolVersion() ?? "Unknown"
        presentAboutPanel(
            purpose: "Edit photo metadata — EXIF, IPTC, and XMP — powered by ExifTool.",
            credits: [
                .init(text: "Uses ExifTool \(exifToolVersion) by Phil Harvey", linkURL: "https://exiftool.org/"),
            ],
            copyright: "© 2026 Chris Le Marquand"
        )
    }

    @objc
    func showAboutPanelMenuAction(_: Any?) {
        showAboutPanel()
    }

    func showWelcomeScreen() {
        guard let appModel else { return }
        appModel.activeWelcomePresentation = AppWelcomePresentation(
            appName: AppBrand.displayName,
            features: Self.welcomeFeatures,
            primaryButtonTitle: "Get Started",
            onPrimaryAction: {
                WelcomeCoordinator.markSeen()
            }
        )
    }

    @objc
    func showWhatsNewAction(_: Any?) {
        showWelcomeScreen()
    }

    private static let welcomeFeatures: [AppWelcomeFeature] = [
        .init(
            symbolName: "character.cursor.ibeam",
            title: "Batch Rename",
            subtitle: "Rename folders of files using custom patterns with date, sequence, and metadata tokens."
        ),
        .init(
            symbolName: "star.leadinghalf.filled",
            title: "Expanded Inspector",
            subtitle: "Edit star ratings, flags, colour labels, and a wider range of EXIF and IPTC fields."
        ),
    ]

    @objc
    func showSettingsWindowAction(_: Any?) {
        settingsWindowController?.showWindowAndActivate()
    }

    @objc
    func showExifToolConsoleAction(_: Any?) {
        exifToolConsoleWindowController?.showWindowAndActivate()
    }

    @objc
    func checkForUpdatesAction(_ sender: Any?) {
        updateService?.checkForUpdates(sender)
    }

    private func configureApplicationMenu() {
        let appName = AppBrand.displayName
        let mainMenu = NSApp.mainMenu ?? NSMenu(title: "MainMenu")
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }

        let appMenuItem: NSMenuItem
        if let first = mainMenu.items.first {
            appMenuItem = first
        } else {
            appMenuItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
            mainMenu.insertItem(appMenuItem, at: 0)
        }
        appMenuItem.title = appName
        appMenuItem.submenu = makeStandardAppMenu(
            appName: appName,
            aboutAction: #selector(showAboutPanelMenuAction(_:)),
            settingsAction: #selector(showSettingsWindowAction(_:)),
            checkForUpdatesAction: #selector(checkForUpdatesAction(_:))
        )
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
        let launchState = Signposts.launch.beginInterval("Launch")
        defer { Signposts.launch.endInterval("Launch", launchState) }

        NSWindow.allowsAutomaticWindowTabbing = false
        updateService = UpdateService()
        // v1.4 Phase 4.1 slice 1: the six top-level menus' shells (File/Edit/View/Image/
        // Folder/Help) already exist by this point, loaded from MainMenu.xib before this
        // method was even called — configureApplicationMenu() only needs to replace the
        // App menu's content (mainMenu.items.first), same as before.
        configureApplicationMenu()
        Signposts.launch.emitEvent("MenuReady")
        if !Self.isSparkleAutoupdateDisabled() {
            updateService?.performBackgroundCheck()
        }
        let model = AppModel()
        settingsWindowController = SettingsWindowController(tabs: [
            SettingsTabDescriptor(symbolName: "gearshape", label: "General",
                viewController: GeneralSettingsViewController(model: model)),
            SettingsTabDescriptor(symbolName: "slider.horizontal.3", label: "Inspector",
                viewController: InspectorSettingsViewController(model: model), preferredHeight: 660),
        ])
        exifToolConsoleWindowController = ExifToolConsoleWindowController(model: model)
        let windowController = MainWindowController(model: model)
        mainWindowController = windowController
        // v1.4 Phase 4.1: populate the six menus' real content synchronously here — after
        // every launch-time NSHostingController exists but before the window is shown, so
        // there's no frame where the user could see or click an incomplete menu, and no
        // NSMenu.didBeginTrackingNotification reinjection needed (removed from
        // configureWindowIfNeeded — see its comment).
        let content = windowController.contentController
        content.injectFileMenuIfNeeded()
        content.injectEditMenuIfNeeded()
        content.injectSortMenuIfNeeded()
        content.injectImageMenuIfNeeded()
        content.injectFolderMenuIfNeeded()
        content.injectHelpMenuIfNeeded()
        windowController.showWindow(nil)
        if let openFolderPath = Self.openFolderPathFromLaunchArguments() {
            model.openFolder(at: URL(fileURLWithPath: openFolderPath))
        }
        NSApp.activate(ignoringOtherApps: true)
        if WelcomeCoordinator.shouldShowOnLaunch {
            Task { @MainActor in self.showWelcomeScreen() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Non-interactive folder open for UI tests and benchmarks: `-openFolderPath <path>`
    /// bypasses the NSOpenPanel in `AppModel.openFolder()`, which UI automation cannot
    /// drive reliably. Inert unless the flag is explicitly passed.
    private static func openFolderPathFromLaunchArguments() -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-openFolderPath"), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    /// `-disableSparkleAutoupdate` skips the background update check entirely for UI
    /// tests and benchmarks. Seeding the `SUEnableAutomaticChecks` default was tried
    /// first and does not reliably suppress it — the update window was observed
    /// appearing during UI test runs regardless — so this gates the call in code
    /// instead of hoping Sparkle honors a preference.
    private static func isSparkleAutoupdateDisabled() -> Bool {
        CommandLine.arguments.contains("-disableSparkleAutoupdate")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Dock Menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        var hasItems = false

        if let model = appModel, !model.favoriteItems.isEmpty {
            for item in model.favoriteItems {
                let menuItem = NSMenuItem(title: item.title, action: #selector(openSidebarItemFromDock(_:)), keyEquivalent: "")
                menuItem.representedObject = item.id
                menuItem.target = self
                menu.addItem(menuItem)
            }
            hasItems = true
        }

        if let model = appModel {
            let recents = model.locationItems.prefix(3)
            if !recents.isEmpty {
                if hasItems { menu.addItem(.separator()) }
                for item in recents {
                    let menuItem = NSMenuItem(title: item.title, action: #selector(openSidebarItemFromDock(_:)), keyEquivalent: "")
                    menuItem.representedObject = item.id
                    menuItem.target = self
                    menu.addItem(menuItem)
                }
                hasItems = true
            }
        }

        if hasItems { menu.addItem(.separator()) }
        let openItem = NSMenuItem(title: "Open Folder…", action: #selector(openFolderFromDock(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        return menu
    }

    @objc private func openSidebarItemFromDock(_ sender: NSMenuItem) {
        guard let sidebarID = sender.representedObject as? String,
              let model = appModel else { return }
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.handleExplicitSidebarSelectionChange(to: sidebarID)
    }

    @objc private func openFolderFromDock(_ sender: Any?) {
        mainWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        appModel?.openFolder()
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
        alert.informativeText = "Quit and discard your prepared changes?"
        alert.addButton(withTitle: "Quit and Discard")
        alert.addButton(withTitle: "Cancel")

        let keyWindow = NSApp.keyWindow ?? mainWindowController?.window
        if let keyWindow {
            alert.runSheetOrModal(for: keyWindow) { [weak self] response in
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
                alert.runSheetOrModal(for: nil) { response in
                    self.isShowingTerminateConfirmation = false
                    if response == .alertFirstButtonReturn {
                        self.allowImmediateTermination = true
                        sender.terminate(nil)
                    } else {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
        }
        return .terminateCancel
    }
}

private struct AboutCredit {
    let text: String
    let linkURL: String?
}

@MainActor
private func presentAboutPanel(
    purpose: String,
    credits: [AboutCredit] = [],
    copyright: String? = nil
) {
    let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    let color = NSColor.secondaryLabelColor
    let centered = NSMutableParagraphStyle()
    centered.alignment = .center
    let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: centered,
    ]

    let body = NSMutableAttributedString(string: purpose, attributes: baseAttributes)
    for credit in credits {
        body.append(NSAttributedString(string: "\n\n\(credit.text)", attributes: baseAttributes))
        if let linkURL = credit.linkURL {
            body.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            let range = NSRange(location: body.length, length: (linkURL as NSString).length)
            body.append(NSAttributedString(string: linkURL, attributes: baseAttributes))
            body.addAttributes(
                [
                    .link: linkURL,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ],
                range: range
            )
        }
    }

    let bundle = Bundle.main
    let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? ProcessInfo.processInfo.processName
    let shortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"

    var options: [NSApplication.AboutPanelOptionKey: Any] = [
        .applicationName: appName,
        .applicationVersion: shortVersion,
        .credits: body,
    ]
    if let copyright {
        options[NSApplication.AboutPanelOptionKey(rawValue: "Copyright")] = copyright
    }

    NSApp.orderFrontStandardAboutPanel(options: options)
    NSApp.activate(ignoringOtherApps: true)
}

@MainActor
final class MainWindowController: NSWindowController {
    let appModel: AppModel
    // v1.4 Phase 4.1: exposed so AppDelegate can populate the top-level menus' real content
    // synchronously right after construction, before the window is ever shown — see
    // applicationDidFinishLaunching.
    let contentController: NativeThreePaneSplitViewController
    private var framePersistenceController: WindowFramePersistenceController?

    init(model: AppModel) {
        appModel = model
        let contentController = NativeThreePaneSplitViewController(model: model)
        self.contentController = contentController
        let window = NSWindow(contentViewController: contentController)
        window.title = AppBrand.displayName
        window.isReleasedWhenClosed = false
        window.isRestorable = true
        configureWindowForToolbar(window)
        let frameAutosaveName = "\(AppBrand.identifierPrefix).MainWindow"
        super.init(window: window)
        framePersistenceController = WindowFramePersistenceController(
            window: window,
            autosaveName: frameAutosaveName,
            minSize: ThreePaneSplitViewController.Metrics.windowMinimum,
            defaultContentSize: ThreePaneSplitViewController.Metrics.windowDefault
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
