import Foundation

struct CSVImportAdapter: ImportSourceAdapter {
    let sourceKind: ImportSourceKind = .csv

    private static let invalidSchemaGuidance = "This CSV is not in ExifTool format. Export using ExifTool/Ledger ExifTool CSV and retry."

    func parse(context: ImportParseContext) throws -> ImportParseResult {
        let rows = try loadRows(sourceURL: context.sourceURL)
        guard let headerRow = rows.first, !headerRow.isEmpty else {
            throw ImportAdapterError.invalidSchema("CSV is empty.")
        }

        let sourceFileColumnIndex = sourceFileColumn(in: headerRow)
        guard isLikelyExifToolCSV(headerRow: headerRow, sourceFileColumnIndex: sourceFileColumnIndex) else {
            throw ImportAdapterError.invalidSchema(Self.invalidSchemaGuidance)
        }
        if context.options.matchStrategy == .filename, sourceFileColumnIndex == nil {
            throw ImportAdapterError.invalidSchema("Filename matching requires an ExifTool SourceFile column. \(Self.invalidSchemaGuidance)")
        }

        let mappedColumns = mappedTagColumns(headerRow: headerRow, tagCatalog: context.tagCatalog)
        guard !mappedColumns.isEmpty else {
            throw ImportAdapterError.invalidSchema("No Ledger-supported ExifTool columns were found. \(Self.invalidSchemaGuidance)")
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

            let sourceFileRaw: String
            if let sourceFileColumnIndex, sourceFileColumnIndex < row.count {
                sourceFileRaw = CSVSupport.trim(row[sourceFileColumnIndex])
            } else {
                sourceFileRaw = ""
            }
            if sourceFileRaw == "*" {
                warnings.append(
                    ImportWarning(
                        sourceLine: rowIndex + 1,
                        message: "SourceFile \"*\" default row is not supported in Ledger CSV import. Row skipped.",
                        severity: .warning
                    )
                )
                continue
            }

            let sourceIdentifierFromPath = normalizedSourceIdentifier(from: sourceFileRaw)
            let identifier: String
            let selector: ImportTargetSelector

            switch context.options.matchStrategy {
            case .filename:
                guard !sourceFileRaw.isEmpty else {
                    warnings.append(
                        ImportWarning(
                            sourceLine: rowIndex + 1,
                            message: "Missing SourceFile value for filename matching.",
                            severity: .warning
                        )
                    )
                    continue
                }
                let fileIdentifier = sourceIdentifierFromPath.isEmpty ? sourceFileRaw : sourceIdentifierFromPath
                identifier = fileIdentifier
                selector = .filename(fileIdentifier)
            case .rowParity:
                paritySourceRowNumber += 1
                guard paritySourceRowNumber >= parityStartRow else {
                    continue
                }
                guard parityMappedCount < parityMaxRows else {
                    continue
                }
                parityMappedCount += 1
                if !sourceIdentifierFromPath.isEmpty {
                    identifier = sourceIdentifierFromPath
                } else {
                    identifier = String(format: "Row %03d", paritySourceRowNumber)
                }
                selector = .rowNumber(parityMappedCount)
            }

            var fields: [ImportFieldValue] = []
            for (columnIndex, descriptor) in mappedColumns {
                guard columnIndex < row.count else { continue }
                let rawValue = CSVSupport.trim(row[columnIndex])
                guard let normalized = normalizeImportedValue(rawValue, for: descriptor) else {
                    warnings.append(
                        ImportWarning(
                            sourceLine: rowIndex + 1,
                            message: "Row \(rowIndex + 1), Column \"\(headerRow[columnIndex])\": value \"\(rawValue)\" is invalid for field \"\(descriptor.label)\". Field skipped.",
                            severity: .warning
                        )
                    )
                    continue
                }
                fields.append(ImportFieldValue(tagID: descriptor.id, value: normalized))
            }

            if fields.isEmpty {
                warnings.append(
                    ImportWarning(
                        sourceLine: rowIndex + 1,
                        message: "No Ledger-supported metadata values found for \"\(identifier)\".",
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

    private func sourceFileColumn(in headerRow: [String]) -> Int? {
        headerRow.firstIndex { CSVSupport.normalizedHeader($0) == "sourcefile" }
    }

    private func isLikelyExifToolCSV(headerRow: [String], sourceFileColumnIndex: Int?) -> Bool {
        if sourceFileColumnIndex != nil {
            return true
        }
        return headerRow.contains { header in
            let trimmed = CSVSupport.trim(header)
            guard !trimmed.isEmpty else { return false }
            return trimmed.contains(":") || trimmed.contains("[") || trimmed.contains("]")
        }
    }

    private func mappedTagColumns(
        headerRow: [String],
        tagCatalog: [ImportTagDescriptor]
    ) -> [(Int, ImportTagDescriptor)] {
        let descriptorIndex = buildTagDescriptorIndex(tagCatalog: tagCatalog)
        var mapped: [(Int, ImportTagDescriptor)] = []

        for (index, header) in headerRow.enumerated() {
            let normalizedHeader = CSVSupport.normalizedHeader(header)
            if normalizedHeader == "sourcefile" {
                continue
            }

            let candidates = [
                normalizedHeader,
                normalizedTagName(fromHeader: header),
            ].filter { !$0.isEmpty }

            var descriptor: ImportTagDescriptor?
            for candidate in candidates {
                if let matched = descriptorIndex[candidate] {
                    descriptor = matched
                    break
                }
            }

            if let descriptor {
                mapped.append((index, descriptor))
            }
        }

        return mapped
    }

    private func buildTagDescriptorIndex(tagCatalog: [ImportTagDescriptor]) -> [String: ImportTagDescriptor] {
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
                let normalized = CSVSupport.normalizedHeader(candidate)
                if normalized.isEmpty { continue }
                if index[normalized] == nil {
                    index[normalized] = descriptor
                }
            }
        }
        return index
    }

    private func normalizedTagName(fromHeader header: String) -> String {
        let trimmed = CSVSupport.trim(header)
        guard !trimmed.isEmpty else { return "" }

        if let range = trimmed.range(of: ":", options: .backwards) {
            return CSVSupport.normalizedHeader(String(trimmed[range.upperBound...]))
        }

        if let range = trimmed.range(of: "]", options: .backwards),
           range.upperBound < trimmed.endIndex {
            return CSVSupport.normalizedHeader(String(trimmed[range.upperBound...]))
        }

        return CSVSupport.normalizedHeader(trimmed)
    }

    private func normalizedSourceIdentifier(from sourceFile: String) -> String {
        let trimmed = CSVSupport.trim(sourceFile)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).lastPathComponent
        }

        if trimmed.contains("\\") {
            let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
            return URL(fileURLWithPath: normalized).lastPathComponent
        }

        return URL(fileURLWithPath: trimmed).lastPathComponent
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
