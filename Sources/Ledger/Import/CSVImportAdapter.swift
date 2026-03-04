import Foundation

struct CSVImportAdapter: ImportSourceAdapter {
    let sourceKind: ImportSourceKind = .csv

    private static let filenameAliases: Set<String> = [
        "filename",
        "file",
        "name",
        "sourcefile",
        "image",
        "imagefile",
        "photo",
    ]

    func suggestColumnPlan(sourceURL: URL, tagCatalog: [ImportTagDescriptor]) throws -> ImportCSVColumnPlan {
        let rows = try loadRows(sourceURL: sourceURL)
        guard let headerRow = rows.first, !headerRow.isEmpty else {
            throw ImportAdapterError.invalidSchema("CSV is empty.")
        }

        let suggestions = buildSuggestedDestinations(headerRow: headerRow, tagCatalog: tagCatalog)
        let duplicateNormalizedHeaders = duplicateHeaderKeys(in: headerRow)
        let sampleRows = Array(rows.dropFirst())
        let entries: [ImportColumnMappingEntry] = headerRow.enumerated().map { index, header in
            let trimmedHeader = CSVSupport.trim(header)
            let normalized = CSVSupport.normalizedHeader(header)
            let displayName: String
            if trimmedHeader.isEmpty {
                displayName = "Column \(index + 1)"
            } else if duplicateNormalizedHeaders.contains(normalized) {
                displayName = "\(trimmedHeader) (col \(index + 1))"
            } else {
                displayName = trimmedHeader
            }
            let sample = firstNonEmptyValue(at: index, rows: sampleRows)
            let suggested = suggestions[index] ?? .ignore
            return ImportColumnMappingEntry(
                columnIndex: index,
                header: header,
                displayName: displayName,
                normalizedHeader: normalized,
                sampleValue: sample,
                suggestedDestination: suggested,
                selectedDestination: suggested
            )
        }
        return ImportCSVColumnPlan(entries: entries)
    }

