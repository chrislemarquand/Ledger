import ExifEditCore
import Foundation

@MainActor
final class ImportCoordinator {
    typealias MetadataProvider = (_ files: [URL]) async -> [URL: FileMetadataSnapshot]

    private let matcher = ImportMatcher()
    private let resolver = ImportConflictResolver()
    private let reportWriter = ImportReportWriter()
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
        if options.sourceKind == .eos1v {
            do {
                parseResult = try eosAdapter.parse(context: context)
            } catch let eosError as ImportAdapterError {
                switch eosError {
                case .invalidSchema:
                    do {
                        var fallback = try csvAdapter.parse(context: context)
                        fallback = ImportParseResult(
                            rows: fallback.rows,
                            warnings: [ImportWarning(sourceLine: nil, message: "EOS format validation failed; using generic CSV importer.", severity: .warning)] + fallback.warnings
                        )
                        parseResult = fallback
                    } catch let csvError {
                        _ = eosError
                        _ = csvError
                        throw ImportAdapterError.invalidSchema(
                            "Couldn’t parse this file as EOS or generic CSV. Verify file format and try a different Matching option."
                        )
                    }
                default:
                    throw eosError
                }
            }
        } else {
            parseResult = try adapter(for: options.sourceKind).parse(context: context)
        }

        let matchResult = matcher.match(parseResult: parseResult, targetFiles: targetFiles)
        let summary = ImportPreviewSummary(
            sourceKind: options.sourceKind,
            parsedRows: parseResult.rows.count,
            matchedRows: matchResult.matched.count,
            conflictedRows: matchResult.conflicts.count,
            warnings: matchResult.warnings.count,
            fieldWrites: matchResult.matched.reduce(0) { $0 + $1.row.fields.count }
        )
        let report = reportWriter.makeInitialReport(
            sourceKind: options.sourceKind,
            parseResult: parseResult,
            matchResult: matchResult
        )

        persist(options: options)

        return ImportPreparedRun(
            options: options,
            parseResult: parseResult,
            matchResult: matchResult,
            previewSummary: summary,
            report: report
        )
    }

    func resolveAssignments(
        preparedRun: ImportPreparedRun,
        resolutions: [UUID: ImportConflictResolutionChoice]
    ) -> ImportConflictResolveResult {
        resolver.resolve(matchResult: preparedRun.matchResult, resolutions: resolutions)
    }

    func appendStagingRows(
        report: ImportReport,
        stagedAssignments: [ImportAssignment],
        skippedConflicts: [ImportConflict]
    ) -> ImportReport {
        reportWriter.appendStagingRows(
            report: report,
            stagedAssignments: stagedAssignments,
            skippedConflicts: skippedConflicts
        )
    }

    func export(report: ImportReport, to url: URL) throws {
        try reportWriter.writeCSV(report: report, to: url)
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
