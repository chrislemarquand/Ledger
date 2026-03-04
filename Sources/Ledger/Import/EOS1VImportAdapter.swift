import Foundation

struct EOS1VImportAdapter: ImportSourceAdapter {
    let sourceKind: ImportSourceKind = .eos1v

    private static let extensionProbeOrder = [".jpg", ".JPG", ".tif", ".TIF", ".tiff", ".TIFF"]
    private static let rowFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumIntegerDigits = 3
        formatter.maximumIntegerDigits = 6
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let outputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static let inputDateFormats = [
        "dd/MM/yyyy HH:mm:ss",
        "d/M/yyyy HH:mm:ss",
        "yyyy/MM/dd HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
    ]

    func parse(context: ImportParseContext) throws -> ImportParseResult {
        let data: Data
        do {
            data = try Data(contentsOf: context.sourceURL)
        } catch {
            throw ImportAdapterError.fileReadFailed(error.localizedDescription)
        }
        let candidates = try CSVSupport.parseRowsByCandidateDelimiters(from: data)
        let best = bestCandidate(from: candidates)
        guard let selected = best else {
            throw ImportAdapterError.invalidSchema("EOS header row not found.")
        }
        let rows = selected.rows
        guard !rows.isEmpty else {
            throw ImportAdapterError.invalidSchema("EOS CSV is empty.")
        }

        guard let headerIndex = findHeaderRowIndex(rows: rows) else {
            throw ImportAdapterError.invalidSchema("EOS header row not found.")
        }

        let header = rows[headerIndex]
        let isoDX = findISODX(fromPreambleRows: Array(rows[..<headerIndex]))
        var parsedRows: [ImportRow] = []
        var warnings: [ImportWarning] = []
        var outputRowNumber = 0
        var paritySourceRowNumber = 0
        let parityStartRow = max(1, context.options.rowParityStartRow)
        let parityMaxRows = context.options.rowParityRowCount > 0 ? context.options.rowParityRowCount : Int.max

        for rowIndex in (headerIndex + 1)..<rows.count {
            let row = rows[rowIndex]
            if row.allSatisfy({ CSVSupport.trim($0).isEmpty }) {
                continue
            }
            let map = dictionary(for: header, values: row)
            let frameNo = columnValue(in: map, matching: ["Frame No.", "Frame No", "Frame", "Frame Number"])
            if frameNo.isEmpty, !looksLikeEOSDataRow(map) {
                continue
            }

            if context.options.matchStrategy == .rowParity {
                paritySourceRowNumber += 1
                if paritySourceRowNumber < parityStartRow {
                    continue
                }
                if outputRowNumber >= parityMaxRows {
                    continue
                }
            }

            outputRowNumber += 1
            let selector = targetSelector(
                for: outputRowNumber,
                strategy: context.options.matchStrategy,
                sourceRowNumber: paritySourceRowNumber
            )
            var fields: [ImportFieldValue] = []

            if let dto = buildDateTimeOriginal(row: map) {
                fields.append(ImportFieldValue(tagID: "datetime-created", value: dto))
            } else {
                warnings.append(
                    ImportWarning(
                        sourceLine: rowIndex + 1,
                        message: "Missing or invalid Date/Time.",
                        severity: .warning
                    )
                )
            }

            appendIfNotEmpty(&fields, tagID: "exif-shutter", value: cleanTv(columnValue(in: map, matching: ["Tv", "Shutter", "Shutter speed"])))
            appendIfNotEmpty(&fields, tagID: "exif-aperture", value: cleanAperture(columnValue(in: map, matching: ["Av", "Aperture", "F Number", "FNumber"])))

            let isoRaw = columnValue(in: map, matching: ["ISO (M)", "ISO(M)", "ISO"])
            let isoValue = extractFirstInteger(from: isoRaw).isEmpty ? isoDX : extractFirstInteger(from: isoRaw)
            appendIfNotEmpty(&fields, tagID: "exif-iso", value: isoValue)

            let focal = normalizeFocalLength(columnValue(in: map, matching: ["Focal length", "Focal Length", "Focal"]))
            appendIfNotEmpty(&fields, tagID: "exif-focal", value: focal)
            appendIfNotEmpty(&fields, tagID: "exif-metering-mode", value: mapMeteringMode(columnValue(in: map, matching: ["Metering mode", "Metering"])))
            appendIfNotEmpty(&fields, tagID: "exif-exposure-program", value: mapExposureProgram(columnValue(in: map, matching: ["Shooting mode", "Exposure mode"])))

            let exposureComp = cleanExposureCompensation(columnValue(in: map, matching: ["Exposure compensation", "Exposure Compensation"]))
            appendIfNotEmpty(&fields, tagID: "exif-exposure-comp", value: exposureComp)

            let flashFired = mapFlashFired(columnValue(in: map, matching: ["Flash mode", "Flash"]))
            appendIfNotEmpty(&fields, tagID: "exif-flash", value: flashFired)

            appendIfNotEmpty(&fields, tagID: "exif-make", value: "Canon")
            appendIfNotEmpty(&fields, tagID: "exif-model", value: "EOS 1V")
            appendIfNotEmpty(&fields, tagID: "xmp-subject", value: "Film")

            appendIfNotEmpty(&fields, tagID: "exif-lens", value: inferLens(focalLength: focal))

            parsedRows.append(
                ImportRow(
                    sourceLine: rowIndex + 1,
                    sourceIdentifier: selector.identifier,
                    targetSelector: selector.selector,
                    fields: fields
                )
            )
        }

        guard !parsedRows.isEmpty else {
            throw ImportAdapterError.invalidSchema("No usable EOS rows found.")
        }
        return ImportParseResult(rows: parsedRows, warnings: warnings)
    }

