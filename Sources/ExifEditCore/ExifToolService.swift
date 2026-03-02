import Foundation
import Darwin

public protocol ExifToolServiceProtocol: Sendable {
    func readMetadata(files: [URL]) async throws -> [FileMetadataSnapshot]
    func writeMetadata(operation: EditOperation) async -> OperationResult
}

public enum ExifToolCommandKind: String, Codable, Sendable {
    case read
    case write
}

public struct ExifToolInvocationTrace: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let kind: ExifToolCommandKind
    public let executablePath: String
    public let arguments: [String]
    public let filePath: String?
    public let terminationStatus: Int32
    public let duration: TimeInterval
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { terminationStatus == 0 }
}

public extension Notification.Name {
    static let exifToolInvocationDidFinish = Notification.Name("ExifEditCore.ExifToolInvocationDidFinish")
}

public struct ExifToolService: ExifToolServiceProtocol {
    private let executableURL: URL
    private let commandBuilder: ExifToolCommandBuilder
    private let readTimeout: TimeInterval
    private let writeTimeout: TimeInterval

    public init(
        executableURL: URL? = nil,
        commandBuilder: ExifToolCommandBuilder = ExifToolCommandBuilder(),
        readTimeout: TimeInterval = 12,
        writeTimeout: TimeInterval = 25
    ) throws {
        if let executableURL {
            self.executableURL = executableURL
        } else if let located = Self.findDefaultExifToolPath() {
            self.executableURL = located
        } else {
            throw ExifEditError.exifToolNotFound
        }

        self.commandBuilder = commandBuilder
        self.readTimeout = max(1, readTimeout)
        self.writeTimeout = max(1, writeTimeout)
    }

    public func readMetadata(files: [URL]) async throws -> [FileMetadataSnapshot] {
        guard !files.isEmpty else { return [] }
        let data = try run(arguments: commandBuilder.readArguments(for: files), kind: .read, filePath: nil)

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw ExifEditError.invalidExifToolJSON
        }

