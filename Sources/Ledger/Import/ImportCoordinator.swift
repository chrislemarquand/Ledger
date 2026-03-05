import ExifEditCore
import Foundation

@MainActor
final class ImportCoordinator {
    typealias MetadataProvider = (_ files: [URL]) async -> [URL: FileMetadataSnapshot]

    private let matcher = ImportMatcher()
    private let resolver = ImportConflictResolver()
    private let csvAdapter = CSVImportAdapter()
    private let gpxAdapter = GPXImportAdapter()
    private let referenceFolderAdapter = ReferenceFolderImportAdapter()
    private let referenceImageAdapter = ReferenceImageImportAdapter()
    private let eosAdapter = EOS1VImportAdapter()
    private let optionsPrefix = "\(AppBrand.identifierPrefix).import.options."

    func loadPersistedOptions(for sourceKind: ImportSourceKind) -> ImportRunOptions {
        let defaults = UserDefaults.standard
        let key = optionsPrefix + sourceKind.rawValue
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ImportRunOptions.self, from: data)
        else {
            return ImportRunOptions.defaults(for: sourceKind)
        }
        return decoded
    }

    func persist(options: ImportRunOptions) {
        let key = optionsPrefix + options.sourceKind.rawValue
        if let encoded = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    func prepareRun(
        options: ImportRunOptions,
        targetFiles: [URL],
        tagCatalog: [ImportTagDescriptor],
        metadataProvider: MetadataProvider
    ) async throws -> ImportPreparedRun {
        guard let sourceURL = options.sourceURL else {
            throw ImportAdapterError.missingSourceURL
        }
        let metadataFiles = metadataFilesNeeded(options: options, targetFiles: targetFiles)
        let metadata = await metadataProvider(Array(metadataFiles))
        let context = ImportParseContext(
            options: options,
            sourceURL: sourceURL,
            auxiliaryURLs: options.auxiliaryURLs,
            targetFiles: targetFiles,
            tagCatalog: tagCatalog,
            metadataByFile: metadata
        )

        let parseResult: ImportParseResult
        let parsedAsSourceKind: ImportSourceKind
        parseResult = try adapter(for: options.sourceKind).parse(context: context)
        parsedAsSourceKind = options.sourceKind

        let matchResult = matcher.match(parseResult: parseResult, targetFiles: targetFiles)
        let summary = ImportPreviewSummary(
            sourceKind: options.sourceKind,
            parsedRows: parseResult.rows.count,
            matchedRows: matchResult.matched.count,
            conflictedRows: matchResult.conflicts.count,
            warnings: matchResult.warnings.count,
            fieldWrites: matchResult.matched.reduce(0) { $0 + $1.row.fields.count }
        )
        persist(options: options)

        return ImportPreparedRun(
            options: options,
            parsedAsSourceKind: parsedAsSourceKind,
            parseResult: parseResult,
            matchResult: matchResult,
            previewSummary: summary
        )
    }

    func resolveAssignments(
        preparedRun: ImportPreparedRun,
        resolutions: [UUID: ImportConflictResolutionChoice]
    ) -> ImportConflictResolveResult {
        resolver.resolve(matchResult: preparedRun.matchResult, resolutions: resolutions)
    }

    private func adapter(for sourceKind: ImportSourceKind) -> ImportSourceAdapter {
        switch sourceKind {
        case .csv:
            return csvAdapter
        case .gpx:
            return gpxAdapter
        case .referenceFolder:
            return referenceFolderAdapter
        case .referenceImage:
            return referenceImageAdapter
        case .eos1v:
            return eosAdapter
        }
    }

    private func metadataFilesNeeded(options: ImportRunOptions, targetFiles: [URL]) -> Set<URL> {
        var files: Set<URL> = []
        switch options.sourceKind {
        case .gpx:
            files.formUnion(targetFiles)
        case .referenceFolder:
            if let folder = options.sourceURL {
                if let sourceFiles = try? FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    files.formUnion(sourceFiles.filter {
                        ReferenceImportSupport.supportedImageExtensions.contains($0.pathExtension.lowercased())
                    })
                }
            }
        case .referenceImage:
            if let source = options.sourceURL {
                files.insert(source)
            }
        case .csv, .eos1v:
            break
        }
        return files
    }
}
