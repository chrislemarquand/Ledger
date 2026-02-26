import ExifEditCore
import Foundation

struct PresetFieldValue: Codable, Hashable, Identifiable {
    var id: String { tagID }
    let tagID: String
    let value: String
}

struct MetadataPreset: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var notes: String?
    var fields: [PresetFieldValue]
    var createdAt: Date
    var updatedAt: Date
}

protocol PresetStoreProtocol {
    func loadPresets() throws -> [MetadataPreset]
    func savePresets(_ presets: [MetadataPreset]) throws
}

struct FilePresetStore: PresetStoreProtocol {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let presets: [MetadataPreset]
    }

    private static let schemaVersion = 1
    private let fileURL: URL

    init(fileURL: URL = FilePresetStore.currentFileURL()) {
        self.fileURL = fileURL
    }

    func loadPresets() throws -> [MetadataPreset] {
        let fileManager = FileManager.default
        let candidates = [fileURL] + Self.legacyFileURLs()
        guard let sourceURL = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return []
        }

        let data = try Data(contentsOf: sourceURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: data)
        if envelope.schemaVersion > Self.schemaVersion {
            throw ExifEditError.presetSchemaVersionTooNew
        }
        return envelope.presets
    }

    func savePresets(_ presets: [MetadataPreset]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let envelope = Envelope(schemaVersion: Self.schemaVersion, presets: presets)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)

        let temporaryURL = directory.appendingPathComponent("presets.tmp.\(UUID().uuidString)")
        try data.write(to: temporaryURL, options: .atomic)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        }
    }

    static func currentFileURL() -> URL {
        AppBrand.currentSupportDirectoryURL()
            .appendingPathComponent("presets.json", isDirectory: false)
    }

    private static func legacyFileURLs() -> [URL] {
        AppBrand.legacySupportDirectoryURLs().map {
            $0.appendingPathComponent("presets.json", isDirectory: false)
        }
    }
}

struct PresetEditorState: Identifiable, Hashable {
    enum Mode: Hashable {
        case createFromCurrent
        case createBlank
        case edit(UUID)
    }

    let id: UUID
    var mode: Mode
    var name: String
    var notes: String
    var includedTagIDs: Set<String>
    var valuesByTagID: [String: String]

    init(
        id: UUID = UUID(),
        mode: Mode,
        name: String,
        notes: String,
        includedTagIDs: Set<String>,
        valuesByTagID: [String: String]
    ) {
        self.id = id
        self.mode = mode
        self.name = name
        self.notes = notes
        self.includedTagIDs = includedTagIDs
        self.valuesByTagID = valuesByTagID
    }
}
