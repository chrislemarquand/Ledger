import Foundation

struct GPXTrackPoint: Hashable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date
}

enum GPXImportError: LocalizedError {
    case unreadable
    case noTrackPoints

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The GPX file could not be parsed."
        case .noTrackPoints:
            return "The GPX file does not contain valid track points with time."
        }
    }
}

enum GPXImporter {
    static func parseTrackPoints(from url: URL) throws -> [GPXTrackPoint] {
        guard let parser = XMLParser(contentsOf: url) else {
            throw GPXImportError.unreadable
        }

        let delegate = GPXTrackParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw GPXImportError.unreadable
        }

        let points = delegate.points.sorted { $0.timestamp < $1.timestamp }
        guard !points.isEmpty else {
            throw GPXImportError.noTrackPoints
        }
        return points
    }
}

private final class GPXTrackParserDelegate: NSObject, XMLParserDelegate {
    private(set) var points: [GPXTrackPoint] = []

    private var currentLatitude: Double?
    private var currentLongitude: Double?
    private var currentTimeString: String?
    private var collectingTime = false
    private var buffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "trkpt" {
            currentLatitude = Double(attributeDict["lat"] ?? "")
            currentLongitude = Double(attributeDict["lon"] ?? "")
            currentTimeString = nil
        } else if elementName == "time" {
            collectingTime = true
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard collectingTime else { return }
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "time" {
            collectingTime = false
            currentTimeString = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if elementName == "trkpt" {
            defer {
                currentLatitude = nil
                currentLongitude = nil
                currentTimeString = nil
            }

            guard let latitude = currentLatitude,
                  let longitude = currentLongitude,
                  let currentTimeString,
                  let timestamp = parseDate(currentTimeString)
            else {
                return
            }

            points.append(
                GPXTrackPoint(
                    latitude: latitude,
                    longitude: longitude,
                    timestamp: timestamp
                )
            )
        }
    }

    private func parseDate(_ value: String) -> Date? {
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601.date(from: value) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: value)
    }
}