    private func bestCandidate(from candidates: [(delimiter: Character, rows: [[String]])]) -> (delimiter: Character, rows: [[String]])? {
        var best: (delimiter: Character, rows: [[String]], score: Int)?
        for candidate in candidates {
            guard let headerIndex = findHeaderRowIndex(rows: candidate.rows) else { continue }
            let header = candidate.rows[headerIndex]
            var score = 0
            let headerTokens = Set(header.map(CSVSupport.normalizedHeader).filter { !$0.isEmpty })
            if headerTokens.contains("frameno") || headerTokens.contains("framenumber") {
                score += 50
            }
            if headerTokens.contains("date") && headerTokens.contains("time") {
                score += 20
            }
            if headerTokens.contains("tv") || headerTokens.contains("av") || headerTokens.contains("focallength") {
                score += 20
            }

            let previewRows = candidate.rows.dropFirst(headerIndex + 1).prefix(100)
            var usablePreviewRows = 0
            for row in previewRows {
                let map = dictionary(for: header, values: row)
                let frameNo = columnValue(in: map, matching: ["Frame No.", "Frame No", "Frame", "Frame Number"])
                if !frameNo.isEmpty || looksLikeEOSDataRow(map) {
                    usablePreviewRows += 1
                }
            }
            score += usablePreviewRows

            if best == nil || score > best!.score {
                best = (delimiter: candidate.delimiter, rows: candidate.rows, score: score)
            }
        }
        return best.map { ($0.delimiter, $0.rows) }
    }

    private func findHeaderRowIndex(rows: [[String]]) -> Int? {
        if let index = rows.firstIndex(where: { row in
            let tokens = Set(row.map(CSVSupport.normalizedHeader).filter { !$0.isEmpty })
            return tokens.contains("frameno") || tokens.contains("framenumber")
        }) {
            return index
        }

        return rows.firstIndex { row in
            let tokens = Set(row.map(CSVSupport.normalizedHeader).filter { !$0.isEmpty })
            let hasDateTime = tokens.contains("date") && tokens.contains("time")
            let hasCaptureMarkers = tokens.contains("tv")
                || tokens.contains("av")
                || tokens.contains("isosm")
                || tokens.contains("focallength")
                || tokens.contains("meteringmode")
                || tokens.contains("shootingmode")
            return hasDateTime && hasCaptureMarkers
        }
    }

    private func findISODX(fromPreambleRows rows: [[String]]) -> String {
        for row in rows {
            for (index, cell) in row.enumerated() {
                let normalized = CSVSupport.normalizedHeader(cell)
                if normalized == "isodx" || normalized == "isodxcode" {
                    if index + 1 < row.count {
                        let value = extractFirstInteger(from: row[index + 1])
                        if !value.isEmpty {
                            return value
                        }
                    }
                }
            }
        }
        return ""
    }

    private func dictionary(for header: [String], values: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for (index, key) in header.enumerated() {
            let value = index < values.count ? values[index] : ""
            result[key] = value
            let normalized = CSVSupport.normalizedHeader(key)
            if !normalized.isEmpty, result[normalized] == nil {
                result[normalized] = value
            }
        }
        return result
    }