        return json.compactMap(parseSnapshot(dictionary:))
    }

    public func writeMetadata(operation: EditOperation) async -> OperationResult {
        let startedAt = Date()
        var succeeded: [URL] = []
        var failed: [FileError] = []

        for file in operation.targetFiles {
            do {
                _ = try run(
                    arguments: commandBuilder.writeArguments(for: operation, file: file),
                    kind: .write,
                    filePath: file.path
                )
                succeeded.append(file)
            } catch {
                failed.append(FileError(fileURL: file, message: error.localizedDescription))
            }
        }

        return OperationResult(
            operationID: operation.id,
            succeeded: succeeded,
            failed: failed,
            backupLocation: nil,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    private static func findDefaultExifToolPath() -> URL? {
        let fileManager = FileManager.default
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("exiftool/bin/exiftool")
        let candidates = [
            bundled?.path,
            "/opt/homebrew/bin/exiftool",
            "/usr/local/bin/exiftool",
            "/usr/bin/exiftool"
        ].compactMap { $0 }

        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private func parseSnapshot(dictionary: [String: Any]) -> FileMetadataSnapshot? {
        guard let sourcePath = dictionary["SourceFile"] as? String else {
            return nil
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        var fields: [MetadataField] = []

        for (rawKey, value) in dictionary {
            guard rawKey != "SourceFile" else { continue }

            let components = rawKey.split(separator: ":", maxSplits: 1).map(String.init)
            guard components.count == 2 else {
                continue
            }
            let group = components[0]
            let key = components[1]
            guard let namespace = normalizedNamespace(fromExifToolGroup: group)
                ?? inferredNamespace(fromExifToolGroup: group, key: key)
            else {
                continue
            }

            fields.append(
                MetadataField(
                    key: key,
                    namespace: namespace,
                    value: normalizedFieldValue(value),
                    valueType: inferValueType(from: value)
                )
            )
        }

        fields.sort { lhs, rhs in
            if lhs.namespace.rawValue == rhs.namespace.rawValue {
                return lhs.key < rhs.key
            }

            return lhs.namespace.rawValue < rhs.namespace.rawValue
        }

        return FileMetadataSnapshot(fileURL: sourceURL, fields: fields)
    }

    private func normalizedNamespace(fromExifToolGroup group: String) -> MetadataNamespace? {
        let normalized = group.uppercased()

        if normalized.hasPrefix("EXIF") {
            return .exif
        }
        if normalized.hasPrefix("IFD") || normalized.hasPrefix("EXIFIFD") || normalized.hasPrefix("MAKERNOTES") {
            return .exif
        }
        if normalized.hasPrefix("GPS") {
            return .exif
        }
        if normalized.hasPrefix("IPTC") {
            return .iptc
        }
        if normalized.hasPrefix("XMP") {
            return .xmp
        }

        return nil
    }

    private func inferredNamespace(fromExifToolGroup group: String, key: String) -> MetadataNamespace? {
        let normalizedGroup = group.uppercased()
        let normalizedKey = key.uppercased()

        // GPS data is often emitted from Composite/GPS groups in exiftool output.
        if normalizedKey.hasPrefix("GPS"), normalizedGroup.hasPrefix("COMPOSITE") || normalizedGroup.hasPrefix("GPS") {
            return .exif
        }
        // Some camera values may surface under Composite in certain files.
        if normalizedGroup.hasPrefix("COMPOSITE"),
           ["FLASH", "EXPOSUREPROGRAM", "METERINGMODE"].contains(normalizedKey) {
            return .exif
        }

        return nil
    }

    private func inferValueType(from value: Any) -> MetadataValueType {
        switch value {
        case is Int, is Int64, is UInt:
            return .integer
        case is Double, is Float:
            return .decimal
        case is Bool:
            return .boolean
        default:
            return .string
        }
    }

    private func normalizedFieldValue(_ value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let array = value as? [Any] {
            return array
                .map { normalizedFieldValue($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
        if value is NSNull {
            return ""
        }
        return String(describing: value)
    }

    private func run(arguments: [String], kind: ExifToolCommandKind, filePath: String?) throws -> Data {
        let startedAt = Date()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()

        // Bundled exiftool is a Perl script that expects Image::ExifTool modules
        // under a sibling "lib" folder.
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
        let deadline = startedAt.addingTimeInterval(timeout(for: kind))
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                Thread.sleep(forTimeInterval: 0.2)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(decoding: stdoutData, as: UTF8.self)
        var stderrText = String(decoding: stderrData, as: UTF8.self)
        if timedOut {
            let timeoutText = "Timed out after \(Int(timeout(for: kind)))s while running exiftool."
            stderrText = stderrText.isEmpty ? timeoutText : "\(stderrText)\n\(timeoutText)"
        }

        emitTrace(
            ExifToolInvocationTrace(
                id: UUID(),
                timestamp: startedAt,
                kind: kind,
                executablePath: executableURL.path,
                arguments: arguments,
                filePath: filePath,
                terminationStatus: process.terminationStatus,
                duration: Date().timeIntervalSince(startedAt),
                stdout: truncated(stdoutText),
                stderr: truncated(stderrText)
            )
        )

        guard process.terminationStatus == 0 else {
            throw ExifEditError.processFailed(code: process.terminationStatus, stderr: stderrText)
        }

        // exiftool exits 0 when a mixed batch has some writable tags and some not —
        // the writable ones are written but the unwritable ones are silently skipped.
        // Detect this by checking stderr for the specific warning exiftool emits,
        // so partial write failures are never swallowed.
        if kind == .write, !stderrText.isEmpty,
           let warning = stderrText.components(separatedBy: "\n")
               .first(where: { $0.contains("doesn't exist or isn't writable") }) {
            throw ExifEditError.processFailed(code: 0, stderr: warning)
        }

        return stdoutData
    }

    private func emitTrace(_ trace: ExifToolInvocationTrace) {
        NotificationCenter.default.post(
            name: .exifToolInvocationDidFinish,
            object: nil,
            userInfo: ["trace": trace]
        )
    }

    private func truncated(_ text: String, limit: Int = 12_000) -> String {
        guard text.count > limit else { return text }
        let kept = text.prefix(limit)
        return "\(kept)\n… (truncated)"
    }

    private func timeout(for kind: ExifToolCommandKind) -> TimeInterval {
        switch kind {
        case .read:
            return readTimeout
        case .write:
            return writeTimeout
        }
    }
}
