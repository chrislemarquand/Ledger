import ExifEditCore
import Foundation

@MainActor
extension AppModel {
    var activeEditableTags: [EditableTag] {
        activeInspectorFieldCatalog.filter(\.isEnabled).map {
            EditableTag(
                id: $0.id,
                namespace: $0.namespace,
                key: $0.key,
                label: $0.label,
                section: $0.section
            )
        }
    }

    var activeEditableTagsByID: [String: EditableTag] {
        Dictionary(uniqueKeysWithValues: activeEditableTags.map { ($0.id, $0) })
    }

    // MARK: - Canonical EXIF enum values (single source of truth)
    // Labels match ExifTool's PrintConv table exactly.

    static let enumExposureProgram: [ImportEnumChoice] = [
        .init(value: "0", label: "Not Defined"),
        .init(value: "1", label: "Manual"),
        .init(value: "2", label: "Program AE"),
        .init(value: "3", label: "Aperture-priority AE"),
        .init(value: "4", label: "Shutter speed priority AE"),
        .init(value: "5", label: "Creative (Slow speed)"),
        .init(value: "6", label: "Action (High speed)"),
        .init(value: "7", label: "Portrait"),
        .init(value: "8", label: "Landscape"),
        .init(value: "9", label: "Bulb"),
    ]

    static let enumFlash: [ImportEnumChoice] = [
        .init(value: "0",  label: "No Flash"),
        .init(value: "1",  label: "Fired"),
        .init(value: "5",  label: "Fired, Return not detected"),
        .init(value: "7",  label: "Fired, Return detected"),
        .init(value: "8",  label: "On, Did not fire"),
        .init(value: "9",  label: "On, Fired"),
        .init(value: "13", label: "On, Return not detected"),
        .init(value: "15", label: "On, Return detected"),
        .init(value: "16", label: "Off, Did not fire"),
        .init(value: "20", label: "Off, Did not fire, Return not detected"),
        .init(value: "24", label: "Auto, Did not fire"),
        .init(value: "25", label: "Auto, Fired"),
        .init(value: "29", label: "Auto, Fired, Return not detected"),
        .init(value: "31", label: "Auto, Fired, Return detected"),
        .init(value: "32", label: "No flash function"),
        .init(value: "48", label: "Off, No flash function"),
        .init(value: "65", label: "Fired, Red-eye reduction"),
        .init(value: "69", label: "Fired, Red-eye reduction, Return not detected"),
        .init(value: "71", label: "Fired, Red-eye reduction, Return detected"),
        .init(value: "73", label: "On, Red-eye reduction"),
        .init(value: "77", label: "On, Red-eye reduction, Return not detected"),
        .init(value: "79", label: "On, Red-eye reduction, Return detected"),
        .init(value: "80", label: "Off, Red-eye reduction"),
        .init(value: "88", label: "Auto, Did not fire, Red-eye reduction"),
        .init(value: "89", label: "Auto, Fired, Red-eye reduction"),
        .init(value: "93", label: "Auto, Fired, Red-eye reduction, Return not detected"),
        .init(value: "95", label: "Auto, Fired, Red-eye reduction, Return detected"),
    ]

    static let enumMeteringMode: [ImportEnumChoice] = [
        .init(value: "0",   label: "Unknown"),
        .init(value: "1",   label: "Average"),
        .init(value: "2",   label: "Center-weighted average"),
        .init(value: "3",   label: "Spot"),
        .init(value: "4",   label: "Multi-spot"),
        .init(value: "5",   label: "Multi-segment"),
        .init(value: "6",   label: "Partial"),
        .init(value: "255", label: "Other"),
    ]

    static let enumExposureMode: [ImportEnumChoice] = [
        .init(value: "0", label: "Auto"),
        .init(value: "1", label: "Manual"),
        .init(value: "2", label: "Auto bracket"),
    ]

    static let enumWhiteBalance: [ImportEnumChoice] = [
        .init(value: "0", label: "Auto"),
        .init(value: "1", label: "Manual"),
    ]

    static let enumSceneCaptureType: [ImportEnumChoice] = [
        .init(value: "0", label: "Standard"),
        .init(value: "1", label: "Landscape"),
        .init(value: "2", label: "Portrait"),
        .init(value: "3", label: "Night"),
        .init(value: "4", label: "Other"),
    ]

    static func defaultFieldCatalogEntries() -> [FieldCatalogEntry] {
        let ratingEntries = [EditableTag.rating, EditableTag.pick, EditableTag.label].map { tag in
            FieldCatalogEntry(
                id: tag.id,
                namespace: tag.namespace,
                key: tag.key,
                label: tag.label,
                section: tag.section,
                inputKind: .text,
                isEnabled: true
            )
        }

        let defaultOffIDs: Set<String> = [
            // Camera
            "exif-lens-serial",
            // Capture
            "exif-exposure-mode", "exif-white-balance", "exif-scene-capture-type",
            // Location
            "iptc-sublocation", "iptc-city", "iptc-state", "iptc-country", "iptc-country-code",
            // Editorial
            "xmp-headline",
            "xmp-caption-writer", "xmp-credit", "xmp-source", "xmp-instructions", "xmp-job-id",
            // Rights
            "exif-artist", "exif-copyright", "xmp-creator",
            "xmp-copyright-status", "xmp-usage-terms", "xmp-copyright-url",
        ]

        let entries = EditableTag.common.map { tag -> FieldCatalogEntry in
            let inputKind: ImportFieldInputKind
            switch tag.id {
            case "exif-exposure-program":
                inputKind = .enumChoice(AppModel.enumExposureProgram)
            case "exif-exposure-mode":
                inputKind = .enumChoice(AppModel.enumExposureMode)
            case "exif-flash":
                inputKind = .enumChoice(AppModel.enumFlash)
            case "exif-metering-mode":
                inputKind = .enumChoice(AppModel.enumMeteringMode)
            case "exif-white-balance":
                inputKind = .enumChoice(AppModel.enumWhiteBalance)
            case "exif-scene-capture-type":
                inputKind = .enumChoice(AppModel.enumSceneCaptureType)
            case "datetime-modified", "datetime-digitized", "datetime-created":
                inputKind = .dateTime
            case "exif-aperture", "exif-shutter", "exif-iso", "exif-focal", "exif-exposure-comp", "exif-gps-alt", "exif-gps-direction":
                inputKind = .decimal
            case "exif-gps-lat", "exif-gps-lon":
                inputKind = .gpsCoordinate
            case "xmp-copyright-status":
                inputKind = .boolean
            default:
                inputKind = .text
            }
            return FieldCatalogEntry(
                id: tag.id,
                namespace: tag.namespace,
                key: tag.key,
                label: tag.label,
                section: tag.section,
                inputKind: inputKind,
                isEnabled: !defaultOffIDs.contains(tag.id)
            )
        }

        return ratingEntries + entries
    }
}
