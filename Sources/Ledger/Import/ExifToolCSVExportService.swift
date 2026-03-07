import Foundation

struct ExifToolCSVExportService {
    enum ExportError: LocalizedError {
        case exifToolNotFound
        case noFiles
        case processFailed(code: Int32, message: String)
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .exifToolNotFound:
                return "ExifTool executable could not be found."
            case .noFiles:
                return "No files are available to export."
            case let .processFailed(code, message):
                if message.isEmpty {
                    return "ExifTool export failed with exit code \(code)."
                }
                return "ExifTool export failed: \(message)"
            case .emptyOutput:
                return "ExifTool produced an empty CSV output."
            }
        }
    }

    func export(fileURLs: [URL], destinationURL: URL) async throws {
        let files = Array(Set(fileURLs)).sorted(by: { $0.path < $1.path })
        guard !files.isEmpty else {
            throw ExportError.noFiles
        }

        try await Task.detached(priority: .userInitiated) {
            let executableURL = try Self.resolveExifToolExecutableURL()
            let arguments = Self.exportArguments(for: files)
            let parent = destinationURL.deletingLastPathComponent()
            let tempOutputURL = parent.appendingPathComponent(".ledger-export-\(UUID().uuidString).csv.tmp")
            let tempStderrURL = parent.appendingPathComponent(".ledger-export-\(UUID().uuidString).stderr.tmp")
            let fileManager = FileManager.default

            defer {
                try? fileManager.removeItem(at: tempOutputURL)
                try? fileManager.removeItem(at: tempStderrURL)
            }

            let result = try Self.runProcess(
                executableURL: executableURL,
                arguments: arguments,
                stdoutURL: tempOutputURL,
                stderrURL: tempStderrURL
            )
            guard result.terminationStatus == 0 else {
                throw ExportError.processFailed(
                    code: result.terminationStatus,
                    message: String(decoding: result.stderr, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            let outputSize = ((try fileManager.attributesOfItem(atPath: tempOutputURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
            guard outputSize > 0 else {
                throw ExportError.emptyOutput
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempOutputURL)
            } else {
                try fileManager.moveItem(at: tempOutputURL, to: destinationURL)
            }
        }.value
    }

    static func exportArguments(for files: [URL]) -> [String] {
        // "--" terminates options so hyphen-prefixed file paths are treated as operands.
        ["-G4", "-a", "-csv", "--"] + files.map(\.path)
    }

    private static func resolveExifToolExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("exiftool/bin/exiftool")
        let candidates = [
            bundled,
            URL(fileURLWithPath: "/opt/homebrew/bin/exiftool"),
            URL(fileURLWithPath: "/usr/local/bin/exiftool"),
            URL(fileURLWithPath: "/usr/bin/exiftool"),
        ].compactMap { $0 }

        for url in candidates where fileManager.isExecutableFile(atPath: url.path) {
            return url
        }

        throw ExportError.exifToolNotFound
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        stdoutURL: URL,
        stderrURL: URL
    ) throws -> (stderr: Data, terminationStatus: Int32) {
        let fileManager = FileManager.default
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()

        // Bundled exiftool expects Image::ExifTool modules under a sibling "lib" folder.
        let bundledLibPath = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("lib")
            .path
        if FileManager.default.fileExists(atPath: bundledLibPath) {
            var environment = ProcessInfo.processInfo.environment
            let existing = environment["PERL5LIB"] ?? ""
            environment["PERL5LIB"] = existing.isEmpty ? bundledLibPath : "\(bundledLibPath):\(existing)"
            process.environment = environment
        }

        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()
        process.waitUntilExit()

        let stderrData = try Data(contentsOf: stderrURL)
        return (
            stderr: stderrData,
            terminationStatus: process.terminationStatus
        )
    }
}
