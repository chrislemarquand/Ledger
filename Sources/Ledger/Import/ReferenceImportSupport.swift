import ExifEditCore
import Foundation

enum ReferenceImportSupport {
    static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "tif", "tiff", "png", "heic", "heif", "dng", "arw", "cr2", "cr3", "nef", "orf", "rw2", "raf"
    ]

    static func selectedDescriptors(
        options: ImportRunOptions,
        catalog: [ImportTagDescriptor]
    ) -> [ImportTagDescriptor] {
        guard !options.selectedTagIDs.isEmpty else {
            return catalog
        }
        let selected = Set(options.selectedTagIDs)
        return catalog.filter { selected.contains($0.id) }
    }

    static func fieldsFromSnapshot(
        snapshot: FileMetadataSnapshot,
        descriptors: [ImportTagDescriptor]
    ) -> [ImportFieldValue] {
        descriptors.compactMap { descriptor in
            if descriptor.id == "exif-gps-lat",
               let signed = signedGPSValue(
                   valueKey: "GPSLatitude",
                   refKey: "GPSLatitudeRef",
                   negativeRef: "S",
                   snapshot: snapshot
               )
            {
                return ImportFieldValue(tagID: descriptor.id, value: signed)
            }

            if descriptor.id == "exif-gps-lon",
               let signed = signedGPSValue(
                   valueKey: "GPSLongitude",
                   refKey: "GPSLongitudeRef",
                   negativeRef: "W",
                   snapshot: snapshot
               )
            {
                return ImportFieldValue(tagID: descriptor.id, value: signed)
            }

            guard let field = snapshot.fields.first(where: {
                $0.namespace == descriptor.namespace && $0.key == descriptor.key
            }) else {
                return nil
            }
            return ImportFieldValue(tagID: descriptor.id, value: CSVSupport.trim(field.value))
        }
    }

    private static func signedGPSValue(
        valueKey: String,
        refKey: String,
        negativeRef: String,
        snapshot: FileMetadataSnapshot
    ) -> String? {
        let valueNamespaces: Set<MetadataNamespace> = [.exif, .xmp]
        guard let raw = snapshot.fields.first(where: {
            $0.key == valueKey && valueNamespaces.contains($0.namespace)
        })?.value else {
            return nil
        }

        let trimmed = CSVSupport.trim(raw)
        guard !trimmed.isEmpty else { return nil }

        guard let parsed = parseCoordinateNumber(trimmed) else {
            return trimmed
        }

        let ref = snapshot.fields.first(where: {
            $0.key == refKey && valueNamespaces.contains($0.namespace)
        })?.value.uppercased() ?? ""
        let signed = ref.contains(negativeRef) ? -abs(parsed) : parsed
        return compactDecimal(signed)
    }

    private static func parseCoordinateNumber(_ raw: String) -> Double? {
        let trimmed = CSVSupport.trim(raw)
        guard !trimmed.isEmpty else { return nil }
        if let direct = Double(trimmed) {
            return direct
        }

        let ns = trimmed as NSString
        let regex = try? NSRegularExpression(pattern: "-?\\d+(?:\\.\\d+)?")
        let matches = regex?.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) ?? []
        let numbers = matches.compactMap { Double(ns.substring(with: $0.range)) }

        guard let first = numbers.first else { return nil }
        if numbers.count >= 3 {
            let degrees = abs(first)
            let minutes = abs(numbers[1])
            let seconds = abs(numbers[2])
            let composed = degrees + (minutes / 60) + (seconds / 3600)
            return first < 0 ? -composed : composed
        }
        return first
    }

    private static func compactDecimal(_ value: Double) -> String {
        let text = String(format: "%.12f", value)
        return text
            .replacingOccurrences(of: #"(\.\d*?[1-9])0+$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\.0+$"#, with: "", options: .regularExpression)
    }
}
