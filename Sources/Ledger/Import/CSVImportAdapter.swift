import Foundation

struct CSVImportAdapter: ImportSourceAdapter {
    let sourceKind: ImportSourceKind = .csv

    private static let invalidSchemaGuidance = "This CSV is not in ExifTool format. Export using ExifTool/Ledger ExifTool CSV and retry."
    private static let firstDecimalRegex = try! NSRegularExpression(pattern: "-?\\d+(?:\\.\\d+)?")

    func parse(context: ImportParseContext) throws -> ImportParseResult {
        let exifDateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = context.options.cameraTimezone
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            return f
        }()
        let rows = try loadRows(sourceURL: context.sourceURL)
        guard let headerRow = rows.first, !headerRow.isEmpty else {
            throw ImportAdapterError.invalidSchema("CSV is empty.")
        }

        let sourceFileColumnIndex = sourceFileColumn(in: headerRow)
        guard isLikelyExifToolCSV(headerRow: headerRow, sourceFileColumnIndex: sourceFileColumnIndex) else {
            throw ImportAdapterError.invalidSchema(Self.invalidSchemaGuidance)
        }

        let descriptorIndex = context.tagDescriptorIndex.isEmpty
            ? CSVSupport.buildTagDescriptorIndex(tagCatalog: context.tagCatalog)
            : context.tagDescriptorIndex
        let mappedColumns = mappedTagColumns(headerRow: headerRow, descriptorIndex: descriptorIndex)
        guard !mappedColumns.isEmpty else {
            throw ImportAdapterError.invalidSchema("No Ledger-supported ExifTool columns were found. \(Self.invalidSchemaGuidance)")
        }

        var warnings: [ImportWarning] = []
        let matching = effectiveMatchingStrategy(
            rows: rows,
            sourceFileColumnIndex: sourceFileColumnIndex,
            targetFiles: context.targetFiles
        )
        if let fallbackReason = matching.fallbackReason {
            warnings.append(
                ImportWarning(
                    sourceLine: nil,
                    message: fallbackReason,
                    severity: .info
                )
            )
        }
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

            switch matching.strategy {
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
                identifier = ImportRowLabelFormatter.fallbackRowLabel(paritySourceRowNumber)
                selector = .rowNumber(parityMappedCount)
            }

            var fieldsByTagID: [String: String] = [:]
            var fieldOrder: [String] = []
            for (columnIndex, descriptor) in mappedColumns {
                guard columnIndex < row.count else { continue }
                let rawValue = CSVSupport.trim(row[columnIndex])
                guard let normalized = normalizeImportedValue(rawValue, for: descriptor, dateFormatter: exifDateFormatter) else {
                    warnings.append(
                        ImportWarning(
                            sourceLine: rowIndex + 1,
                            message: "Row \(rowIndex + 1), Column \"\(headerRow[columnIndex])\": value \"\(rawValue)\" is invalid for field \"\(descriptor.label)\". Field skipped.",
                            severity: .warning
                        )
                    )
                    continue
                }
                if fieldsByTagID[descriptor.id] == nil {
                    fieldOrder.append(descriptor.id)
                }
                // If multiple CSV columns map to the same Ledger tag, keep the last
                // parsed value so row preview counts and staging reflect unique tags.
                fieldsByTagID[descriptor.id] = normalized
            }
            let fields = fieldOrder.map { ImportFieldValue(tagID: $0, value: fieldsByTagID[$0] ?? "") }

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