    func parse(context: ImportParseContext) throws -> ImportParseResult {
        let rows = try loadRows(sourceURL: context.sourceURL)
        guard let headerRow = rows.first, !headerRow.isEmpty else {
            throw ImportAdapterError.invalidSchema("CSV is empty.")
        }

        let plan: ImportCSVColumnPlan
        if let existing = context.options.csvColumnPlan {
            plan = existing
        } else {
            plan = try suggestColumnPlan(sourceURL: context.sourceURL, tagCatalog: context.tagCatalog)
        }
        let activeEntries = plan.entries
            .filter { $0.columnIndex >= 0 && $0.columnIndex < headerRow.count }
            .sorted(by: { $0.columnIndex < $1.columnIndex })
        let tagByID = Dictionary(uniqueKeysWithValues: context.tagCatalog.map { ($0.id, $0) })

        let filenameEntries = activeEntries.filter { $0.selectedDestination == .filename }
        if context.options.matchStrategy == .filename {
            if filenameEntries.isEmpty {
                throw ImportAdapterError.invalidSchema("Filename matching selected, but no column is mapped to Filename.")
            }
            if filenameEntries.count > 1 {
                throw ImportAdapterError.invalidSchema("Multiple columns are mapped to Filename. Choose exactly one.")
            }
        }

        var warnings: [ImportWarning] = []
        var parsedRows: [ImportRow] = []
        var paritySourceRowNumber = 0
        var parityMappedCount = 0
        let parityStartRow = max(1, context.options.rowParityStartRow)
        let parityMaxRows = context.options.rowParityRowCount > 0 ? context.options.rowParityRowCount : Int.max

        for rowIndex in 1..<rows.count {
            let row = rows[rowIndex]
            if row.allSatisfy({ CSVSupport.trim($0).isEmpty }) {
                continue
            }
            let identifier: String
            let selector: ImportTargetSelector
            switch context.options.matchStrategy {
            case .filename:
                guard let filenameColumn = filenameEntries.first?.columnIndex else {
                    throw ImportAdapterError.invalidSchema("Filename matching selected, but no column is mapped to Filename.")
                }
                guard filenameColumn < row.count else {
                    warnings.append(
                        ImportWarning(
                            sourceLine: rowIndex + 1,
                            message: "Missing filename value.",
                            severity: .warning
                        )
                    )
                    continue
                }
                let filename = CSVSupport.trim(row[filenameColumn])
                guard !filename.isEmpty else {
                    warnings.append(
                        ImportWarning(
                            sourceLine: rowIndex + 1,
                            message: "Empty filename value.",
                            severity: .warning
                        )
                    )
                    continue
                }
                identifier = filename
                selector = .filename(filename)
            case .rowParity:
                paritySourceRowNumber += 1
                guard paritySourceRowNumber >= parityStartRow else {
                    continue
                }
                guard parityMappedCount < parityMaxRows else {
                    continue
                }
                parityMappedCount += 1
                identifier = String(format: "Row %03d", paritySourceRowNumber)
                selector = .rowNumber(parityMappedCount)
            }

            var fields: [ImportFieldValue] = []
            for entry in activeEntries {
                guard case let .tag(tagID) = entry.selectedDestination else { continue }
                let columnIndex = entry.columnIndex
                guard columnIndex < row.count else { continue }
                let rawValue = CSVSupport.trim(row[columnIndex])
                guard let descriptor = tagByID[tagID] else { continue }
                guard let normalized = normalizeImportedValue(rawValue, for: descriptor) else {
                    warnings.append(
                        ImportWarning(
                            sourceLine: rowIndex + 1,
                            message: "Row \(rowIndex + 1), Column \"\(entry.displayName)\": value \"\(rawValue)\" is invalid for field \"\(descriptor.label)\". Field skipped.",
                            severity: .warning
                        )
                    )
                    continue
                }
                fields.append(ImportFieldValue(tagID: tagID, value: normalized))
            }

            if fields.isEmpty {
                warnings.append(
                    ImportWarning(
                        sourceLine: rowIndex + 1,
                        message: "No mapped metadata fields found for “\(identifier)”.",
                        severity: .info
                    )
                )
            }

            parsedRows.append(
                ImportRow(
                    sourceLine: rowIndex + 1,
                    sourceIdentifier: identifier,
                    targetSelector: selector,
                    fields: fields
                )
            )
        }

        return ImportParseResult(rows: parsedRows, warnings: warnings)
    }

    private func buildSuggestedDestinations(
        headerRow: [String],
        tagCatalog: [ImportTagDescriptor]
    ) -> [Int: ImportColumnDestination] {
        var mapped: [Int: ImportColumnDestination] = [:]
        let tagMappings = buildTagHeaderMap(tagCatalog: tagCatalog)
        for (index, header) in headerRow.enumerated() {
            let normalized = CSVSupport.normalizedHeader(header)
            if Self.filenameAliases.contains(normalized) {
                mapped[index] = .filename
                continue
            }
            if let tagID = tagMappings[normalized] {
                mapped[index] = .tag(tagID)
            } else {
                mapped[index] = .ignore
            }
        }
        return mapped
    }

    private func buildTagHeaderMap(tagCatalog: [ImportTagDescriptor]) -> [String: String] {
        var map: [String: String] = [:]
        for descriptor in tagCatalog {
            let namespaceKey = "\(descriptor.namespace.rawValue):\(descriptor.key)"
            let namespaceDashKey = "\(descriptor.namespace.rawValue)-\(descriptor.key)"
            let candidates = [
                descriptor.id,
                descriptor.key,
                descriptor.label,
                namespaceKey,
                namespaceDashKey,
            ]
            for candidate in candidates {
                map[CSVSupport.normalizedHeader(candidate)] = descriptor.id
            }
        }
        return map
    }

