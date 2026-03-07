import ExifEditCore
import Foundation

enum ImportSourceKind: String, CaseIterable, Codable, Sendable {
    case csv
    case gpx
    case referenceFolder
    case referenceImage
    case eos1v

    var menuTitle: String {
        switch self {
        case .csv:
            return "CSV…"
        case .gpx:
            return "GPX…"
        case .referenceFolder:
            return "Reference Folder…"
        case .referenceImage:
            return "Reference Image…"
        case .eos1v:
            return "EOS 1V CSV…"
        }
    }

    var title: String {
        switch self {
        case .csv:
            return "CSV"
        case .gpx:
            return "GPX"
        case .referenceFolder:
            return "Reference Folder"
        case .referenceImage:
            return "Reference Image"
        case .eos1v:
            return "EOS 1V CSV"
        }
    }
}

enum ImportScope: String, CaseIterable, Codable, Sendable {
    case selection
    case folder

    var title: String {
        switch self {
        case .selection:
            return "Selection"
        case .folder:
            return "Folder"
        }
    }
}

enum ImportEmptyValuePolicy: String, CaseIterable, Codable, Sendable {
    case clear
    case skip

    var title: String {
        switch self {
        case .clear:
            return "Clear Empty Values"
        case .skip:
            return "Skip Empty Values"
        }
    }
}


enum ImportMatchStrategy: String, CaseIterable, Codable, Sendable {
    case filename
    case rowParity

    var title: String {
        switch self {
        case .filename:
            return "Match by Filename"
        case .rowParity:
            return "Match by Row Order"
        }
    }
}

struct ImportTagDescriptor: Hashable, Sendable {
    let id: String
    let key: String
    let namespace: MetadataNamespace
    let label: String
    let section: String
    let inputKind: ImportFieldInputKind

    init(
        id: String,
        key: String,
        namespace: MetadataNamespace,
        label: String,
        section: String,
        inputKind: ImportFieldInputKind = .text
    ) {
        self.id = id
        self.key = key
        self.namespace = namespace
        self.label = label
        self.section = section
        self.inputKind = inputKind
    }
}

struct ImportEnumChoice: Hashable, Codable, Sendable {
    let value: String
    let label: String
}

enum ImportFieldInputKind: Hashable, Codable, Sendable {
    case text
    case dateTime
    case decimal
    case gpsCoordinate
    case enumChoice([ImportEnumChoice])
}


enum ImportTargetSelector: Hashable, Sendable {
    case filename(String)
    case rowNumber(Int)
    case direct(URL)
}

struct ImportFieldValue: Hashable, Sendable {
    let tagID: String
    let value: String
}

struct ImportRow: Hashable, Sendable {
    let sourceLine: Int
    let sourceIdentifier: String
    let targetSelector: ImportTargetSelector
    let fields: [ImportFieldValue]
}

enum ImportWarningSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

struct ImportWarning: Hashable, Sendable {
    let sourceLine: Int?
    let message: String
    let severity: ImportWarningSeverity
}

struct ImportParseResult: Hashable, Sendable {
    let rows: [ImportRow]
    let warnings: [ImportWarning]
}

enum ImportConflictKind: String, Codable, Sendable {
    case duplicateSourceIdentifier
    case multipleTargets
    case missingTarget
}

struct ImportConflict: Hashable, Identifiable, Sendable {
    let id: UUID
    let kind: ImportConflictKind
    let sourceLine: Int
    let sourceIdentifier: String
    let rowFields: [ImportFieldValue]
    let candidateTargets: [URL]
    let message: String
}

enum ImportConflictResolutionChoice: Hashable, Sendable {
    case skip
    case target(URL)
}

struct ImportRowMatch: Hashable, Sendable {
    let row: ImportRow
    let targetURL: URL
}

struct ImportMatchResult: Hashable, Sendable {
    let matched: [ImportRowMatch]
    let conflicts: [ImportConflict]
    let warnings: [ImportWarning]
}

struct ImportAssignment: Hashable, Sendable {
    let targetURL: URL
    let fields: [ImportFieldValue]
}

struct ImportPreviewSummary: Hashable, Sendable {
    let sourceKind: ImportSourceKind
    let parsedRows: Int
    let matchedRows: Int
    let conflictedRows: Int
    let warnings: Int
    let fieldWrites: Int
}


struct ImportRunOptions: Hashable, Codable, Sendable {
    var sourceKind: ImportSourceKind
    var scope: ImportScope
    var emptyValuePolicy: ImportEmptyValuePolicy
    var matchStrategy: ImportMatchStrategy
    var rowParityStartRow: Int
    var rowParityRowCount: Int
    var sourceURLPath: String?
    var auxiliaryURLPaths: [String]
    var selectedTagIDs: [String]
    var gpxToleranceSeconds: Int
    var gpxCameraOffsetSeconds: Int
    var referenceFolderRowFallbackEnabled: Bool = false
    /// IANA timezone identifier for the timezone the camera clock was set to.
    /// Defaults to the current system timezone. Stored as a string so the struct
    /// remains `Codable` and `Sendable`. Use the `cameraTimezone` computed
    /// property for a typed `TimeZone` value.
    var cameraTimezoneIdentifier: String