    private func effectiveMatchingStrategy(
        rows: [[String]],
        sourceFileColumnIndex: Int?,
        targetFiles: [URL]
    ) -> (strategy: ImportMatchStrategy, fallbackReason: String?) {
        guard let sourceFileColumnIndex else {
            return (.rowParity, nil)
        }

        let targetCounts = Dictionary(grouping: targetFiles) { $0.lastPathComponent.lowercased() }
            .mapValues(\.count)
        var seenSourceIdentifiers = Set<String>()
        var sawUsableSourceFile = false

        for row in rows.dropFirst() {
            if row.allSatisfy({ CSVSupport.trim($0).isEmpty }) {
                continue
            }

            guard sourceFileColumnIndex < row.count else {
                return (
                    .rowParity,
                    "Using row-order matching: SourceFile values are incomplete for one or more rows."
                )
            }

            let sourceFileRaw = CSVSupport.trim(row[sourceFileColumnIndex])
            if sourceFileRaw == "*" {
                continue
            }
            let identifier = normalizedSourceIdentifier(from: sourceFileRaw).lowercased()
            guard !identifier.isEmpty else {
                return (
                    .rowParity,
                    "Using row-order matching: SourceFile values are missing for one or more rows."
                )
            }

            sawUsableSourceFile = true
            if !seenSourceIdentifiers.insert(identifier).inserted {
                return (
                    .rowParity,
                    "Using row-order matching: duplicate SourceFile identifiers were found in the CSV."
                )
            }

            if !targetFiles.isEmpty && targetCounts[identifier] != 1 {
                return (
                    .rowParity,
                    "Using row-order matching: SourceFile values do not map uniquely to files in the current scope."
                )
            }
        }

        if sawUsableSourceFile {
            return (.filename, nil)
        }
        return (.rowParity, nil)
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
        descriptorIndex: [String: ImportTagDescriptor]
    ) -> [(Int, ImportTagDescriptor)] {
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

    private func normalizeImportedValue(_ value: String, for descriptor: ImportTagDescriptor, dateFormatter: DateFormatter) -> String? {
        let trimmed = CSVSupport.trim(value)
        guard !trimmed.isEmpty else { return "" }

        switch descriptor.inputKind {
        case .text:
            return trimmed
        case .dateTime:
            if let parsed = dateFormatter.date(from: trimmed) {
                return dateFormatter.string(from: parsed)
            }
            if let parsed = Self.iso8601WithFraction.date(from: trimmed) ?? Self.iso8601WithoutFraction.date(from: trimmed) {
                return dateFormatter.string(from: parsed)
            }
            if let parsed = Self.exifWithColonOffset.date(from: trimmed) ?? Self.exifWithBasicOffset.date(from: trimmed) {
                return dateFormatter.string(from: parsed)
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
            if let match = matchEnumChoice(trimmed, choices: choices, descriptorID: descriptor.id) {
                return match
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
        let ns = raw as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = Self.firstDecimalRegex.firstMatch(in: raw, range: range) {
            let token = ns.substring(with: match.range)
            if let value = Double(token), value.isFinite {
                return value
            }
        }
        return nil
    }

    private func matchEnumChoice(_ raw: String, choices: [ImportEnumChoice], descriptorID: String) -> String? {
        if let numeric = Double(raw), numeric.isFinite {
            let rounded = numeric.rounded()
            if abs(numeric - rounded) < 0.000_001 {
                let normalizedValue = String(Int(rounded))
                if choices.contains(where: { $0.value == normalizedValue }) {
                    return normalizedValue
                }
            }
        }

        let normalizedRaw = normalizeEnumText(raw)
        if let direct = choices.first(where: { normalizeEnumText($0.label) == normalizedRaw }) {
            return direct.value
        }

        switch descriptorID {
        case "exif-exposure-program":
            if normalizedRaw.contains("shutter"), let match = choices.first(where: { $0.value == "4" }) { return match.value }
            if normalizedRaw.contains("aperture"), let match = choices.first(where: { $0.value == "3" }) { return match.value }
            if normalizedRaw.contains("program"), let match = choices.first(where: { $0.value == "2" }) { return match.value }
            if normalizedRaw.contains("manual"), let match = choices.first(where: { $0.value == "1" }) { return match.value }
            if normalizedRaw.contains("portrait"), let match = choices.first(where: { $0.value == "7" }) { return match.value }
            if normalizedRaw.contains("landscape"), let match = choices.first(where: { $0.value == "8" }) { return match.value }
        case "exif-flash":
            if normalizedRaw.contains("didnotfire") && normalizedRaw.contains("off"),
               let match = choices.first(where: { $0.value == "16" }) {
                return match.value
            }
            if normalizedRaw == "noflash", let match = choices.first(where: { $0.value == "0" }) { return match.value }
            if normalizedRaw.contains("fired"), let match = choices.first(where: { $0.value == "1" }) { return match.value }
        default:
            break
        }
        return nil
    }

    private func normalizeEnumText(_ raw: String) -> String {
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        var result = String()
        result.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.lowercased()
    }

    private func parseCoordinate(_ raw: String) -> Double? {
        guard let parsed = CSVSupport.parseCoordinateNumber(raw) else { return nil }

        if let direction = coordinateDirection(in: raw) {
            switch direction {
            case .south, .west:
                return -abs(parsed)
            case .north, .east:
                return abs(parsed)
            }
        }
        return parsed
    }

    private enum CoordinateDirection {
        case north
        case south
        case east
        case west
    }

    private func coordinateDirection(in raw: String) -> CoordinateDirection? {
        let tokens = raw
            .uppercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        for token in tokens.reversed() {
            switch token {
            case "N", "NORTH":
                return .north
            case "S", "SOUTH":
                return .south
            case "E", "EAST":
                return .east
            case "W", "WEST":
                return .west
            default:
                continue
            }
        }
        return nil
    }

    private func compactDecimal(_ value: Double) -> String {
        let text = String(format: "%.12f", value)
        return text
            .replacingOccurrences(of: #"(\.\d*?[1-9])0+$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\.0+$"#, with: "", options: .regularExpression)
    }


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

    private static let exifWithColonOffset: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
        return formatter
    }()

    private static let exifWithBasicOffset: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXX"
        return formatter
    }()
}
