import Foundation

public struct ExifToolCommandBuilder: Sendable {
    public init() {}

    // Maps a primary XMP/EXIF tag to its IPTC counterpart for dual-write.
    // Lightroom Classic writes both simultaneously; omitting the IPTC tag
    // breaks roundtrip fidelity with older tools that read IPTC only.
    private static let iptcDualWrite: [String: String] = [
        // Existing fields
        "XMP:Title":                           "IPTC:ObjectName",
        "XMP:Description":                     "IPTC:Caption-Abstract",
        "XMP:Subject":                         "IPTC:Keywords",
        "EXIF:Copyright":                      "IPTC:CopyrightNotice",
        "XMP:Creator":                         "IPTC:By-line",
        // Priority 2 — Location Detail
        "XMP-iptcCore:Location":               "IPTC:Sub-location",
        "XMP-photoshop:City":                  "IPTC:City",
        "XMP-photoshop:State":                 "IPTC:Province-State",
        "XMP-photoshop:Country":               "IPTC:Country-PrimaryLocationName",
        "XMP-iptcCore:CountryCode":            "IPTC:Country-PrimaryLocationCode",
        // Priority 3 — Editorial
        "XMP-photoshop:Headline":              "IPTC:Headline",
        "XMP-photoshop:CaptionWriter":         "IPTC:Writer-Editor",
        "XMP-photoshop:Credit":                "IPTC:Credit",
        "XMP-photoshop:Source":                "IPTC:Source",
        "XMP-photoshop:Instructions":          "IPTC:SpecialInstructions",
        "XMP-photoshop:TransmissionReference": "IPTC:OriginalTransmissionReference",
    ]

    public func readArguments(for files: [URL]) -> [String] {
        var args = ["-j", "-G1", "-n"]
        args.append(contentsOf: files.map(\.path))
        return args
    }

    public func writeArguments(for operation: EditOperation, file: URL) -> [String] {
        var args = ["-overwrite_original"]

        for change in operation.changes {
            let tag = writeTag(for: change)
            args.append("-\(tag)=\(change.newValue)")
            if let iptcTag = Self.iptcDualWrite[tag] {
                args.append("-\(iptcTag)=\(change.newValue)")
            }
        }

        args.append(file.path)
        return args
    }

    private func writeTag(for patch: MetadataPatch) -> String {
        // GPS tags must be written in the GPS group so longitude/latitude refs
        // are interpreted consistently by exiftool and image readers.
        if patch.namespace == .exif, patch.key.uppercased().hasPrefix("GPS") {
            return "GPS:\(patch.key)"
        }
        return "\(patch.namespace.rawValue):\(patch.key)"
    }
}
