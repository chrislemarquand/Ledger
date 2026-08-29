import AppKit
import SwiftUI

/// Debug-only UI for driving the read-only `eos1v_tool.py` commands against a connected
/// EOS-1V. Console pane on top, controls beneath — same shape as `ExifToolConsoleView`.
struct EOS1VConsoleView: View {
    @StateObject private var runner = EOS1VToolRunner()
    @State private var command: EOS1VToolRunner.Command = .probe
    @State private var verbose = false

    var body: some View {
        VStack(spacing: 0) {
            consolePane
            Divider()
            controls
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    // MARK: - Console

    private var consolePane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if runner.lines.isEmpty {
                        Text("Connect the EOS-1V via the ES-E1 cable, switch it on in PC/data-transfer mode, then run a command.\n\nThe camera sleeps after a short idle period — if a command reports that it “did not answer the wake”, power-cycle the camera and try again.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    ForEach(runner.lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.isError ? Color.red : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: runner.lines.count) {
                guard let lastID = runner.lines.last?.id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(lastID, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Command:")
                    .frame(width: 92, alignment: .leading)
                Picker("", selection: $command) {
                    ForEach(EOS1VToolRunner.Command.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                Toggle("Verbose", isOn: $verbose)
                    .toggleStyle(.checkbox)
                Spacer()
                if runner.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { runner.cancel() }
                } else {
                    Button("Run") { runner.run(command, verbose: verbose) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!runner.configurationProblems.isEmpty)
                }
                Button("Clear") { runner.clear() }
                    .disabled(runner.lines.isEmpty || runner.isRunning)
            }

            pathRow(label: "Tool folder:", value: $runner.toolDirectory)
            pathRow(label: "Python:", value: $runner.pythonPath, chooseFiles: true)
            pathRow(label: "Output to:", value: $runner.outputDirectory)

            if !runner.configurationProblems.isEmpty {
                ForEach(runner.configurationProblems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            statusLine
        }
        .padding(12)
    }

    private func pathRow(label: String, value: Binding<String>, chooseFiles: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 92, alignment: .leading)
            TextField("", text: value)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity)
            Button("Choose…") { choosePath(into: value, chooseFiles: chooseFiles) }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            if let code = runner.lastExitCode {
                Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(code == 0 ? .green : .red)
                Text(code == 0 ? "Completed" : "Exited with status \(code)")
            } else if runner.isRunning {
                Text("Running…")
            } else {
                Text("Idle")
            }
            if let duration = runner.lastDuration {
                Text(String(format: "· %.1fs", duration))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Read-only commands only")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func choosePath(into binding: Binding<String>, chooseFiles: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = !chooseFiles
        panel.canChooseFiles = chooseFiles
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: binding.wrappedValue).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.wrappedValue = url.path
    }
}
