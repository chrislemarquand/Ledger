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
    /// Original dates snapshotted at sheet-open time from the loaded metadata.
    /// Used in place of live model reads to prevent display churn during background loading.
    var capturedDates: [URL: Date] = [:]
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
    let effectiveChangeFileCount: Int

    static let empty = DateTimeAdjustAssessment(
        rows: [],
        blockingIssues: [],
        warnings: [],
        effectiveChangeFileCount: 0
    )
}

// MARK: - Location Adjust

struct LocationAdjustSession: Identifiable {
    let id = UUID()
    let fileURLs: [URL]
    var searchQuery: String = ""
    var latitude: Double?
    var longitude: Double?
    var includeCoordinates: Bool = true
    var selectedAdvancedFields: Set<LocationAdvancedField> = []
    var resolvedSublocation: String = ""
    var resolvedCity: String = ""
    var resolvedStateProvince: String = ""
    var resolvedCountry: String = ""
    var resolvedCountryCode: String = ""

    func resolvedValue(for field: LocationAdvancedField) -> String {
        switch field {
        case .sublocation:
            return resolvedSublocation
        case .city:
            return resolvedCity
        case .stateProvince:
            return resolvedStateProvince
        case .country:
            return resolvedCountry
        case .countryCode:
            return resolvedCountryCode
        }
    }

    mutating func setResolvedValue(_ value: String, for field: LocationAdvancedField) {
        switch field {
        case .sublocation:
            resolvedSublocation = value
        case .city:
            resolvedCity = value
        case .stateProvince:
            resolvedStateProvince = value
        case .country:
            resolvedCountry = value
        case .countryCode:
            resolvedCountryCode = value
        }
    }
}

enum LocationAdvancedField: String, CaseIterable, Identifiable, Hashable {
    case sublocation
    case city
    case stateProvince
    case country
    case countryCode

    var id: String { rawValue }

    var tagID: String {
        switch self {
        case .sublocation:
            return "iptc-sublocation"
        case .city:
            return "iptc-city"
        case .stateProvince:
            return "iptc-state"
        case .country:
            return "iptc-country"
        case .countryCode:
            return "iptc-country-code"
        }
    }

    var label: String {
        switch self {
        case .sublocation:
            return "Sublocation"
        case .city:
            return "City"
        case .stateProvince:
            return "State / Province"
        case .country:
            return "Country"
        case .countryCode:
            return "Country Code"
        }
    }
}

struct LocationAdjustPreviewRow: Identifiable {
    let id: URL
    let fileName: String
    let originalDisplay: String
    let adjustedDisplay: String
    let deltaText: String
}

struct LocationAdjustAssessment {
    let rows: [LocationAdjustPreviewRow]
    let blockingIssues: [String]
    let warnings: [String]
    let effectiveChangeFileCount: Int

    static let empty = LocationAdjustAssessment(
        rows: [],
        blockingIssues: [],
        warnings: [],
        effectiveChangeFileCount: 0
    )
}
