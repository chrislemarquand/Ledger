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
            guard let field = snapshot.fields.first(where: {
                $0.namespace == descriptor.namespace && $0.key == descriptor.key
            }) else {
                return nil
            }
            return ImportFieldValue(tagID: descriptor.id, value: CSVSupport.trim(field.value))
        }
    }
}
