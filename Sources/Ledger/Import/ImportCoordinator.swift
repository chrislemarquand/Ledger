import ExifEditCore
import Foundation

@MainActor
final class ImportCoordinator {
    typealias MetadataProvider = (_ files: [URL]) async -> [URL: FileMetadataSnapshot]

    private let matcher = ImportMatcher()
    private let resolver = ImportConflictResolver()
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
        let metadataFiles = await Task.detached(priority: .userInitiated) {
            Self.metadataFilesNeeded(options: options, targetFiles: targetFiles)
        }.value
        let metadata = await metadataProvider(Array(metadataFiles))
        let tagDescriptorIndex = CSVSupport.buildTagDescriptorIndex(tagCatalog: tagCatalog)
        let context = ImportParseContext(
            options: options,
            sourceURL: sourceURL,
            auxiliaryURLs: options.auxiliaryURLs,
            targetFiles: targetFiles,
            tagCatalog: tagCatalog,
            metadataByFile: metadata,
            tagDescriptorIndex: tagDescriptorIndex
        )

        let parseResult: ImportParseResult
        let parsedAsSourceKind: ImportSourceKind
        parseResult = try await Task.detached(priority: .userInitiated) {
            try Self.parse(sourceKind: options.sourceKind, context: context)
        }.value
        parsedAsSourceKind = options.sourceKind

        let matchResult = matcher.match(parseResult: parseResult, targetFiles: targetFiles, options: options)
        let catalogTagIDs = Set(tagCatalog.map(\.id))
        let activeTagIDs: Set<String>
        if options.selectedTagIDs.isEmpty {
            activeTagIDs = catalogTagIDs
        } else {
            activeTagIDs = Set(options.selectedTagIDs).intersection(catalogTagIDs)
        }
        let summary = ImportPreviewSummary(
            sourceKind: options.sourceKind,
            parsedRows: parseResult.rows.count,
            matchedRows: matchResult.matched.count,
            conflictedRows: matchResult.conflicts.count,
            warnings: matchResult.warnings.count,
            fieldWrites: matchResult.matched.reduce(0) { partial, match in
                let matchedFieldIDs = Set(match.row.fields.map(\.tagID))
                return partial + matchedFieldIDs.intersection(activeTagIDs).count
            }
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

    private nonisolated static func parse(sourceKind: ImportSourceKind, context: ImportParseContext) throws -> ImportParseResult {
        switch sourceKind {
        case .csv:
            return try CSVImportAdapter().parse(context: context)
        case .gpx:
            return try GPXImportAdapter().parse(context: context)
        case .referenceFolder:
            return try ReferenceFolderImportAdapter().parse(context: context)
        case .referenceImage:
            return try ReferenceImageImportAdapter().parse(context: context)
        case .eos1v:
            return try EOS1VImportAdapter().parse(context: context)
        }
    }

    private nonisolated static func metadataFilesNeeded(options: ImportRunOptions, targetFiles: [URL]) -> Set<URL> {
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
