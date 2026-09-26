import LedgerCore
import Foundation

enum LensKind: String, Codable, CaseIterable {
    case prime
    case zoom
}

struct LensProfile: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var kind: LensKind

    /// Prime: its one focal length. Zoom: the wide end.
    var minFocalLengthMM: Int
    /// Prime: mirrors `minFocalLengthMM`. Zoom: the telephoto end.
    var maxFocalLengthMM: Int

    /// Widest (smallest f-number) aperture at the wide end — the lens's only
    /// aperture value for a prime or constant-aperture zoom. Optional because
    /// it isn't always known (e.g. a variable-aperture zoom entered without one).
    var widestApertureAtMinFocal: Double?
    /// Zoom only. Widest aperture at the telephoto end; nil means constant-aperture
    /// (or simply unknown) across the zoom's range.
    var widestApertureAtMaxFocal: Double?

    var notes: String?
    var createdAt: Date
    var updatedAt: Date
}

protocol LensProfileStoreProtocol {
    func loadLensProfiles() throws -> [LensProfile]
    func saveLensProfiles(_ profiles: [LensProfile]) throws
}

struct FileLensProfileStore: LensProfileStoreProtocol {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let profiles: [LensProfile]
    }

    private static let schemaVersion = 1
    private let fileURL: URL

    init(fileURL: URL = FileLensProfileStore.currentFileURL()) {
        self.fileURL = fileURL
    }

    func loadLensProfiles() throws -> [LensProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: data)
        if envelope.schemaVersion > Self.schemaVersion {
            throw MetadataEditError.lensProfileSchemaVersionTooNew
        }
        return envelope.profiles
    }

    func saveLensProfiles(_ profiles: [LensProfile]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let envelope = Envelope(schemaVersion: Self.schemaVersion, profiles: profiles)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)

        let temporaryURL = directory.appendingPathComponent("lens-profiles.tmp.\(UUID().uuidString)")
        try data.write(to: temporaryURL, options: .atomic)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        }
    }

    static func currentFileURL() -> URL {
        AppBrand.currentSupportDirectoryURL()
            .appendingPathComponent("lens-profiles.json", isDirectory: false)
    }
}
