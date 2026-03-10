import Foundation

enum CSVSupport {
    static let candidateDelimiters: [Character] = [",", ";", "\t", "|"]
    private static let coordinateNumberRegex = try! NSRegularExpression(pattern: "-?\\d+(?:\\.\\d+)?")

    static func parseRows(from data: Data) throws -> [[String]] {
        guard let content = decodedString(from: data) else {
            throw ImportAdapterError.fileReadFailed("Unsupported text encoding.")
        }
        return parseRows(from: content)
    }

    static func parseRows(from text: String) -> [[String]] {
        let delimiter = detectDelimiter(in: text)
        return parseRows(from: text, delimiter: delimiter)
    }

    static func parseRows(from text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex

        func flushField() {
            row.append(field)
            field = ""
        }

        func flushRow() {
            rows.append(row)
            row.removeAll(keepingCapacity: true)
        }

        while index < text.endIndex {
            let character = text[index]
            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                if character == "\"" {
                    inQuotes = true
                } else if character == delimiter {
                    flushField()
                } else if character.isNewline {
                    flushField()
                    flushRow()
                    let next = text.index(after: index)
                    if character == "\r", next < text.endIndex, text[next] == "\n" {
                        index = next
                    }
                } else {
                    field.append(character)
                }
            }
            index = text.index(after: index)
        }

        if !field.isEmpty || !row.isEmpty {
            flushField()
            flushRow()
        }

        return rows
    }

    static func parseRowsByCandidateDelimiters(from data: Data) throws -> [(delimiter: Character, rows: [[String]])] {
        guard let content = decodedString(from: data) else {
            throw ImportAdapterError.fileReadFailed("Unsupported text encoding.")
        }
        return candidateDelimiters.map { delimiter in
            (delimiter: delimiter, rows: parseRows(from: content, delimiter: delimiter))
        }
    }

    static func decodedString(from data: Data) -> String? {
        // Deterministic decoder order:
        // 1) UTF variants first (preferred for modern exports),
        // 2) legacy single-byte fallbacks.
        // Note: without a BOM, some CP1252 byte sequences can be valid UTF-8 bytes.
        // In such ambiguous cases we intentionally keep UTF-first behavior.
        let decoders: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .windowsCP1252,
            .isoLatin1,
        ]
        for encoding in decoders {
            if let decoded = String(data: data, encoding: encoding) {
                return decoded
            }
        }
        return nil
    }

    private static func detectDelimiter(in text: String) -> Character {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map(trim)
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return "," }

        var bestDelimiter: Character = ","
        var bestScore = Int.min

        for candidate in candidateDelimiters {
            let sample = lines.prefix(20)
            let rows = sample.map { parseRows(from: $0, delimiter: candidate).first ?? [] }
            let multiColumnRows = rows.filter { $0.count > 1 }.count
            let maxColumns = rows.map(\.count).max() ?? 0
            let score = (multiColumnRows * 100) + maxColumns
            if score > bestScore {
                bestScore = score
                bestDelimiter = candidate
            }
        }

        return bestDelimiter
    }

    static func normalizedHeader(_ value: String) -> String {
        let lowercased = trim(value).lowercased()
        guard !lowercased.isEmpty else { return "" }

        var normalized = String()
        normalized.reserveCapacity(lowercased.count)
        for scalar in lowercased.unicodeScalars {
            switch scalar.value {
            case 48...57, 97...122:
                normalized.unicodeScalars.append(scalar)
            default:
                continue
            }
        }
        return normalized
    }

    static func buildTagDescriptorIndex(tagCatalog: [ImportTagDescriptor]) -> [String: ImportTagDescriptor] {
        var index: [String: ImportTagDescriptor] = [:]
        for descriptor in tagCatalog {
            let candidates = [
                descriptor.id,
                descriptor.key,
                descriptor.label,
                "\(descriptor.namespace.rawValue):\(descriptor.key)",
                "\(descriptor.namespace.rawValue)-\(descriptor.key)",
            ]
            for candidate in candidates {
                let normalized = normalizedHeader(candidate)
                if normalized.isEmpty { continue }
                if index[normalized] == nil {
                    index[normalized] = descriptor
                }
            }
        }
        return index
    }

    static func parseCoordinateNumber(_ raw: String) -> Double? {
        let trimmed = trim(raw)
        guard !trimmed.isEmpty else { return nil }
        if let direct = Double(trimmed), direct.isFinite {
            return direct
        }

        let ns = trimmed as NSString
        let matches = coordinateNumberRegex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
        let numbers: [Double] = matches.compactMap { Double(ns.substring(with: $0.range)) }
        let hasExplicitNegative = matches.first
            .map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-") }
            ?? false

        guard let first = numbers.first else { return nil }
        if numbers.count >= 3 {
            let degrees = abs(first)
            let minutes = abs(numbers[1])
            let seconds = abs(numbers[2])
            let composed = degrees + (minutes / 60) + (seconds / 3600)
            return hasExplicitNegative ? -composed : composed
        }
        return first
    }

    static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
