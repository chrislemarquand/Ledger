import Foundation

struct ReferenceImageImportAdapter: ImportSourceAdapter {
    let sourceKind: ImportSourceKind = .referenceImage

    func parse(context: ImportParseContext) throws -> ImportParseResult {
        guard ReferenceImportSupport.supportedImageExtensions.contains(context.sourceURL.pathExtension.lowercased()) else {
            throw ImportAdapterError.invalidSchema("Reference image must be a supported image file.")
        }
        guard let snapshot = context.metadataByFile[context.sourceURL] else {
            throw ImportAdapterError.invalidSchema("Couldn’t read metadata from the reference image.")
        }

        let descriptors = ReferenceImportSupport.selectedDescriptors(
            options: context.options,
            catalog: context.tagCatalog
        )
        let fields = ReferenceImportSupport.fieldsFromSnapshot(snapshot: snapshot, descriptors: descriptors)

        var rows: [ImportRow] = []
        rows.reserveCapacity(context.targetFiles.count)
        for (index, targetURL) in context.targetFiles.enumerated() {
            rows.append(
                ImportRow(
                    sourceLine: index + 1,
                    sourceIdentifier: targetURL.lastPathComponent,
                    targetSelector: .direct(targetURL),
                    fields: fields
                )
            )
        }

        return ImportParseResult(rows: rows, warnings: [])
    }
}