    private func duplicateHeaderKeys(in headerRow: [String]) -> Set<String> {
        var counts: [String: Int] = [:]
        for header in headerRow {
            let key = CSVSupport.normalizedHeader(header)
            guard !key.isEmpty else { continue }
            counts[key, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.map(\.key))
    }

    private func firstNonEmptyValue(at index: Int, rows: [[String]]) -> String? {
        for row in rows {
            guard index < row.count else { continue }
            let value = CSVSupport.trim(row[index])
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func loadRows(sourceURL: URL) throws -> [[String]] {
        do {
            let data = try Data(contentsOf: sourceURL)
            return try CSVSupport.parseRows(from: data)
        } catch let error as ImportAdapterError {
            throw error
        } catch {
            throw ImportAdapterError.fileReadFailed(error.localizedDescription)
        }
    }

    private func normalizeImportedValue(_ value: String, for descriptor: ImportTagDescriptor) -> String? {
        let trimmed = CSVSupport.trim(value)
        guard !trimmed.isEmpty else { return "" }

        switch descriptor.inputKind {
        case .text:
            return trimmed
        case .dateTime:
            if Self.exifDateFormatter.date(from: trimmed) != nil {
                return trimmed
            }
            if let parsed = Self.iso8601WithFraction.date(from: trimmed) ?? Self.iso8601WithoutFraction.date(from: trimmed) {
                return Self.exifDateFormatter.string(from: parsed)
            }
            return nil
        case .decimal:
            if let decimal = parseDecimal(trimmed) {
                return compactDecimal(decimal)
            }
            return nil
        case .gpsCoordinate:
            if let coordinate = parseCoordinate(trimmed) {
                return compactDecimal(coordinate)
            }
            return nil
        case let .enumChoice(choices):
            if choices.contains(where: { $0.value == trimmed }) {
                return trimmed
            }
            if let match = choices.first(where: { $0.label.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return match.value
            }
            return nil
        }
    }

    private func parseDecimal(_ raw: String) -> Double? {
        if let direct = Double(raw), direct.isFinite {
            return direct
        }
        if raw.contains("/") {
            let parts = raw.split(separator: "/", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count == 2,
               let numerator = Double(parts[0]),
               let denominator = Double(parts[1]),
               denominator != 0 {
                return numerator / denominator
            }
        }
        return nil
    }

    private func parseCoordinate(_ raw: String) -> Double? {
        let upper = raw.uppercased()
        let hasWestOrSouth = upper.contains("W") || upper.contains("S")
        let hasEastOrNorth = upper.contains("E") || upper.contains("N")
        guard let parsed = parseCoordinateNumber(raw) else { return nil }
        if hasWestOrSouth, !hasEastOrNorth {
            return -abs(parsed)
        }
        if hasEastOrNorth, !hasWestOrSouth {
            return abs(parsed)
        }
        return parsed
    }

    private func parseCoordinateNumber(_ raw: String) -> Double? {
        if let direct = Double(raw), direct.isFinite {
            return direct
        }
        let ns = raw as NSString
        let regex = try? NSRegularExpression(pattern: "-?\\d+(?:\\.\\d+)?")
        let matches = regex?.matches(in: raw, range: NSRange(location: 0, length: ns.length)) ?? []
        let numbers: [Double] = matches.compactMap { Double(ns.substring(with: $0.range)) }
        guard let first = numbers.first else { return nil }
        if numbers.count >= 3 {
            let degrees = abs(first)
            let minutes = abs(numbers[1])
            let seconds = abs(numbers[2])
            let composed = degrees + (minutes / 60) + (seconds / 3600)
            return first < 0 ? -composed : composed
        }
        return first
    }

    private func compactDecimal(_ value: Double) -> String {
        let text = String(format: "%.12f", value)
        return text
            .replacingOccurrences(of: #"(\.\d*?[1-9])0+$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\.0+$"#, with: "", options: .regularExpression)
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private nonisolated(unsafe) static let iso8601WithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let iso8601WithoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
