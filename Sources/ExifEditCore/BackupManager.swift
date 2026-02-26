import Foundation

public protocol BackupManaging: Sendable {
    func createBackup(operationID: UUID, files: [URL]) throws -> URL
    func restoreBackup(operationID: UUID) throws -> OperationResult
    func pruneOperations(keepLast count: Int) throws
}

public struct BackupManager: BackupManaging {
    public struct BackupManifest: Codable {
        public struct Entry: Codable {
            public let originalPath: String
            public let backupFileName: String
        }

        public let operationID: UUID
        public let entries: [Entry]
    }

    private let baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.baseDirectory = appSupport.appendingPathComponent("ExifEdit/Backups", isDirectory: true)
        }
    }

    public func createBackup(operationID: UUID, files: [URL]) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let operationFolder = baseDirectory.appendingPathComponent(operationID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: operationFolder, withIntermediateDirectories: true)

        var entries: [BackupManifest.Entry] = []

        for (index, file) in files.enumerated() {
            let fileName = "\(index)_\(file.lastPathComponent)"
            let backupURL = operationFolder.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: file, to: backupURL)
            entries.append(.init(originalPath: file.path, backupFileName: fileName))
        }

        let manifest = BackupManifest(operationID: operationID, entries: entries)
        let manifestURL = operationFolder.appendingPathComponent("manifest.json")
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)

        return operationFolder
    }

    public func restoreBackup(operationID: UUID) throws -> OperationResult {
        let startedAt = Date()
        let folder = baseDirectory.appendingPathComponent(operationID.uuidString, isDirectory: true)
        let manifestURL = folder.appendingPathComponent("manifest.json")

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ExifEditError.backupNotFound
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: data)

        var succeeded: [URL] = []
        var failed: [FileError] = []

        for entry in manifest.entries {
            let source = folder.appendingPathComponent(entry.backupFileName)
            let destination = URL(fileURLWithPath: entry.originalPath)

            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
                succeeded.append(destination)
            } catch {
                failed.append(FileError(fileURL: destination, message: error.localizedDescription))
            }
        }

        return OperationResult(
            operationID: operationID,
            succeeded: succeeded,
            failed: failed,
            backupLocation: folder,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    public func pruneOperations(keepLast count: Int) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return }

        let contents = try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )

        let operationFolders = contents
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return dateA > dateB
            }

        for folder in operationFolders.dropFirst(max(0, count)) {
            try fileManager.removeItem(at: folder)
        }
    }
}
