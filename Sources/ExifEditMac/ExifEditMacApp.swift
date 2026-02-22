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
            CommandGroup(replacing: .appInfo) {
                Button("About Logbook") {
                    appDelegate.showAboutPanel()
                }
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    performUndo()
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo") {
                    performRedo()
                }
                .keyboardShortcut("Z", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.openFolderAction(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Open in Default App") {
                    appDelegate.appModel?.openSelectedInDefaultApp()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled((appDelegate.appModel?.selectedFileURLs.isEmpty ?? true))

                Button("Reveal in Finder") {
                    appDelegate.appModel?.revealSelectionInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled((appDelegate.appModel?.selectedFileURLs.isEmpty ?? true))
            }

            CommandGroup(after: .pasteboard) {
                Menu("Find") {
                    Button("Find…") {
                        NSApp.sendAction(#selector(NativeThreePaneSplitViewController.focusSearchAction(_:)), to: nil, from: nil)
                    }
                    .keyboardShortcut("f", modifiers: .command)
                }
            }

            CommandGroup(after: .toolbar) {
                Button("Show Sidebar") {
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                Divider()

                Button("Gallery View") {
                    appDelegate.appModel?.browserViewMode = .gallery
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled((appDelegate.appModel?.browserViewMode ?? .gallery) == .gallery)

                Button("List View") {
                    appDelegate.appModel?.browserViewMode = .list
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled((appDelegate.appModel?.browserViewMode ?? .gallery) == .list)

                Divider()

                Menu("Sort By") {
                    let sort = appDelegate.appModel?.browserSort ?? .name

                    Button {
                        appDelegate.appModel?.browserSort = .name
                    } label: {
                        if sort == .name { Label("Name", systemImage: "checkmark") } else { Text("Name") }
                    }

                    Button {
                        appDelegate.appModel?.browserSort = .created
                    } label: {
                        if sort == .created { Label("Date Created", systemImage: "checkmark") } else { Text("Date Created") }
                    }

                    Button {
                        appDelegate.appModel?.browserSort = .size
                    } label: {
                        if sort == .size { Label("Size", systemImage: "checkmark") } else { Text("Size") }
                    }

                    Button {
                        appDelegate.appModel?.browserSort = .kind
                    } label: {
                        if sort == .kind { Label("Kind", systemImage: "checkmark") } else { Text("Kind") }
                    }
                }

                Button("Zoom In") {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.zoomInAction(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!(appDelegate.appModel?.browserViewMode == .gallery && (appDelegate.appModel?.canIncreaseGalleryZoom ?? false)))

                Button("Zoom Out") {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.zoomOutAction(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!(appDelegate.appModel?.browserViewMode == .gallery && (appDelegate.appModel?.canDecreaseGalleryZoom ?? false)))
            }

            CommandMenu("Metadata") {
                Button("Refresh Files and Metadata") {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.refreshAction(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Apply Metadata Changes") {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.applyChangesAction(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!(appDelegate.appModel?.canApplyMetadataChanges ?? false))

                Divider()

                Menu("Import") {
                    Button("Import GPX…") {
                        NSApp.sendAction(#selector(NativeThreePaneSplitViewController.importGPXAction(_:)), to: nil, from: nil)
                    }
                    .disabled((appDelegate.appModel?.browserItems.isEmpty ?? true))
                }

                Menu("Presets") {
                    Menu("Apply Preset") {
                        if (appDelegate.appModel?.presets.isEmpty ?? true) {
                            Text("No Presets")
                        } else {
                            ForEach(appDelegate.appModel?.presets ?? []) { preset in
                                Button(preset.name) {
                                    appDelegate.appModel?.applyPreset(presetID: preset.id)
                                }
                                .disabled((appDelegate.appModel?.selectedFileURLs.isEmpty ?? true))
                            }
                        }
                    }

                    Divider()

                    Button("Save Current as Preset…") {
                        NSApp.sendAction(#selector(NativeThreePaneSplitViewController.saveCurrentAsPresetAction(_:)), to: nil, from: nil)
                    }
                    .disabled((appDelegate.appModel?.selectedFileURLs.isEmpty ?? true))

                    Button("Manage Presets…") {
                        NSApp.sendAction(#selector(NativeThreePaneSplitViewController.managePresetsAction(_:)), to: nil, from: nil)
                    }
                }
            }

            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Info Panel") {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.debugAction(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }

            CommandGroup(after: .help) {
                Button("ExifTool Documentation") {
                    if let url = URL(string: "https://exiftool.org/") {
                        NSWorkspace.shared.open(url)
                    }
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
            ?? "Logbook"
        let shortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
        let buildVersion = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
        let combinedVersion = "\(shortVersion) (\(buildVersion))"
        let exifToolVersion = bundledExifToolVersion() ?? "Unknown"

        let purpose = "A local EXIF/IPTC/XMP editor powered by ExifTool."
        let credits = NSMutableAttributedString(
            string: "\(purpose)\n\nUses ExifTool \(exifToolVersion) by Phil Harvey\n"
        )
        let linkText = "https://exiftool.org/"
        let linkRange = NSRange(location: credits.length, length: (linkText as NSString).length)
        credits.append(NSAttributedString(string: linkText))
        credits.addAttributes(
            [
                .link: linkText,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
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
        window.title = "Logbook"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct MetadataDebugSheet: View {
    private enum DebugViewMode: String, CaseIterable, Identifiable {
        case exifToolLog = "ExifTool Log"
        case parsedFields = "Parsed Fields"

        var id: String { rawValue }
    }

    @ObservedObject var model: AppModel
    var onClose: (() -> Void)?
    @State private var mode: DebugViewMode = .exifToolLog

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Metadata Info")
                    .font(.title3.weight(.semibold))
                Spacer()
                Picker("View", selection: $mode) {
                    ForEach(DebugViewMode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                if mode == .exifToolLog {
                    Button("Clear Log") {
                        model.clearExifToolTraceLog()
                    }
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(displayText, forType: .string)
                }
                Button("Close") { onClose?() }
                    .keyboardShortcut(.cancelAction)
            }

            Text(mode == .exifToolLog
                ? "Live exiftool command/output log (temporary debugging tool)."
                : "Raw parsed fields from current selection (temporary debugging tool).")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: .constant(displayText))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(minHeight: 420)
        }
        .padding()
        .frame(minWidth: 860, minHeight: 560)
    }

    private var displayText: String {
        switch mode {
        case .exifToolLog:
            return model.exifToolTraceText
        case .parsedFields:
            return model.metadataDebugText
        }
    }
}
