import Foundation

public struct MetadataValidator {
    private static let nonWritableKeys: Set<String> = [
        "FileType",
        "MIMEType",
        "Directory",
        "FileName",
        "FileSize"
    ]

    public init() {}

    public func validate(patches: [MetadataPatch]) throws {
        guard !patches.isEmpty else {
            throw ExifEditError.invalidOperation("No metadata changes were provided.")
        }

        for patch in patches {
            if patch.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ExifEditError.invalidOperation("Metadata key cannot be empty.")
            }

            if Self.nonWritableKeys.contains(patch.key) {
                throw ExifEditError.invalidOperation("\(patch.key) is not writable.")
            }

            if patch.valueType == .date {
                _ = try normalizedDate(from: patch.newValue)
            }
        }
    }

    private func normalizedDate(from input: String) throws -> Date {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let parsed = iso.date(from: input) {
            return parsed
        }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy:MM:dd HH:mm:ss"

        if let parsed = fallback.date(from: input) {
            return parsed
        }

        throw ExifEditError.invalidOperation("Invalid date format for \(input).")
    }
}
