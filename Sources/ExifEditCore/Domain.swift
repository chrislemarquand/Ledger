import Foundation

public enum MetadataNamespace: String, Codable, CaseIterable, Sendable {
    case exif = "EXIF"
    case iptc = "IPTC"
    case xmp = "XMP"
    case xmpDM = "XMP-xmpDM"
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

// MARK: - Batch Rename Domain

public enum BatchRenameScope: String, Sendable, CaseIterable, Identifiable {
    case selection
    case folder

    public var id: String { rawValue }
}

public enum DateSource: String, Sendable, Equatable, CaseIterable, Identifiable {
    public var id: String { rawValue }
    case dateTimeOriginal
    case createDate
    case modifyDate

    public var displayName: String {
        switch self {
        case .dateTimeOriginal: return "Date Time Original"
        case .createDate: return "Date Created"
        case .modifyDate: return "Date File Modified"
        }
    }
}

public enum DateFormat: String, Sendable, Equatable, CaseIterable, Identifiable {
    public var id: String { rawValue }
    case mmddyyyy
    case mmddyy
    case yyyymmdd
    case yymmdd
    case ddmmyyyy
    case ddmmyy
    case yyyy
    case yy
    case mm
    case dd
    case hhmmss
    case hhmm
    case milliseconds

    public var displayName: String {
        switch self {
        case .mmddyyyy:    return "MMDDYYYY"
        case .mmddyy:      return "MMDDYY"
        case .yyyymmdd:    return "YYYYMMDD"
        case .yymmdd:      return "YYMMDD"
        case .ddmmyyyy:    return "DDMMYYYY"
        case .ddmmyy:      return "DDMMYY"
        case .yyyy:        return "YYYY"
        case .yy:          return "YY"
        case .mm:          return "MM"
        case .dd:          return "DD"
        case .hhmmss:      return "HHMMSS"
        case .hhmm:        return "HHMM"
        case .milliseconds: return "Milliseconds"
        }
    }

    public var dateFormatString: String {
        switch self {
        case .mmddyyyy:    return "MMddyyyy"
        case .mmddyy:      return "MMddyy"
        case .yyyymmdd:    return "yyyyMMdd"
        case .yymmdd:      return "yyMMdd"
        case .ddmmyyyy:    return "ddMMyyyy"
        case .ddmmyy:      return "ddMMyy"
        case .yyyy:        return "yyyy"
        case .yy:          return "yy"
        case .mm:          return "MM"
        case .dd:          return "dd"
        case .hhmmss:      return "HHmmss"
        case .hhmm:        return "HHmm"
        case .milliseconds: return "SSS"
        }
    }
}

public enum SequencePadding: Int, Sendable, Equatable, CaseIterable, Identifiable {
    case one = 1, two = 2, three = 3, four = 4, five = 5, six = 6

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .one:   return "One Digit"
        case .two:   return "Two Digits"
        case .three: return "Three Digits"
        case .four:  return "Four Digits"
        case .five:  return "Five Digits"
        case .six:   return "Six Digits"
        }
    }
}

public enum RenameToken: Sendable, Equatable {
    case text(String)
    case originalName
    case sequence(start: Int, padding: SequencePadding)
    case sequenceLetter(uppercase: Bool)
    case date(source: DateSource, format: DateFormat)
    case `extension`(String)
}

public struct RenamePattern: Sendable, Equatable {
    public var tokens: [RenameToken]

    public init(tokens: [RenameToken] = []) {
        self.tokens = tokens
    }
}

public struct RenamePlanEntry: Sendable {
    public let sourceURL: URL
    public let proposedBasename: String        // before collision resolution
    public let finalTargetURL: URL             // after collision resolution

    public init(sourceURL: URL, proposedBasename: String, finalTargetURL: URL) {
        self.sourceURL = sourceURL
        self.proposedBasename = proposedBasename
        self.finalTargetURL = finalTargetURL
    }
}

public struct RenameValidationIssue: Sendable, Equatable {
    public let sourceURL: URL?
    public let message: String

    public init(sourceURL: URL? = nil, message: String) {
        self.sourceURL = sourceURL
        self.message = message
    }
}

public struct RenamePlanAssessment: Sendable {
    public let entries: [RenamePlanEntry]
    public let issues: [RenameValidationIssue]

    public init(entries: [RenamePlanEntry], issues: [RenameValidationIssue]) {
        self.entries = entries
        self.issues = issues
    }
}

public enum RenameConflictPolicy: Sendable { case autoDisambiguate }

public struct RenameOperation: Sendable, Identifiable {
    public let id: UUID
    public let files: [URL]
    public let pattern: RenamePattern
    public let conflictPolicy: RenameConflictPolicy

    public init(
        id: UUID = UUID(),
        files: [URL],
        pattern: RenamePattern,
        conflictPolicy: RenameConflictPolicy = .autoDisambiguate
    ) {
        self.id = id
        self.files = files
        self.pattern = pattern
        self.conflictPolicy = conflictPolicy
    }
}

public struct RenameResult: Sendable {
    public let operationID: UUID
    public let succeeded: [URL]
    public let failed: [(URL, any Error & Sendable)]
    public let backupLocation: URL?
    public let duration: TimeInterval

    public init(
        operationID: UUID,
        succeeded: [URL],
        failed: [(URL, any Error & Sendable)],
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

// MARK: - Errors

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
            return "Your presets were saved by a newer version of the app and can't be read. Update the app to access them."
        }
    }
}
