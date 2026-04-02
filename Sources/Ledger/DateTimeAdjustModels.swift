import Foundation

// MARK: - Mode

enum DateTimeAdjustMode: String, CaseIterable, Identifiable {
    case shift
    case timeZone
    case specific
    case file

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .timeZone: "Time Zone"
        case .shift: "Shift"
        case .specific: "Specific"
        case .file: "File"
        }
    }

    func subtitle(fileCount: Int) -> String {
        let noun = fileCount == 1 ? "1 selected file" : "\(fileCount) selected files"
        switch self {
        case .timeZone: return "Changing \(noun) to a new time zone"
        case .shift: return "Changing \(noun) by set amount"
        case .specific: return "Changing \(noun) to a specific date and time"
        case .file: return "Changing \(noun) to the file creation date and time"
        }
    }
}

// MARK: - Scope

enum DateTimeAdjustScope: String, CaseIterable, Identifiable {
    case single
    case selection
    case folder

    var id: String { rawValue }
}

// MARK: - Target Tag

enum DateTimeTargetTag: String, CaseIterable, Identifiable, Hashable {
    case dateTimeOriginal
    case dateTimeDigitized
    case dateTimeModified

    var id: String { rawValue }

    var editableTagID: String {
        switch self {
        case .dateTimeOriginal: "datetime-created"
        case .dateTimeDigitized: "datetime-digitized"
        case .dateTimeModified: "datetime-modified"
        }
    }

    var displayName: String {
        switch self {
        case .dateTimeOriginal: "Original"
        case .dateTimeDigitized: "Digitised"
        case .dateTimeModified: "Modified"
        }
    }

    static func from(editableTagID: String) -> DateTimeTargetTag? {
        switch editableTagID {
        case "datetime-created": .dateTimeOriginal
        case "datetime-digitized": .dateTimeDigitized
        case "datetime-modified": .dateTimeModified
        default: nil
        }
    }
}

// MARK: - Session

struct DateTimeAdjustSession: Identifiable {
    let id = UUID()
    var mode: DateTimeAdjustMode = .shift
    let scope: DateTimeAdjustScope
    let launchTag: DateTimeTargetTag
    let fileURLs: [URL]
    var sourceTimeZoneID: String = TimeZone.current.identifier
    var closestCity: String = ""
    var targetTimezone: String = ""
    var shiftDays: Int = 0
    var shiftHours: Int = 0
    var shiftMinutes: Int = 0
    var shiftSeconds: Int = 0
    var specificDate: Date = Date()
    var applyTo: Set<DateTimeTargetTag> = [.dateTimeOriginal]
}

// MARK: - Preview

struct DateTimeAdjustPreviewRow: Identifiable {
    let id: URL
    let fileName: String
    let originalDisplay: String
    let adjustedDisplay: String
    let deltaText: String
    let warnings: [String]
}

struct DateTimeAdjustAssessment {
    let rows: [DateTimeAdjustPreviewRow]
    let blockingIssues: [String]
    let warnings: [String]

    static let empty = DateTimeAdjustAssessment(rows: [], blockingIssues: [], warnings: [])
}
