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

    static func defaultFieldCatalogEntries() -> [FieldCatalogEntry] {
        let enumExposureProgram: [ImportEnumChoice] = [
            .init(value: "0", label: "Unknown"),
            .init(value: "1", label: "Manual"),
            .init(value: "2", label: "Program AE"),
            .init(value: "3", label: "Aperture Priority"),
            .init(value: "4", label: "Shutter Priority"),
            .init(value: "5", label: "Creative"),
            .init(value: "6", label: "Action"),
            .init(value: "7", label: "Portrait"),
            .init(value: "8", label: "Landscape"),
        ]
        let enumFlash: [ImportEnumChoice] = [
            .init(value: "0", label: "No Flash"),
            .init(value: "1", label: "Fired"),
            .init(value: "5", label: "Fired, No Return"),
            .init(value: "7", label: "Fired, Return Detected"),
            .init(value: "9", label: "On, Did Not Fire"),
            .init(value: "13", label: "On, No Return"),
            .init(value: "15", label: "On, Return Detected"),
            .init(value: "16", label: "Off"),
            .init(value: "24", label: "Auto, Did Not Fire"),
            .init(value: "25", label: "Auto, Fired"),
            .init(value: "29", label: "Auto, Fired, No Return"),
            .init(value: "31", label: "Auto, Fired, Return Detected"),
            .init(value: "32", label: "No Flash"),
            .init(value: "65", label: "Fired, Red-Eye Reduction"),
            .init(value: "69", label: "Fired, Red-Eye, No Return"),
            .init(value: "71", label: "Fired, Red-Eye, Return Detected"),
            .init(value: "73", label: "On, Red-Eye, Did Not Fire"),
            .init(value: "77", label: "On, Red-Eye, No Return"),
            .init(value: "79", label: "On, Red-Eye, Return Detected"),
            .init(value: "89", label: "Auto, Fired, Red-Eye"),
            .init(value: "93", label: "Auto, Fired, Red-Eye, No Return"),
            .init(value: "95", label: "Auto, Fired, Red-Eye, Return Detected"),
        ]
        let enumMeteringMode: [ImportEnumChoice] = [
            .init(value: "0", label: "Unknown"),
            .init(value: "1", label: "Average"),
            .init(value: "2", label: "Center-Weighted Average"),
            .init(value: "3", label: "Spot"),
            .init(value: "4", label: "Multi-Spot"),
            .init(value: "5", label: "Multi-Segment"),
            .init(value: "6", label: "Partial"),
            .init(value: "255", label: "Other"),
        ]

        var entries = EditableTag.common.map { tag -> FieldCatalogEntry in
            let inputKind: ImportFieldInputKind
            switch tag.id {
            case "exif-exposure-program":
                inputKind = .enumChoice(enumExposureProgram)
            case "exif-flash":
                inputKind = .enumChoice(enumFlash)
            case "exif-metering-mode":
                inputKind = .enumChoice(enumMeteringMode)
            case "datetime-modified", "datetime-digitized", "datetime-created":
                inputKind = .dateTime
            case "exif-aperture", "exif-shutter", "exif-iso", "exif-focal", "exif-exposure-comp", "exif-gps-alt", "exif-gps-direction":
                inputKind = .decimal
            case "exif-gps-lat", "exif-gps-lon":
                inputKind = .gpsCoordinate
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
                isEnabled: true
            )
        }

        for tag in [EditableTag.rating, EditableTag.pick, EditableTag.label] {
            entries.append(FieldCatalogEntry(
                id: tag.id,
                namespace: tag.namespace,
                key: tag.key,
                label: tag.label,
                section: tag.section,
                inputKind: .text,
                isEnabled: true
            ))
        }

        return entries
    }
}
