import Foundation

/// Runs `eos1v_tool.py` (github.com/epvucclaude/eos1v-serial) as a subprocess and streams
/// its output line-by-line for display in `EOS1VConsoleView`.
///
/// **Safety contract:** `Command` deliberately has *no cases* for the tool's destructive
/// operations — `erase-all`, `set-clock`, `write-cfn`, `write-pfn`, `apply`. They are absent
/// from the type rather than merely hidden in the UI, so no code path in Ledger can invoke
/// them. `erase-all` in particular is a single, irreversible camera command with no arming
/// step. Do not add write cases here without a deliberate, separately-reviewed decision.
@MainActor
final class EOS1VToolRunner: ObservableObject {

    // MARK: - Read-only command surface

    enum Command: String, CaseIterable, Identifiable, Sendable {
        case probe
        case download
        case dumpSettings
        case readCFN
        case readPFN
        case readItems

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .probe:        return "Probe (wake + read one frame)"
            case .download:     return "Download shooting data"
            case .dumpSettings: return "Dump all settings (C.Fn + P.Fn)"
            case .readCFN:      return "Read Custom Functions"
            case .readPFN:      return "Read Personal Functions"
            case .readItems:    return "Read recorded-items mask"
            }
        }

        /// Commands that write a file into the output directory.
        var producesFiles: Bool {
            switch self {
            case .probe, .readItems: return false
            default: return true
            }
        }

        fileprivate var subcommand: String {
            switch self {
            case .probe:        return "probe"
            case .download:     return "download"
            case .dumpSettings: return "dump-settings"
            case .readCFN:      return "read-cfn"
            case .readPFN:      return "read-pfn"
            case .readItems:    return "read-items"
            }
        }

        /// Output filenames this command needs, appended after the subcommand.
        fileprivate func outputFilenames(stamp: String) -> [String] {
            switch self {
            case .download:     return ["\(stamp)-shooting-data.csv", "\(stamp)-raw.txt"]
            case .dumpSettings: return ["\(stamp)-settings.txt"]
            case .readCFN:      return ["\(stamp)-cfn-backup.txt"]
            case .readPFN:      return ["\(stamp)-pfn-backup.txt"]
            case .probe, .readItems: return []
            }
        }
    }

    // MARK: - Output

    struct OutputLine: Identifiable, Sendable {
        let id = UUID()
        let text: String
        let isError: Bool
        let timestamp: Date
    }

    @Published private(set) var lines: [OutputLine] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastCommandLine: String?
    @Published private(set) var lastExitCode: Int32?
    @Published private(set) var lastDuration: TimeInterval?

    private var process: Process?

    // MARK: - Configuration (persisted)

    private enum Keys {
        static let toolDirectory = "\(AppBrand.identifierPrefix).eos1v.toolDirectory"
        static let pythonPath = "\(AppBrand.identifierPrefix).eos1v.pythonPath"
        static let outputDirectory = "\(AppBrand.identifierPrefix).eos1v.outputDirectory"
    }

    @Published var toolDirectory: String {
        didSet { UserDefaults.standard.set(toolDirectory, forKey: Keys.toolDirectory) }
    }

    @Published var pythonPath: String {
        didSet { UserDefaults.standard.set(pythonPath, forKey: Keys.pythonPath) }
    }

    @Published var outputDirectory: String {
        didSet { UserDefaults.standard.set(outputDirectory, forKey: Keys.outputDirectory) }
    }

    init() {
        let defaults = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let guessedTool = "\(home)/Xcode Projects/eos1v-serial"
        toolDirectory = defaults.string(forKey: Keys.toolDirectory) ?? guessedTool
        pythonPath = defaults.string(forKey: Keys.pythonPath) ?? "\(guessedTool)/.venv/bin/python"
        outputDirectory = defaults.string(forKey: Keys.outputDirectory) ?? "\(guessedTool)/captures"
    }

    // MARK: - Preflight

    /// Human-readable problems that would stop a run, checked before spawning anything.
    var configurationProblems: [String] {
        var problems: [String] = []
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: pythonPath) {
            problems.append("Python interpreter not found or not executable: \(pythonPath)")
        }
        if !fm.fileExists(atPath: scriptPath) {
            problems.append("eos1v_tool.py not found in: \(toolDirectory)")
        }
        return problems
    }

    private var scriptPath: String { "\(toolDirectory)/eos1v_tool.py" }

    // MARK: - Run / cancel

    func run(_ command: Command, verbose: Bool) {
        guard !isRunning else { return }

        let problems = configurationProblems
        guard problems.isEmpty else {
            problems.forEach { appendLine($0, isError: true) }
            return
        }

        var arguments = [scriptPath, command.subcommand]
        if command.producesFiles {
            let directory = URL(fileURLWithPath: outputDirectory)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                appendLine("Could not create output directory: \(error.localizedDescription)", isError: true)
                return
            }
            let stamp = Self.stampFormatter.string(from: Date())
            arguments.append(contentsOf: command.outputFilenames(stamp: stamp).map {
                directory.appendingPathComponent($0).path
            })
        }
        if verbose { arguments.append("-v") }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = arguments
        task.currentDirectoryURL = URL(fileURLWithPath: toolDirectory)

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        lastCommandLine = ([pythonPath] + arguments).joined(separator: " ")
        lastExitCode = nil
        lastDuration = nil
        isRunning = true
        process = task
        appendLine("$ \(lastCommandLine ?? "")", isError: false)

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendChunk(text, isError: false) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendChunk(text, isError: true) }
        }

        let started = Date()
        task.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            let elapsed = Date().timeIntervalSince(started)
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            // Drain anything buffered between the last handler call and exit.
            let tailOut = String(data: stdout.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            let tailErr = String(data: stderr.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            Task { @MainActor in
                guard let self else { return }
                if !tailOut.isEmpty { self.appendChunk(tailOut, isError: false) }
                if !tailErr.isEmpty { self.appendChunk(tailErr, isError: true) }
                self.finish(code: code, duration: elapsed)
            }
        }

        do {
            try task.run()
        } catch {
            appendLine("Failed to launch: \(error.localizedDescription)", isError: true)
            finish(code: -1, duration: 0)
        }
    }

    /// Terminates the running subprocess. Safe at any point — every command exposed here is
    /// read-only, so an interrupted run cannot leave the camera in a partial write state.
    func cancel() {
        guard let process, process.isRunning else { return }
        appendLine("— cancelled —", isError: true)
        process.terminate()
    }

    func clear() {
        lines.removeAll()
        lastCommandLine = nil
        lastExitCode = nil
        lastDuration = nil
    }

    // MARK: - Private

    private func finish(code: Int32, duration: TimeInterval) {
        lastExitCode = code
        lastDuration = duration
        isRunning = false
        process = nil
    }

    private func appendChunk(_ chunk: String, isError: Bool) {
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.isEmpty, lines.last?.text.isEmpty == true { continue }
            appendLine(text, isError: isError)
        }
    }

    private func appendLine(_ text: String, isError: Bool) {
        lines.append(OutputLine(text: text, isError: isError, timestamp: Date()))
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
