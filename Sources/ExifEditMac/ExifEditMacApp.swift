import AppKit
import SwiftUI

@main
struct ExifEditMacApp: App {
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
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button {
                    guard let model = appDelegate.appModel else { return }
                    model.performFileAction(.openInDefaultApp, targetURLs: Array(model.selectedFileURLs))
                } label: {
                    let state = appDelegate.appModel?.fileActionState(for: .openInDefaultApp, targetURLs: Array(appDelegate.appModel?.selectedFileURLs ?? []))
                    Label(state?.title ?? "Open in Default App", systemImage: state?.symbolName ?? "arrow.up.forward.app")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled({
                    guard let model = appDelegate.appModel else { return true }
                    return !model.fileActionState(for: .openInDefaultApp, targetURLs: Array(model.selectedFileURLs)).isEnabled
                }())

                Button {
                    appDelegate.appModel?.revealSelectionInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(appDelegate.appModel?.selectedFileURLs.isEmpty ?? true)

                Divider()

                Button {
                    guard let model = appDelegate.appModel else { return }
                    model.performFileAction(.restoreFromLastBackup, targetURLs: Array(model.selectedFileURLs))
                } label: {
                    let state = appDelegate.appModel?.fileActionState(for: .restoreFromLastBackup, targetURLs: Array(appDelegate.appModel?.selectedFileURLs ?? []))
                    Label(state?.title ?? "Restore from Last Backup", systemImage: state?.symbolName ?? "arrow.uturn.backward.circle")
                }
                .disabled({
                    guard let model = appDelegate.appModel else { return true }
                    return !model.fileActionState(for: .restoreFromLastBackup, targetURLs: Array(model.selectedFileURLs)).isEnabled
                }())
            }

            CommandGroup(after: .pasteboard) {
                Button {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.focusSearchAction(_:)), to: nil, from: nil)
                } label: {
                    Label("Find…", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            CommandGroup(after: .pasteboard) {
                Button {
                    rotateSelectionLeft()
                } label: {
                    Label("Rotate Left", systemImage: "rotate.left")
                }
                .disabled(appDelegate.appModel?.selectedFileURLs.isEmpty ?? true)

                Button {
                    rotateSelectionRight()
                } label: {
                    Label("Rotate Right", systemImage: "rotate.right")
                }
                .disabled(appDelegate.appModel?.selectedFileURLs.isEmpty ?? true)

                Button {
                    flipSelectionHorizontal()
                } label: {
                    Label("Flip", systemImage: "flip.horizontal")
                }
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

                Divider()

                Button {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.zoomInAction(_:)), to: nil, from: nil)
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled((appDelegate.appModel?.browserViewMode ?? .gallery) == .list)

                Button {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.zoomOutAction(_:)), to: nil, from: nil)
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled((appDelegate.appModel?.browserViewMode ?? .gallery) == .list)
            }

            CommandMenu("Folder") {
                Button {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.refreshAction(_:)), to: nil, from: nil)
                } label: {
                    Label("Refresh Files and Metadata", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)

                Button {
                    guard let model = appDelegate.appModel else { return }
                    model.performFileAction(.applyMetadataChanges, targetURLs: Array(model.selectedFileURLs))
                } label: {
                    let state = appDelegate.appModel?.fileActionState(for: .applyMetadataChanges, targetURLs: Array(appDelegate.appModel?.selectedFileURLs ?? []))
                    Label(state?.title ?? "Apply Metadata Changes", systemImage: state?.symbolName ?? "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled({
                    guard let model = appDelegate.appModel else { return true }
                    return !model.fileActionState(for: .applyMetadataChanges, targetURLs: Array(model.selectedFileURLs)).isEnabled
                }())

                Button {
                    guard let model = appDelegate.appModel else { return }
                    model.performFileAction(.clearMetadataChanges, targetURLs: Array(model.selectedFileURLs))
                } label: {
                    let state = appDelegate.appModel?.fileActionState(for: .clearMetadataChanges, targetURLs: Array(appDelegate.appModel?.selectedFileURLs ?? []))
                    Label(state?.title ?? "Clear Metadata Changes", systemImage: state?.symbolName ?? "xmark.circle")
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled({
                    guard let model = appDelegate.appModel else { return true }
                    return !model.fileActionState(for: .clearMetadataChanges, targetURLs: Array(model.selectedFileURLs)).isEnabled
                }())

                Button {
                    guard let model = appDelegate.appModel else { return }
                    model.performFileAction(.restoreFromLastBackup, targetURLs: Array(model.selectedFileURLs))
                } label: {
                    let state = appDelegate.appModel?.fileActionState(for: .restoreFromLastBackup, targetURLs: Array(appDelegate.appModel?.selectedFileURLs ?? []))
                    Label(state?.title ?? "Restore from Last Backup", systemImage: state?.symbolName ?? "arrow.uturn.backward.circle")
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled({
                    guard let model = appDelegate.appModel else { return true }
                    return !model.fileActionState(for: .restoreFromLastBackup, targetURLs: Array(model.selectedFileURLs)).isEnabled
                }())

                Divider()

                Button {
                    appDelegate.appModel?.pinSelectedSidebarLocationToFavorites()
                } label: {
                    Label("Pin Location to Pinned", systemImage: "pin")
                }
                .disabled(!(appDelegate.appModel?.canPinSelectedSidebarLocation ?? false))

                Button {
                    appDelegate.appModel?.unpinSelectedSidebarFavorite()
                } label: {
                    Label("Unpin Pinned", systemImage: "pin.slash")
                }
                .disabled(!(appDelegate.appModel?.canUnpinSelectedSidebarLocation ?? false))

                Button {
                    appDelegate.appModel?.moveSelectedFavoriteUp()
                } label: {
                    Label("Move Pinned Up", systemImage: "arrow.up")
                }
                .disabled(!(appDelegate.appModel?.canMoveSelectedFavoriteUp ?? false))

                Button {
                    appDelegate.appModel?.moveSelectedFavoriteDown()
                } label: {
                    Label("Move Pinned Down", systemImage: "arrow.down")
                }
                .disabled(!(appDelegate.appModel?.canMoveSelectedFavoriteDown ?? false))

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
                        Label("Save Current as Preset…", systemImage: "square.and.arrow.down.on.square")
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

        let purpose = "A local EXIF/IPTC/XMP editor powered by ExifTool."
        let nativeFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
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
        alert.messageText = "You have unsaved metadata changes."
        alert.informativeText = "Quit and discard unsaved edits?"
        alert.addButton(withTitle: "Quit")
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
