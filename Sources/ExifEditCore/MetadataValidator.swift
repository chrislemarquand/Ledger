import Foundation

public struct MetadataValidator {
    private nonisolated(unsafe) static let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

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
        if let parsed = Self.isoDateFormatter.date(from: input) {
            return parsed
        }

        if let parsed = Self.exifDateFormatter.date(from: input) {
            return parsed
        }

        throw ExifEditError.invalidOperation("Invalid date format for \(input).")
    }
}
