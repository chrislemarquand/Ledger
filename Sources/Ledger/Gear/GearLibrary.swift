import Foundation

struct GearLens: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var focalRange: String           // e.g. "24-105" or "50"
    var maxAperture: Double          // e.g. 4.0; drives default stop list
    var customApertureStops: [String]?  // nil = generated from maxAperture
}

struct GearCamera: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var lensIDs: [UUID] = []         // empty = all lenses in library
    var maxShutterSpeed: String?     // e.g. "1/8000"; nil = full list
    var customShutterSpeeds: [String]? // nil = generated from maxShutterSpeed
}

struct GearLibrary: Codable, Equatable {
    var cameras: [GearCamera] = []
    var lenses: [GearLens] = []

    static let empty = GearLibrary()

    // MARK: - Standard sequences

    static let allApertureStops: [Double] = [
        1.0, 1.2, 1.4, 1.8, 2.0, 2.5, 2.8, 3.5, 4.0, 5.0,
        5.6, 6.3, 7.1, 8, 10, 11, 13, 14, 16, 18, 20, 22,
    ]

    static let allShutterSpeeds: [String] = [
        "1/8000", "1/6400", "1/5000", "1/4000", "1/3200", "1/2500",
        "1/2000", "1/1600", "1/1250", "1/1000", "1/800", "1/640",
        "1/500", "1/400", "1/320", "1/250", "1/200", "1/160",
        "1/125", "1/100", "1/80", "1/60", "1/50", "1/40",
        "1/30", "1/25", "1/20", "1/15", "1/13", "1/10",
        "1/8", "1/6", "1/5", "1/4", "1/3", "1/2", "1",
    ]

    // MARK: - Option helpers

    func apertureOptions(for lens: GearLens?) -> [String] {
        guard let lens else { return Self.allApertureStops.map { Self.formatAperture($0) } }
        if let custom = lens.customApertureStops { return custom }
        return Self.allApertureStops
            .filter { $0 >= lens.maxAperture - 0.01 }
            .map { Self.formatAperture($0) }
    }

    func shutterOptions(for camera: GearCamera?) -> [String] {
        guard let camera else { return Self.allShutterSpeeds }
        if let custom = camera.customShutterSpeeds { return custom }
        guard let max = camera.maxShutterSpeed,
              let idx = Self.allShutterSpeeds.firstIndex(of: max)
        else { return Self.allShutterSpeeds }
        return Array(Self.allShutterSpeeds[idx...])
    }

    /// Lenses available for a given camera. Empty lensIDs means all library lenses.
    func availableLenses(for camera: GearCamera?) -> [GearLens] {
        guard let camera, !camera.lensIDs.isEmpty else { return lenses }
        return camera.lensIDs.compactMap { id in lenses.first { $0.id == id } }
    }

    static func formatAperture(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
