import ExifEditCore
import Foundation

struct GPXImportAdapter: ImportSourceAdapter {
    let sourceKind: ImportSourceKind = .gpx

    func parse(context: ImportParseContext) throws -> ImportParseResult {
        let exifDateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = context.options.cameraTimezone
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            return f
        }()
        let parser = GPXTrackParser()
        let files = [context.sourceURL] + context.auxiliaryURLs
        var points: [GPXTrackPoint] = []

        for fileURL in files {
            do {
                let data = try Data(contentsOf: fileURL)
                points.append(contentsOf: try parser.parse(data: data))
            } catch {
                throw ImportAdapterError.fileReadFailed(error.localizedDescription)
            }
        }
        points.sort(by: { $0.timestamp < $1.timestamp })

        guard !points.isEmpty else {
            throw ImportAdapterError.invalidSchema("No timestamped GPX track points found.")
        }

        var rows: [ImportRow] = []
        var warnings: [ImportWarning] = []

        for (index, fileURL) in context.targetFiles.enumerated() {
            guard let snapshot = context.metadataByFile[fileURL] else {
                warnings.append(
                    ImportWarning(
                        sourceLine: nil,
                        message: "Missing metadata for \(fileURL.lastPathComponent); skipped GPX match.",
                        severity: .warning
                    )
                )
                continue
            }

            guard let captureDate = captureDate(from: snapshot, exifFormatter: exifDateFormatter) else {
                warnings.append(
                    ImportWarning(
                        sourceLine: nil,
                        message: "No capture date for \(fileURL.lastPathComponent); skipped GPX match.",
                        severity: .warning
                    )
                )
                continue
            }

            let shifted = captureDate.addingTimeInterval(TimeInterval(context.options.gpxCameraOffsetSeconds))
            guard let nearest = nearestPoint(to: shifted, in: points) else {
                warnings.append(
                    ImportWarning(
                        sourceLine: nil,
                        message: "No GPX point for \(fileURL.lastPathComponent).",
                        severity: .warning
                    )
                )
                continue
            }

            let delta = abs(nearest.timestamp.timeIntervalSince(shifted))
            if delta > TimeInterval(context.options.gpxToleranceSeconds) {
                warnings.append(
                    ImportWarning(
                        sourceLine: nil,
                        message: "Nearest GPX point for \(fileURL.lastPathComponent) is outside tolerance.",
                        severity: .warning
                    )
                )
                continue
            }

            var fields: [ImportFieldValue] = [
                ImportFieldValue(tagID: "exif-gps-lat", value: compactDecimal(nearest.latitude)),
                ImportFieldValue(tagID: "exif-gps-lon", value: compactDecimal(nearest.longitude)),
            ]
            if let altitude = nearest.altitude {
                fields.append(ImportFieldValue(tagID: "exif-gps-alt", value: compactDecimal(altitude)))
            }

            rows.append(
                ImportRow(
                    sourceLine: index + 1,
                    sourceIdentifier: fileURL.lastPathComponent,
                    targetSelector: .direct(fileURL),
                    fields: fields
                )
            )
        }

        return ImportParseResult(rows: rows, warnings: warnings)
    }

    private func captureDate(from snapshot: FileMetadataSnapshot, exifFormatter: DateFormatter) -> Date? {
        let keys = ["DateTimeOriginal", "CreateDate", "ModifyDate"]
        for key in keys {
            if let field = snapshot.fields.first(where: { $0.namespace == .exif && $0.key == key }),
               let parsed = parseDate(field.value, exifFormatter: exifFormatter) {
                return parsed
            }
        }
        return nil
    }

    private func parseDate(_ raw: String, exifFormatter: DateFormatter) -> Date? {
        if let parsed = exifFormatter.date(from: raw) {
            return parsed
        }
        if let parsed = Self.iso8601Formatter.date(from: raw) {
            return parsed
        }
        return nil
    }

    private func nearestPoint(to date: Date, in points: [GPXTrackPoint]) -> GPXTrackPoint? {
        points.min(by: {
            let d0 = abs($0.timestamp.timeIntervalSince(date))
            let d1 = abs($1.timestamp.timeIntervalSince(date))
            return d0 == d1 ? $0.timestamp < $1.timestamp : d0 < d1
        })
    }

    private func compactDecimal(_ value: Double) -> String {
        let text = String(format: "%.8f", value)
        return text
            .replacingOccurrences(of: #"(\.\d*?[1-9])0+$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\.0+$"#, with: "", options: .regularExpression)
    }


    private nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct GPXTrackPoint: Hashable {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let timestamp: Date
}

private final class GPXTrackParser: NSObject, XMLParserDelegate {
    private var points: [GPXTrackPoint] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var currentEleText = ""
    private var currentTimeText = ""
    private var currentElement = ""

    func parse(data: Data) throws -> [GPXTrackPoint] {
        points.removeAll(keepingCapacity: true)
        currentLat = nil
        currentLon = nil
        currentEle = nil
        currentEleText = ""
        currentTimeText = ""
        currentElement = ""

        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw ImportAdapterError.invalidSchema(parser.parserError?.localizedDescription ?? "Invalid GPX format.")
        }
        return points
    }

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = Self.localName(for: elementName)
        currentElement = name
        if name == "trkpt" {
            currentLat = Double(attributeDict["lat"] ?? "")
            currentLon = Double(attributeDict["lon"] ?? "")
            currentEle = nil
            currentEleText = ""
            currentTimeText = ""
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        switch currentElement {
        case "ele":
            currentEleText += string
        case "time":
            currentTimeText += string
        default:
            break
        }
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        let name = Self.localName(for: elementName)
        if name == "ele" {
            currentEle = Double(CSVSupport.trim(currentEleText))
            currentEleText = ""
        } else if name == "time" {
            currentTimeText = CSVSupport.trim(currentTimeText)
        } else if name == "trkpt" {
            defer {
                currentLat = nil
                currentLon = nil
                currentEle = nil
                currentEleText = ""
                currentTimeText = ""
                currentElement = ""
            }
            guard let latitude = currentLat,
                  let longitude = currentLon,
                  let timestamp = GPXTrackParser.parseTimestamp(currentTimeText)
            else {
                return
            }

            points.append(
                GPXTrackPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: currentEle,
                    timestamp: timestamp
                )
            )
        }
    }

    private nonisolated(unsafe) static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let dateFormatterNoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = CSVSupport.trim(raw)
        guard !trimmed.isEmpty else { return nil }
        if let withFractional = dateFormatter.date(from: trimmed) {
            return withFractional
        }
        return dateFormatterNoFractional.date(from: trimmed)
    }

    private static func localName(for qName: String) -> String {
        qName.split(separator: ":").last.map(String.init) ?? qName
    }
}
