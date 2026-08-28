import AppKit
import ExifEditCore
import SwiftUI

/// Standalone auxiliary window, same lifecycle pattern as SharedUI's `SettingsWindowController` —
/// created once and kept alive for the app's lifetime, brought to front on repeat invocation
/// rather than recreated.
@MainActor
final class ExifToolConsoleWindowController: NSWindowController {
    init(model: AppModel) {
        let hostingController = NSHostingController(rootView: ExifToolConsoleView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "ExifTool Console"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 420))
        window.minSize = NSSize(width: 480, height: 240)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("\(AppBrand.identifierPrefix).ExifToolConsoleWindow")
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

private struct ExifToolConsoleView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.exifToolConsoleEntries) { trace in
                            ExifToolConsoleEntryView(trace: trace)
                                .id(trace.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.exifToolConsoleEntries.count) {
                    guard let lastID = model.exifToolConsoleEntries.last?.id else { return }
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            Divider()
            HStack {
                Text("\(model.exifToolConsoleEntries.count) command\(model.exifToolConsoleEntries.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clearExifToolConsole() }
                    .disabled(model.exifToolConsoleEntries.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 480, minHeight: 240)
    }
}

private struct ExifToolConsoleEntryView: View {
    let trace: ExifToolInvocationTrace

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("$ \(commandLine)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(trace.succeeded ? .primary : Color.red)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(Self.timeFormatter.string(from: trace.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(String(format: "%.2fs", trace.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !trace.stdout.isEmpty {
                Text(trace.stdout)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !trace.stderr.isEmpty {
                Text(trace.stderr)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var commandLine: String {
        (["exiftool"] + trace.arguments).joined(separator: " ")
    }
}