    /// The timezone the camera clock was set to when the images were captured.
    /// Used by adapters to interpret bare EXIF date strings (which carry no UTC
    /// offset) as absolute points in time — most importantly for GPX matching.
    var cameraTimezone: TimeZone {
        get { TimeZone(identifier: cameraTimezoneIdentifier) ?? .current }
        set { cameraTimezoneIdentifier = newValue.identifier }
    }

    init(
        sourceKind: ImportSourceKind,
        scope: ImportScope,
        emptyValuePolicy: ImportEmptyValuePolicy,
        matchStrategy: ImportMatchStrategy,
        rowParityStartRow: Int,
        rowParityRowCount: Int,
        sourceURLPath: String?,
        auxiliaryURLPaths: [String],
        selectedTagIDs: [String],
        gpxToleranceSeconds: Int,
        gpxCameraOffsetSeconds: Int,
        referenceFolderRowFallbackEnabled: Bool = false,
        cameraTimezoneIdentifier: String
    ) {
        self.sourceKind = sourceKind
        self.scope = scope
        self.emptyValuePolicy = emptyValuePolicy
        self.matchStrategy = matchStrategy
        self.rowParityStartRow = rowParityStartRow
        self.rowParityRowCount = rowParityRowCount
        self.sourceURLPath = sourceURLPath
        self.auxiliaryURLPaths = auxiliaryURLPaths
        self.selectedTagIDs = selectedTagIDs
        self.gpxToleranceSeconds = gpxToleranceSeconds
        self.gpxCameraOffsetSeconds = gpxCameraOffsetSeconds
        self.referenceFolderRowFallbackEnabled = referenceFolderRowFallbackEnabled
        self.cameraTimezoneIdentifier = cameraTimezoneIdentifier
    }

    static func defaults(for sourceKind: ImportSourceKind) -> ImportRunOptions {
        ImportRunOptions(
            sourceKind: sourceKind,
            scope: .folder,
            emptyValuePolicy: .clear,
            matchStrategy: sourceKind == .csv || sourceKind == .eos1v ? .rowParity : .filename,
            rowParityStartRow: 1,
            rowParityRowCount: 0,
            sourceURLPath: nil,
            auxiliaryURLPaths: [],
            selectedTagIDs: [],
            gpxToleranceSeconds: 600,
            gpxCameraOffsetSeconds: 0,
            referenceFolderRowFallbackEnabled: false,
            cameraTimezoneIdentifier: TimeZone.current.identifier
        )
    }

    var sourceURL: URL? {
        guard let sourceURLPath, !sourceURLPath.isEmpty else { return nil }
        return URL(fileURLWithPath: sourceURLPath)
    }

    var auxiliaryURLs: [URL] {
        auxiliaryURLPaths.map { URL(fileURLWithPath: $0) }
    }

    private enum CodingKeys: String, CodingKey {
        case sourceKind
        case scope
        case emptyValuePolicy
        case matchStrategy
        case rowParityStartRow
        case rowParityRowCount
        case sourceURLPath
        case auxiliaryURLPaths
        case selectedTagIDs
        case gpxToleranceSeconds
        case gpxCameraOffsetSeconds
        case referenceFolderRowFallbackEnabled
        case cameraTimezoneIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceKind = try container.decode(ImportSourceKind.self, forKey: .sourceKind)
        scope = try container.decode(ImportScope.self, forKey: .scope)
        emptyValuePolicy = try container.decode(ImportEmptyValuePolicy.self, forKey: .emptyValuePolicy)
        matchStrategy = try container.decode(ImportMatchStrategy.self, forKey: .matchStrategy)
        rowParityStartRow = try container.decode(Int.self, forKey: .rowParityStartRow)
        rowParityRowCount = try container.decode(Int.self, forKey: .rowParityRowCount)
        sourceURLPath = try container.decodeIfPresent(String.self, forKey: .sourceURLPath)
        auxiliaryURLPaths = try container.decode([String].self, forKey: .auxiliaryURLPaths)
        selectedTagIDs = try container.decode([String].self, forKey: .selectedTagIDs)
        gpxToleranceSeconds = try container.decode(Int.self, forKey: .gpxToleranceSeconds)
        gpxCameraOffsetSeconds = try container.decode(Int.self, forKey: .gpxCameraOffsetSeconds)
        referenceFolderRowFallbackEnabled = try container.decodeIfPresent(Bool.self, forKey: .referenceFolderRowFallbackEnabled) ?? false
        cameraTimezoneIdentifier = try container.decode(String.self, forKey: .cameraTimezoneIdentifier)
    }
}

struct ImportPreparedRun: Hashable, Sendable {
    let options: ImportRunOptions
    let parsedAsSourceKind: ImportSourceKind
    let parseResult: ImportParseResult
    let matchResult: ImportMatchResult
    let previewSummary: ImportPreviewSummary
}

struct ImportStageSummary: Hashable, Sendable {
    let stagedFiles: Int
    let stagedFields: Int
    let skippedFields: Int
    let warnings: [String]
}

extension ImportSourceKind: Identifiable {
    var id: String { rawValue }
}
