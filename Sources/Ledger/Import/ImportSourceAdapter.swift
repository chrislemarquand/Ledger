import ExifEditCore
import Foundation

struct ImportParseContext: Sendable {
    let options: ImportRunOptions
    let sourceURL: URL
    let auxiliaryURLs: [URL]
    let targetFiles: [URL]
    let tagCatalog: [ImportTagDescriptor]
    let metadataByFile: [URL: FileMetadataSnapshot]
    let tagDescriptorIndex: [String: ImportTagDescriptor]

    init(
        options: ImportRunOptions,
        sourceURL: URL,
        auxiliaryURLs: [URL],
        targetFiles: [URL],
        tagCatalog: [ImportTagDescriptor],
        metadataByFile: [URL: FileMetadataSnapshot],
        tagDescriptorIndex: [String: ImportTagDescriptor] = [:]
    ) {
        self.options = options
        self.sourceURL = sourceURL
        self.auxiliaryURLs = auxiliaryURLs
        self.targetFiles = targetFiles
        self.tagCatalog = tagCatalog
        self.metadataByFile = metadataByFile
        self.tagDescriptorIndex = tagDescriptorIndex
    }
}

protocol ImportSourceAdapter {
    var sourceKind: ImportSourceKind { get }
    func parse(context: ImportParseContext) throws -> ImportParseResult
}

enum ImportAdapterError: LocalizedError {
    case missingSourceURL
    case fileReadFailed(String)
    case invalidSchema(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .missingSourceURL:
            return "Select a source file first."
        case let .fileReadFailed(message):
            return "Couldn’t read source file: \(message)"
        case let .invalidSchema(message):
            return "Import format is invalid: \(message)"
        case let .unsupported(message):
            return message
        }
    }
}
