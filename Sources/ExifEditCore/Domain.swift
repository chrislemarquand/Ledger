import Foundation

public enum MetadataNamespace: String, Codable, CaseIterable, Sendable {
    case exif = "EXIF"
    case iptc = "IPTC"
    case xmp = "XMP"
}

public enum MetadataValueType: String, Codable, Sendable {
    case string
    case integer
    case decimal
    case boolean
    case date
    case unknown
}

public struct MetadataField: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(namespace.rawValue):\(key)" }
    public let key: String
    public let namespace: MetadataNamespace
    public let value: String
    public let valueType: MetadataValueType
    public let writable: Bool
    public let source: String

    public init(
        key: String,
        namespace: MetadataNamespace,
        value: String,
        valueType: MetadataValueType = .string,
        writable: Bool = true,
        source: String = "exiftool"
    ) {
        self.key = key
        self.namespace = namespace
        self.value = value
        self.valueType = valueType
        self.writable = writable
        self.source = source
    }
}

public struct FileMetadataSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: URL { fileURL }
    public let fileURL: URL
    public let fields: [MetadataField]
    public let diagnostics: [String]
    public let loadedAt: Date

    public init(
        fileURL: URL,
        fields: [MetadataField],
        diagnostics: [String] = [],
        loadedAt: Date = Date()
    ) {
        self.fileURL = fileURL
        self.fields = fields
        self.diagnostics = diagnostics
        self.loadedAt = loadedAt
    }
}

public struct MetadataPatch: Codable, Hashable, Sendable {
    public let key: String
    public let namespace: MetadataNamespace
    public let newValue: String
    public let valueType: MetadataValueType

    public init(
        key: String,
        namespace: MetadataNamespace,
        newValue: String,
        valueType: MetadataValueType = .string
    ) {
        self.key = key
        self.namespace = namespace
        self.newValue = newValue
        self.valueType = valueType
    }
}

public enum WriteMode: String, Codable, Sendable {
    case backupThenWrite
}

public struct EditOperation: Codable, Hashable, Sendable {
    public let id: UUID
    public let targetFiles: [URL]
    public let changes: [MetadataPatch]
    public let writeMode: WriteMode

    public init(
        id: UUID = UUID(),
        targetFiles: [URL],
        changes: [MetadataPatch],
        writeMode: WriteMode = .backupThenWrite
    ) {
        self.id = id
        self.targetFiles = targetFiles
        self.changes = changes
        self.writeMode = writeMode
    }
}

public struct FileError: Codable, Hashable, Sendable {
    public let fileURL: URL
    public let message: String

    public init(fileURL: URL, message: String) {
        self.fileURL = fileURL
        self.message = message
    }
}

public struct OperationResult: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let succeeded: [URL]
    public let failed: [FileError]
    public let backupLocation: URL?
    public let duration: TimeInterval

    public init(
        operationID: UUID,
        succeeded: [URL],
        failed: [FileError],
        backupLocation: URL?,
        duration: TimeInterval
    ) {
        self.operationID = operationID
        self.succeeded = succeeded
        self.failed = failed
        self.backupLocation = backupLocation
        self.duration = duration
    }
}

public enum ExifEditError: Error, LocalizedError {
    case exifToolNotFound
    case processFailed(code: Int32, stderr: String)
    case invalidExifToolJSON
    case backupNotFound
    case invalidOperation(String)
    case presetSchemaVersionTooNew

    public var errorDescription: String? {
        switch self {
        case .exifToolNotFound:
            return "Could not find exiftool executable."
        case let .processFailed(code, stderr):
            return "exiftool failed with exit code \(code): \(stderr)"
        case .invalidExifToolJSON:
            return "Invalid JSON output from exiftool."
        case .backupNotFound:
            return "Backup for this operation was not found."
        case let .invalidOperation(reason):
            return reason
        case .presetSchemaVersionTooNew:
        return "Your presets were saved by a newer version of Ledger and can't be read. Update Ledger to access them."
        }
    }
}
