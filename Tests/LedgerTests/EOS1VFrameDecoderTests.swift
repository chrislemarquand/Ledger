@testable import ExifEditMac
import XCTest

/// Stage A gate for the native EOS-1V decoder.
///
/// Fixtures are a real capture from the camera on 2026-08-29 (16 films, 554 frames):
/// - `session-raw.txt` — the raw protocol dump, decoder input.
/// - `session-expected.csv` — the reference decode of that same dump.
/// - `ese1-roll-00-023.csv` — Canon's own ES-E1 Windows export of one of those rolls,
///   i.e. genuine ground truth from the original software.
///
/// The whole point of this suite is that the decoder can be developed and proven with
/// no camera attached.
final class EOS1VFrameDecoderTests: XCTestCase {

    private static func fixture(_ name: String) throws -> String {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/EOS1V")
        return try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func loadFilms() throws -> [EOS1VFilm] {
        let replies = EOS1VRawDump.parse(try Self.fixture("session-raw.txt"))
        return EOS1VRawDump.films(from: replies)
    }

    // MARK: Framing

    func testRawDumpParsesAndChecksumsValidate() throws {
        let replies = EOS1VRawDump.parse(try Self.fixture("session-raw.txt"))
        XCTAssertFalse(replies.isEmpty)
        let bad = replies.filter { !$0.checksumValid }
        XCTAssertTrue(bad.isEmpty, "\(bad.count) replies failed checksum validation")
        // Every reply must echo the command byte that produced it.
        XCTAssertTrue(replies.allSatisfy { $0.echo == $0.command })
    }

    func testSessionContainsExpectedFilms() throws {
        let films = try loadFilms()
        XCTAssertEqual(films.count, 16)
        XCTAssertEqual(films.map(\.frames.count).reduce(0, +), 554)
        XCTAssertEqual(films.first?.filmID, "00-13")
        XCTAssertEqual(films.first?.loadedDate, "2025-10-08")
        XCTAssertEqual(films.first?.loadedTime, "12:27:00")
    }

    /// This camera's mask is `ff ff 0c 3f 00 08 00 3f` — which is *not* the documented
    /// baseline (`ff ff 00 3f …`). Byte 2 has bits 3 and 2 set, i.e. the 2-byte **Bulb
    /// exposure time** item is enabled, where the reference baseline had it off.
    ///
    /// That makes this a genuinely useful fixture: every field after Bulb is shifted two
    /// bytes from the "baseline" positions, so decoding it correctly exercises the
    /// compositional layout rather than a fixed offset table. A fixed-offset decoder
    /// would produce wrong dates for every one of these 554 frames.
    func testCaptureUsesANonBaselineMaskWithBulbEnabled() throws {
        let films = try loadFilms()
        let masks = Set(films.map { Data($0.itemsMask) })
        XCTAssertEqual(masks.count, 1, "expected one mask across the session")

        let mask = try XCTUnwrap(films.first?.itemsMask)
        XCTAssertEqual(mask, [0xFF, 0xFF, 0x0C, 0x3F, 0x00, 0x08, 0x00, 0x3F])
        XCTAssertNotEqual(mask, EOS1VFrameDecoder.baselineMask)

        let layout = EOS1VFrameDecoder.layout(for: mask)
        XCTAssertFalse(layout.hasUnknownItems, "mask sets a bit we cannot identify")
        XCTAssertNotNil(layout.offsets["bulb"], "bulb should be present in this mask")
        // Bulb occupies 2 bytes, pushing the shot date/time later than baseline.
        let baseline = EOS1VFrameDecoder.layout(for: EOS1VFrameDecoder.baselineMask)
        XCTAssertEqual(layout.offsets["shotdate"], (baseline.offsets["shotdate"] ?? 0) + 2)
    }

    // MARK: Layout

    func testBaselineLayoutOffsetsMatchTheDocumentedRecordShape() {
        let layout = EOS1VFrameDecoder.layout(for: EOS1VFrameDecoder.baselineMask)
        XCTAssertFalse(layout.hasUnknownItems)
        XCTAssertEqual(layout.offsets["focal"], 3)
        XCTAssertEqual(layout.offsets["maxap"], 5)
        XCTAssertEqual(layout.offsets["Tv"], 6)
        XCTAssertEqual(layout.offsets["Av"], 7)
        XCTAssertEqual(layout.offsets["ISO"], 8)
        XCTAssertEqual(layout.offsets["expcomp"], 9)
        XCTAssertEqual(layout.offsets["flashcomp"], 10)
        XCTAssertEqual(layout.offsets["flashmode"], 11)
        XCTAssertEqual(layout.offsets["metering"], 12)
        XCTAssertEqual(layout.offsets["mode"], 13)
        XCTAssertEqual(layout.offsets["drive"], 14)
        XCTAssertEqual(layout.offsets["afmode"], 15)
    }

    func testAllOffMaskKeepsOnlyMandatoryFields() {
        // Documented all-off mask: only the mandatory Shooting mode and a pad byte survive.
        let layout = EOS1VFrameDecoder.layout(for: [0xC0, 0x09, 0, 0, 0, 0, 0, 0])
        XCTAssertNotNil(layout.offsets["mode"])
        XCTAssertNotNil(layout.offsets["pad16"])
        XCTAssertNil(layout.offsets["focal"])
        XCTAssertNil(layout.offsets["Tv"])
        XCTAssertFalse(layout.hasUnknownItems)
    }

    // MARK: Value encodings

    func testApexEncodings() {
        XCTAssertEqual(EOS1VFrameDecoder.apexShutter(0x14), "1")      // 1 second
        XCTAssertEqual(EOS1VFrameDecoder.apexAperture(0x18), "8.0")
        XCTAssertEqual(EOS1VFrameDecoder.isoFromSv(0x58), "400")
        XCTAssertEqual(EOS1VFrameDecoder.isoFromSv(0xF0), "")         // no DX code
        XCTAssertEqual(EOS1VFrameDecoder.compensation(0x08), "+1.0")
        XCTAssertEqual(EOS1VFrameDecoder.compensation(0xF8), "-1.0")
        XCTAssertEqual(EOS1VFrameDecoder.compensation(0x05), "+0.7")
        XCTAssertEqual(EOS1VFrameDecoder.compensation(0x00), "0.0")
        XCTAssertEqual(EOS1VFrameDecoder.flashLabel(0x02), "OFF")
        XCTAssertEqual(EOS1VFrameDecoder.flashLabel(0x0A), "TTL autoflash")
        XCTAssertEqual(EOS1VFrameDecoder.flashLabel(0xC9), "E-TTL")
    }

    // MARK: Full-session regression

    func testDecodesEntireSessionIdenticallyToReference() throws {
        let expected = try CSVFixture(text: Self.fixture("session-expected.csv"))
        var decodedRows: [[String: String]] = []

        for film in try loadFilms() {
            for row in EOS1VFrameDecoder.decode(film: film) {
                XCTAssertFalse(row.layoutUntrusted, "film \(film.filmID) frame \(row.frameNumber)")
                decodedRows.append([
                    "Film": film.filmID,
                    "Film loaded date": film.loadedDate ?? "",
                    "Film loaded time": film.loadedTime ?? "",
                    "Frame": String(row.frameNumber),
                    "Focal length": row.focalLength,
                    "Max aperture": row.maxAperture,
                    "Tv": row.tv,
                    "Av": row.av,
                    "ISO (DX)": row.isoDX,
                    "ISO (M)": row.isoManual,
                    "Exposure compensation": row.exposureCompensation,
                    "Flash exposure compensation": row.flashExposureCompensation,
                    "Shooting mode": row.shootingMode,
                    "Metering mode": row.meteringMode,
                    "Flash mode": row.flashMode,
                    "Film advance": row.filmAdvance,
                    "AF mode": row.afMode,
                    "AF point achieving focus": row.afPointAchievingFocus,
                    "AF point selection": row.afPointSelection,
                    "Multiple exposure": row.multipleExposure ? "ON" : "OFF",
                    "Date": row.date,
                    "Time": row.time,
                    "Battery date": row.batteryDate,
                    "Battery time": row.batteryTime,
                ])
            }
        }

        XCTAssertEqual(decodedRows.count, expected.rows.count, "row count")

        var mismatches: [String] = []
        for (index, expectedRow) in expected.rows.enumerated() where index < decodedRows.count {
            for column in expected.columns where column != "raw" {
                let want = expectedRow[column] ?? ""
                let got = decodedRows[index][column] ?? ""
                if want != got {
                    mismatches.append("row \(index + 1) [\(column)] expected \(want.debugDescription) got \(got.debugDescription)")
                }
            }
        }
        XCTAssertTrue(mismatches.isEmpty,
                      "\(mismatches.count) field mismatches:\n" + mismatches.prefix(20).joined(separator: "\n"))
    }

    /// Ground truth: Canon's own ES-E1 Windows export of roll 00-023.
    func testMatchesCanonESE1ExportForRoll00023() throws {
        let rows = try loadFilms()
            .first { $0.filmID == "00-23" }
            .map { EOS1VFrameDecoder.decode(film: $0) }
        let decoded = try XCTUnwrap(rows)

        let reference = try ESE1Fixture(text: Self.fixture("ese1-roll-00-023.csv"))
        XCTAssertEqual(decoded.count, reference.rows.count)

        for row in decoded {
            let want = try XCTUnwrap(reference.rows[row.frameNumber],
                                     "frame \(row.frameNumber) missing from ES-E1 export")
            XCTAssertEqual(row.focalLength, want["Focal length"], "frame \(row.frameNumber) focal")
            XCTAssertEqual(row.maxAperture, want["Max. aperture"], "frame \(row.frameNumber) maxap")
            XCTAssertEqual(row.tv, want["Tv"], "frame \(row.frameNumber) Tv")
            XCTAssertEqual(row.av, want["Av"], "frame \(row.frameNumber) Av")
            XCTAssertEqual(row.shootingMode, want["Shooting mode"], "frame \(row.frameNumber) mode")
            XCTAssertEqual(row.meteringMode, want["Metering mode"], "frame \(row.frameNumber) metering")
            XCTAssertEqual(row.filmAdvance, want["Film advance mode"], "frame \(row.frameNumber) advance")
            XCTAssertEqual(row.afMode, want["AF mode"], "frame \(row.frameNumber) AF")
            XCTAssertEqual(row.flashMode, want["Flash mode"], "frame \(row.frameNumber) flash")
            XCTAssertEqual(row.exposureCompensation, want["Exposure compensation"], "frame \(row.frameNumber) EC")
            XCTAssertEqual(row.flashExposureCompensation, want["Flash exposure compensation"], "frame \(row.frameNumber) FEC")
            XCTAssertEqual(row.time, want["Time"], "frame \(row.frameNumber) time")
            // ES-E1 writes dates as D/M/YYYY; ours are ISO.
            XCTAssertEqual(row.date, Self.isoDate(fromESE1: want["Date"] ?? ""), "frame \(row.frameNumber) date")
        }
    }

    private static func isoDate(fromESE1 value: String) -> String {
        let parts = value.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return value }
        return String(format: "%04d-%02d-%02d", parts[2], parts[1], parts[0])
    }
}

