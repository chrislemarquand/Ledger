import Foundation

struct ReferenceFolderImportAdapter: ImportSourceAdapter {
    let sourceKind: ImportSourceKind = .referenceFolder

    func parse(context: ImportParseContext) throws -> ImportParseResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: context.sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ImportAdapterError.invalidSchema("Reference folder is unavailable.")
        }

        let sourceFiles: [URL]
        do {
            sourceFiles = try FileManager.default.contentsOfDirectory(
                at: context.sourceURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ).filter { url in
                ReferenceImportSupport.supportedImageExtensions.contains(url.pathExtension.lowercased())
            }
        } catch {
            throw ImportAdapterError.fileReadFailed(error.localizedDescription)
        }

        let descriptors = ReferenceImportSupport.selectedDescriptors(
            options: context.options,
            catalog: context.tagCatalog
        )
        var rows: [ImportRow] = []
        var warnings: [ImportWarning] = []

        for sourceFile in sourceFiles.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            guard let snapshot = context.metadataByFile[sourceFile] else {
                warnings.append(
                    ImportWarning(
                        sourceLine: nil,
                        message: "Couldn’t read metadata for reference file \(sourceFile.lastPathComponent).",
                        severity: .warning
                    )
                )
                continue
            }
            let fields = ReferenceImportSupport.fieldsFromSnapshot(snapshot: snapshot, descriptors: descriptors)
            rows.append(
                ImportRow(
                    sourceLine: rows.count + 1,
                    sourceIdentifier: sourceFile.lastPathComponent,
                    targetSelector: .filename(sourceFile.lastPathComponent),
                    fields: fields
                )
            )
        }

        if sourceFiles.isEmpty {
            warnings.append(
                ImportWarning(
                    sourceLine: nil,
                    message: "Reference folder has no supported image files.",
                    severity: .warning
                )
            )
        }

        return ImportParseResult(rows: rows, warnings: warnings)
    }
}
