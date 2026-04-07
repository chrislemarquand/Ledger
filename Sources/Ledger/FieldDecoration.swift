import Foundation

/// Decoration table for inspector fields that display units alongside numeric values.
///
/// Provides a single source of truth for which tag IDs carry decorative prefixes
/// or suffixes (e.g. "ƒ/2.8", "50 mm"), and for stripping those characters
/// wherever user input or imported data might contain them.
enum FieldDecoration {

    private struct Entry {
        let prefix: String
        let suffix: String
    }

    private static let table: [String: Entry] = [
        "exif-aperture":      Entry(prefix: "\u{0192}/", suffix: ""),
        "exif-focal":         Entry(prefix: "", suffix: " mm"),
        "exif-shutter":       Entry(prefix: "", suffix: " s"),
        "exif-exposure-comp": Entry(prefix: "", suffix: " EV"),
        "xmp-exposure-bias":  Entry(prefix: "", suffix: " EV"),
    ]

    /// Returns `value` with its decorative prefix/suffix applied.
    /// Returns `value` unchanged if the tag has no decoration or the value is empty.
    static func apply(_ value: String, tagID: String) -> String {
        guard let entry = table[tagID], !value.isEmpty else { return value }
        return entry.prefix + value + entry.suffix
    }

    /// Strips any known decorative prefix/suffix variants from `value`.
    /// Case-insensitive. Returns `value` unchanged if the tag has no decoration.
    static func strip(_ value: String, tagID: String) -> String {
        guard table[tagID] != nil else { return value }
        var result = value.trimmingCharacters(in: .whitespaces)

        for prefix in strippablePrefixes(for: tagID) {
            if result.lowercased().hasPrefix(prefix.lowercased()) {
                result = String(result.dropFirst(prefix.count))
                break
            }
        }

        for suffix in strippableSuffixes(for: tagID) {
            if result.lowercased().hasSuffix(suffix.lowercased()) {
                result = String(result.dropLast(suffix.count))
                break
            }
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func strippablePrefixes(for tagID: String) -> [String] {
        switch tagID {
        case "exif-aperture": return ["\u{0192}/", "f/", "F/"]
        default:              return []
        }
    }

    private static func strippableSuffixes(for tagID: String) -> [String] {
        switch tagID {
        case "exif-focal":         return [" mm", "mm"]
        case "exif-shutter":       return [" s", "s"]
        case "exif-exposure-comp",
             "xmp-exposure-bias":  return [" EV", "EV", " ev", "ev"]
        default:                   return []
        }
    }
}