// MARK: - Fixture readers

/// Minimal reader for the reference CSV (header on row 1, no preamble).
private struct CSVFixture {
    let columns: [String]
    let rows: [[String: String]]

    init(text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let header = lines.first.map(CSVFixture.split) ?? []
        columns = header
        rows = lines.dropFirst().map { line in
            Dictionary(uniqueKeysWithValues: zip(header, CSVFixture.split(line)))
        }
    }

    /// Handles the quoted fields the reference writer emits.
    static func split(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            if character == "\"" { inQuotes.toggle() }
            else if character == ",", !inQuotes { fields.append(current); current = "" }
            else { current.append(character) }
        }
        fields.append(current)
        return fields
    }
}

/// Reader for Canon's ES-E1 export: a preamble, then a header row starting "Frame No.",
/// and a leading empty column on every row.
private struct ESE1Fixture {
    /// Keyed by frame number.
    let rows: [Int: [String: String]]

    init(text: String) throws {
        let lines = text.split(whereSeparator: \.isNewline).map { CSVFixture.split(String($0)) }
        guard let headerIndex = lines.firstIndex(where: { $0.contains("Frame No.") }) else {
            throw NSError(domain: "ESE1Fixture", code: 1)
        }
        let header = lines[headerIndex].map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [Int: [String: String]] = [:]
        for line in lines[(headerIndex + 1)...] {
            let values = line.map { field -> String in
                // ES-E1 escapes shutter speeds for Excel as ="1/1000". The CSV splitter
                // has already consumed the quotes, so only the leading "=" remains.
                var value = field.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\"", with: "")
                if value.hasPrefix("=") { value.removeFirst() }
                return value
            }
            let row = Dictionary(uniqueKeysWithValues: zip(header, values))
            guard let number = Int(row["Frame No."] ?? "") else { continue }
            out[number] = row
        }
        rows = out
    }
}
