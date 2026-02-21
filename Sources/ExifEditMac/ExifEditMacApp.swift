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
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.openFolderAction(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("Refresh") {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.refreshAction(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Reveal in Finder") {
                    appDelegate.appModel?.revealSelectionInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled((appDelegate.appModel?.selectedFileURLs.isEmpty ?? true))

                Button("Open in Default App") {
                    appDelegate.appModel?.openSelectedInDefaultApp()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled((appDelegate.appModel?.selectedFileURLs.isEmpty ?? true))
            }

            CommandGroup(after: .toolbar) {
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
                Button("Apply Metadata Changes") {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.applyChangesAction(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Restore Last Operation") {
                    NSApp.sendAction(#selector(NativeThreePaneSplitViewController.restoreAction(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
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
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    var appModel: AppModel? { mainWindowController?.appModel }

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
