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

enum ImportPendingEditsPolicy: String, CaseIterable, Codable, Sendable {
    case merge
    case replace
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

enum ImportReportStatus: String, Codable, Sendable {
    case matched
    case conflict
    case skipped
    case warning
    case staged
}

struct ImportReportRow: Hashable, Sendable {
    let sourceLine: Int?
    let sourceIdentifier: String
    let targetPath: String?
    let status: ImportReportStatus
    let message: String
}

struct ImportReport: Hashable, Sendable {
    let sourceKind: ImportSourceKind
    let generatedAt: Date
    let summary: ImportPreviewSummary
    let rows: [ImportReportRow]
}

struct ImportRunOptions: Hashable, Codable, Sendable {
    var sourceKind: ImportSourceKind
    var scope: ImportScope
    var emptyValuePolicy: ImportEmptyValuePolicy
    var matchStrategy: ImportMatchStrategy
    var sourceURLPath: String?
    var auxiliaryURLPaths: [String]
    var selectedTagIDs: [String]
    var gpxToleranceSeconds: Int
    var gpxCameraOffsetSeconds: Int

    static func defaults(for sourceKind: ImportSourceKind) -> ImportRunOptions {
        ImportRunOptions(
            sourceKind: sourceKind,
            scope: .folder,
            emptyValuePolicy: .clear,
            matchStrategy: sourceKind == .eos1v ? .rowParity : .filename,
            sourceURLPath: nil,
            auxiliaryURLPaths: [],
            selectedTagIDs: [],
            gpxToleranceSeconds: 600,
            gpxCameraOffsetSeconds: 0
        )
    }

    var sourceURL: URL? {
        guard let sourceURLPath, !sourceURLPath.isEmpty else { return nil }
        return URL(fileURLWithPath: sourceURLPath)
    }

    var auxiliaryURLs: [URL] {
        auxiliaryURLPaths.map { URL(fileURLWithPath: $0) }
    }
}

struct ImportPreparedRun: Hashable, Sendable {
    let options: ImportRunOptions
    let parseResult: ImportParseResult
    let matchResult: ImportMatchResult
    let previewSummary: ImportPreviewSummary
    let report: ImportReport
}

struct ImportStageSummary: Hashable, Sendable {
    let stagedFiles: Int
    let stagedFields: Int
    let skippedFields: Int
    let warnings: [String]
}