    private func buildDateTimeOriginal(row: [String: String]) -> String? {
        let date = columnValue(in: row, matching: ["Date"])
        let time = columnValue(in: row, matching: ["Time"])
        guard !date.isEmpty, !time.isEmpty else { return nil }
        let input = "\(date) \(time)"
        var parsedDate: Date?
        for format in Self.inputDateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: input) {
                parsedDate = date
                break
            }
        }
        guard let parsed = parsedDate else { return nil }
        return Self.outputDateFormatter.string(from: parsed)
    }

    private func looksLikeEOSDataRow(_ row: [String: String]) -> Bool {
        let date = columnValue(in: row, matching: ["Date"])
        let time = columnValue(in: row, matching: ["Time"])
        if !date.isEmpty, !time.isEmpty {
            return true
        }

        let signals = [
            columnValue(in: row, matching: ["Tv", "Shutter", "Shutter speed"]),
            columnValue(in: row, matching: ["Av", "Aperture", "F Number", "FNumber"]),
            columnValue(in: row, matching: ["ISO (M)", "ISO(M)", "ISO"]),
            columnValue(in: row, matching: ["Focal length", "Focal Length", "Focal"]),
            columnValue(in: row, matching: ["Metering mode", "Metering"]),
            columnValue(in: row, matching: ["Shooting mode", "Exposure mode"]),
        ]
        return signals.contains { !CSVSupport.trim($0).isEmpty }
    }

    private func columnValue(in row: [String: String], matching keys: [String]) -> String {
        for key in keys {
            if let exact = row[key] {
                let value = CSVSupport.trim(exact)
                if !value.isEmpty {
                    return value
                }
            }
            let normalizedKey = CSVSupport.normalizedHeader(key)
            if let normalized = row[normalizedKey] {
                let value = CSVSupport.trim(normalized)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return ""
    }

    private func targetSelector(
        for outputRowNumber: Int,
        strategy: ImportMatchStrategy,
        sourceRowNumber: Int
    ) -> (selector: ImportTargetSelector, identifier: String) {
        let sourceRowValue = sourceRowNumber > 0 ? sourceRowNumber : outputRowNumber
        let rowString = Self.rowFormatter.string(from: NSNumber(value: sourceRowValue)) ?? String(format: "%03d", sourceRowValue)
        let candidates = Self.extensionProbeOrder.map { "\(rowString)\($0)" }
        let fallback = candidates.first ?? "\(rowString).jpg"
        switch strategy {
        case .filename:
            return (.filename(fallback), fallback)
        case .rowParity:
            return (.rowNumber(outputRowNumber), fallback)
        }
    }

    private func cleanTv(_ raw: String?) -> String {
        var value = CSVSupport.trim(raw ?? "")
        if value.hasPrefix("=") {
            value.removeFirst()
            value = CSVSupport.trim(value)
        }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private func cleanAperture(_ raw: String?) -> String {
        CSVSupport.trim(raw ?? "")
            .lowercased()
            .replacingOccurrences(of: "f/", with: "")
    }

    private func normalizeFocalLength(_ raw: String?) -> String {
        let value = CSVSupport.trim(raw ?? "")
        guard !value.isEmpty else { return "" }
        let digits = value.prefix { $0.isNumber }
        guard !digits.isEmpty else { return value }
        return "\(digits) mm"
    }

    private func mapMeteringMode(_ raw: String?) -> String {
        let value = CSVSupport.trim(raw ?? "")
        switch value.lowercased() {
        case "evaluative", "pattern":
            return "5"
        case "center-weighted average", "centre-weighted average", "center-weighted":
            return "2"
        case "spot":
            return "3"
        case "partial":
            return "6"
        case "average":
            return "1"
        case "multi-spot":
            return "4"
        case "unknown":
            return "0"
        default:
            return value
        }
    }

    private func mapExposureProgram(_ raw: String?) -> String {
        let value = CSVSupport.trim(raw ?? "")
        switch value.lowercased() {
        case "aperture-priority ae":
            return "3"
        case "shutter-speed-priority ae", "shutter speed priority ae":
            return "4"
        case "program ae":
            return "2"
        case "manual exposure", "bulb":
            return "1"
        default:
            return value
        }
    }

    private func mapFlashFired(_ raw: String?) -> String {
        let value = CSVSupport.trim(raw ?? "")
        switch value.lowercased() {
        case "on":
            return "1"
        case "off":
            return "0"
        default:
            return value
        }
    }

    private func extractFirstInteger(from raw: String) -> String {
        let value = CSVSupport.trim(raw)
        guard let match = value.range(of: #"(\d{2,5})"#, options: .regularExpression) else {
            return value
        }
        return String(value[match])
    }

    private func cleanExposureCompensation(_ raw: String?) -> String {
        var value = CSVSupport.trim(raw ?? "")
        guard !value.isEmpty else { return "" }
        value = value
            .replacingOccurrences(of: "EV", with: "")
            .replacingOccurrences(of: "ev", with: "")
            .replacingOccurrences(of: "±0", with: "0")
            .replacingOccurrences(of: " ", with: "")

        if let range = value.range(of: #"^([+-]?)(\d+)\/(\d+)$"#, options: .regularExpression) {
            let body = String(value[range])
            let parts = body.split(separator: "/")
            guard parts.count == 2, let denominator = Double(parts[1]), denominator != 0 else { return value }
            let signedNumerator = Double(parts[0]) ?? 0
            let normalized = signedNumerator / denominator
            return compactDecimalString(normalized)
        }

        if let number = Double(value) {
            return compactDecimalString(number)
        }
        return value
    }

    private func compactDecimalString(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        let asText = String(format: "%.2f", rounded)
        return asText
            .replacingOccurrences(of: #"(\.\d*?[1-9])0+$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\.0+$"#, with: "", options: .regularExpression)
    }

    private func inferLens(focalLength: String) -> String {
        let number = Int(focalLength.prefix { $0.isNumber })
        switch number {
        case 28:
            return "EF28mm ƒ2.8 IS USM"
        case 40:
            return "EF40mm ƒ2.8 STM"
        case 50:
            return "EF50mm ƒ1.8 STM"
        default:
            return "EF24-105mm ƒ4L IS USM"
        }
    }

    private func appendIfNotEmpty(_ fields: inout [ImportFieldValue], tagID: String, value: String) {
        if !CSVSupport.trim(value).isEmpty {
            fields.append(ImportFieldValue(tagID: tagID, value: value))
        }
    }
}
