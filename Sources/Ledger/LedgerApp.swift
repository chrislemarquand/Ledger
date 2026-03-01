import AppKit
import SwiftUI

@main
struct LedgerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                // Settings intentionally hidden for now; fallback to default implementation later.
            }

            CommandGroup(replacing: .appInfo) {
                Button {
                    appDelegate.showAboutPanel()
                } label: {
                    Label("About \(AppBrand.displayName)", systemImage: "info.circle")
                }
            }

            CommandGroup(replacing: .undoRedo) {
                Button {
                    performUndo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)

                Button {
                    performRedo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .keyboardShortcut("Z", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .newItem) {
                Button {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.openFolderAction(_:)), to: nil, from: nil)
                } label: {
                    Label("Open Folder…", systemImage: "folder")
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button {
                    guard let model = appDelegate.appModel else { return }
                    model.performFileAction(.openInDefaultApp, targetURLs: Array(model.selectedFileURLs))
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled({
                    guard let model = appDelegate.appModel else { return true }
                    return !model.fileActionState(for: .openInDefaultApp, targetURLs: Array(model.selectedFileURLs)).isEnabled
                }())

                Menu("Open With") {
                    let apps = availableOpenWithApps()
                    if apps.isEmpty {
                        Text("No Compatible Apps")
                    } else {
                        ForEach(apps) { app in
                            Button(app.name) {
                                openSelection(with: app.url)
                            }
                        }
                    }
                }
                .disabled(appDelegate.appModel?.selectedFileURLs.isEmpty ?? true)

                Button {
                    appDelegate.appModel?.revealSelectionInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(appDelegate.appModel?.selectedFileURLs.isEmpty ?? true)

                Button {
                    appDelegate.appModel?.quickLookSelection()
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(appDelegate.appModel?.selectedFileURLs.isEmpty ?? true)

                Divider()

                Button {
                    appDelegate.appModel?.pinSelectedSidebarLocationToFavorites()
                } label: {
                    Label("Pin Folder to Sidebar", systemImage: "pin")
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!(appDelegate.appModel?.canPinSelectedSidebarLocation ?? false))

                Button {
                    appDelegate.appModel?.unpinSelectedSidebarFavorite()
                } label: {
                    Label("Unpin Folder from Sidebar", systemImage: "pin.slash")
                }
                .disabled(!(appDelegate.appModel?.canUnpinSelectedSidebarLocation ?? false))

                Button {
                    appDelegate.appModel?.moveSelectedFavoriteUp()
                } label: {
                    Label("Move Folder Up in Sidebar", systemImage: "arrow.up")
                }
                .disabled(!(appDelegate.appModel?.canMoveSelectedFavoriteUp ?? false))

                Button {
                    appDelegate.appModel?.moveSelectedFavoriteDown()
                } label: {
                    Label("Move Folder Down in Sidebar", systemImage: "arrow.down")
                }
                .disabled(!(appDelegate.appModel?.canMoveSelectedFavoriteDown ?? false))
            }

            CommandGroup(after: .pasteboard) {
                Button {
                    rotateSelectionLeft()
                } label: {
                    Label("Rotate", systemImage: "rotate.left")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appDelegate.appModel?.selectedFileURLs.isEmpty ?? true)

                Button {
                    flipSelectionHorizontal()
                } label: {
                    Label("Flip", systemImage: "flip.horizontal")
                }
                .keyboardShortcut("F", modifiers: [.command, .shift])
                .disabled(appDelegate.appModel?.selectedFileURLs.isEmpty ?? true)
            }

            CommandGroup(after: .toolbar) {
                Button {
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                Button {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.toggleInspectorAction(_:)), to: nil, from: nil)
                } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

            }

            CommandMenu("Image") {
                Button {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.applySelectionAction(_:)), to: nil, from: nil)
                } label: {
                    let selection = Array(appDelegate.appModel?.selectedFileURLs ?? [])
                    let title = appDelegate.appModel?.applyMetadataSelectionTitle(for: selection) ?? "Apply Metadata Changes to Selection"
                    Label(title, systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled({
                    guard let model = appDelegate.appModel else { return true }
                    return !model.fileActionState(for: .applyMetadataChanges, targetURLs: Array(model.selectedFileURLs)).isEnabled
                }())

                Button {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.refreshSelectionMetadataAction(_:)), to: nil, from: nil)
                } label: {
                    Label("Refresh Metadata for Selection", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
                .disabled(appDelegate.appModel?.selectedFileURLs.isEmpty ?? true)

                Button {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.clearChangesAction(_:)), to: nil, from: nil)
                } label: {
                    Label("Clear Metadata Changes", systemImage: "xmark.circle")
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled({
                    guard let model = appDelegate.appModel else { return true }
                    return !model.fileActionState(for: .clearMetadataChanges, targetURLs: Array(model.selectedFileURLs)).isEnabled
                }())

                Button {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.restoreFromBackupAction(_:)), to: nil, from: nil)
                } label: {
                    Label("Restore from Backup", systemImage: "arrow.uturn.backward.circle")
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled({
                    guard let model = appDelegate.appModel else { return true }
                    return !model.fileActionState(for: .restoreFromLastBackup, targetURLs: Array(model.selectedFileURLs)).isEnabled
                }())

                Divider()

                Button {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.applyFolderAction(_:)), to: nil, from: nil)
                } label: {
                    Label("Apply Metadata Changes to All Images", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("S", modifiers: [.command, .option, .shift])
                .disabled(!(appDelegate.appModel?.canApplyMetadataChanges ?? false))

                Button {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.refreshAllMetadataAction(_:)), to: nil, from: nil)
                } label: {
                    Label("Refresh Metadata for All Images", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled((appDelegate.appModel?.browserItems.isEmpty ?? true))

                Button {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.clearAllChangesAction(_:)), to: nil, from: nil)
                } label: {
                    Label("Clear Metadata Changes from All Images", systemImage: "xmark.circle")
                }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(!(appDelegate.appModel?.canApplyMetadataChanges ?? false))

                Button {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.restoreAllFromBackupAction(_:)), to: nil, from: nil)
                } label: {
                    Label("Restore Metadata from Backup for All Images", systemImage: "arrow.uturn.backward.circle")
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled((appDelegate.appModel?.browserItems.isEmpty ?? true))

                Divider()

                Menu("Presets") {
                    Menu("Apply Preset") {
                        if appDelegate.appModel?.presets.isEmpty ?? true {
                            Text("No Presets")
                        } else {
                            ForEach(appDelegate.appModel?.presets ?? []) { preset in
                                Button {
                                    appDelegate.appModel?.applyPreset(presetID: preset.id)
                                } label: {
                                    Label(preset.name, systemImage: "slider.horizontal.3")
                                }
                                .disabled(appDelegate.appModel?.selectedFileURLs.isEmpty ?? true)
                            }
                        }
                    }

                    Divider()

                    Button {
                        NSApp.sendAction(#selector(NativeThreePaneSplitViewController.saveCurrentAsPresetAction(_:)), to: nil, from: nil)
                    } label: {
                        Label("Save as Preset…", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(appDelegate.appModel?.selectedFileURLs.isEmpty ?? true)

                    Button {
                        NSApp.sendAction(#selector(NativeThreePaneSplitViewController.managePresetsAction(_:)), to: nil, from: nil)
                    } label: {
                        Label("Manage Presets…", systemImage: "slider.horizontal.below.square.filled.and.square")
                    }
                }
            }

            CommandGroup(after: .help) {
                Button {
                    if let url = URL(string: "https://exiftool.org/") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("ExifTool Documentation", systemImage: "link")
                }
            }

        }
    }

    private func performUndo() {
        if let undoManager = NSApp.keyWindow?.firstResponder?.undoManager, undoManager.canUndo {
            undoManager.undo()
            return
        }
        _ = appDelegate.appModel?.undoLastMetadataEdit()
    }

    private func performRedo() {
        if let undoManager = NSApp.keyWindow?.firstResponder?.undoManager, undoManager.canRedo {
            undoManager.redo()
            return
        }
        _ = appDelegate.appModel?.redoLastMetadataEdit()
    }

    private func rotateSelectionLeft() {
        guard let model = appDelegate.appModel else { return }
        let files = Array(model.selectedFileURLs).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }
        for fileURL in files {
            model.rotateLeft(fileURL: fileURL)
        }
    }

    private func rotateSelectionRight() {
        guard let model = appDelegate.appModel else { return }
        let files = Array(model.selectedFileURLs).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }
        for fileURL in files {
            model.rotateLeft(fileURL: fileURL)
            model.rotateLeft(fileURL: fileURL)
            model.rotateLeft(fileURL: fileURL)
        }
    }

    private func flipSelectionHorizontal() {
        guard let model = appDelegate.appModel else { return }
        let files = Array(model.selectedFileURLs).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }
        for fileURL in files {
            model.flipHorizontal(fileURL: fileURL)
        }
    }

    private struct OpenWithApp: Identifiable {
        let url: URL
        let name: String
        var id: String { url.path }
    }

    private func availableOpenWithApps() -> [OpenWithApp] {
        guard let model = appDelegate.appModel,
              let selected = Array(model.selectedFileURLs).sorted(by: { $0.path < $1.path }).first
        else {
            return []
        }

        return NSWorkspace.shared.urlsForApplications(toOpen: selected)
            .map { appURL in
                let fallbackName = appURL.deletingPathExtension().lastPathComponent
                let appName = FileManager.default.displayName(atPath: appURL.path)
                return OpenWithApp(url: appURL, name: appName.isEmpty ? fallbackName : appName)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func openSelection(with applicationURL: URL) {
        guard let model = appDelegate.appModel else { return }
        let files = Array(model.selectedFileURLs).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            files,
            withApplicationAt: applicationURL,
            configuration: config,
            completionHandler: nil
        )
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
        let credits = NSMutableAttributedString(
            string: "\(purpose)\n\nUses ExifTool \(exifToolVersion) by Phil Harvey\n",
            attributes: [
                .font: nativeFont,
                .foregroundColor: nativeColor
            ]
        )
        let linkText = "https://exiftool.org/"
        let linkRange = NSRange(location: credits.length, length: (linkText as NSString).length)
        credits.append(NSAttributedString(
            string: linkText,
            attributes: [
                .font: nativeFont,
                .foregroundColor: nativeColor
            ]
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
        let model = AppModel()
        let windowController = MainWindowController(model: model)
        mainWindowController = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        super.init(window: window)
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
