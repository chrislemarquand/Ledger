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

    func export(fileURLs: [URL], destinationURL: URL) throws {
        let files = Array(Set(fileURLs)).sorted(by: { $0.path < $1.path })
        guard !files.isEmpty else {
            throw ExportError.noFiles
        }

        let executableURL = try resolveExifToolExecutableURL()
        let arguments = ["-G4", "-a", "-csv"] + files.map(\.path)
        let result = try runProcess(executableURL: executableURL, arguments: arguments)
        guard result.terminationStatus == 0 else {
            throw ExportError.processFailed(
                code: result.terminationStatus,
                message: String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        guard !result.stdout.isEmpty else {
            throw ExportError.emptyOutput
        }

        try result.stdout.write(to: destinationURL, options: .atomic)
    }

    private func resolveExifToolExecutableURL() throws -> URL {
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

    private func runProcess(executableURL: URL, arguments: [String]) throws -> (stdout: Data, stderr: Data, terminationStatus: Int32) {
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

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return (
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile(),
            terminationStatus: process.terminationStatus
        )
    }
}
