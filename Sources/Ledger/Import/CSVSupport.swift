import Foundation

enum CSVSupport {
    static let candidateDelimiters: [Character] = [",", ";", "\t", "|"]

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
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }

    static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
