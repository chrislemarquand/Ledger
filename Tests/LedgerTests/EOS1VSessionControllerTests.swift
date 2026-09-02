@testable import ExifEditMac
import Foundation
import XCTest

// v1.4 Phase 3.4: EOS1VSessionController.loadFilmRolls previously had its own hand-rolled
// CSV field splitter (didn't handle escaped `""` quotes or embedded commas correctly),
// duplicating CSVSupport's proper parser. This locks in that swapping to CSVSupport
// preserves parsing for eos1v-serial's real CSV shape, with an escaped-quote case added
// specifically because that's exactly what the old splitter got wrong.
@MainActor
final class EOS1VSessionControllerTests: XCTestCase {
    private static let header = [
        "Film", "Film loaded date", "Film loaded time", "Frame", "Focal length", "Max aperture",
        "Tv", "Av", "ISO (DX)", "ISO (M)", "Exposure compensation", "Flash exposure compensation",
        "Shooting mode", "Metering mode", "Flash mode", "Film advance", "AF mode",
        "AF point achieving focus", "AF point selection", "Multiple exposure", "Date", "Time",
        "Battery date", "Battery time",
    ].joined(separator: ",")

    private func writeCSV(_ rows: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EOS1VSessionControllerTests-\(UUID().uuidString).csv")
        let text = ([Self.header] + rows).joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testLoadFilmRollsGroupsFramesByFilmAndPreservesFieldOrder() throws {
        let url = try writeCSV([
            "00-13,2026:01:01,10:00:00,1,50,1.8,1/250,f/1.8,100,,0,0,Manual,Evaluative,Off,Normal,One-Shot,Center,Center,Off,2026:01:01,10:00:01,2026:01:01,09:00:00",
            "00-13,2026:01:01,10:00:00,2,50,1.8,1/500,f/1.8,100,,0,0,Manual,Evaluative,Off,Normal,One-Shot,Center,Center,Off,2026:01:01,10:00:05,2026:01:01,09:00:00",
            "00-14,2026:01:02,11:00:00,1,24,2.8,1/125,f/2.8,200,,0,0,Av,Spot,On,Normal,AI Servo,Left,Left,Off,2026:01:02,11:00:01,2026:01:02,10:00:00",
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let rolls = EOS1VSessionController.loadFilmRolls(from: url)

        XCTAssertEqual(rolls.map(\.id), ["00-13", "00-14"])
        XCTAssertEqual(rolls[0].loadedDate, "2026:01:01")
        XCTAssertEqual(rolls[0].loadedTime, "10:00:00")
        XCTAssertEqual(rolls[0].frames.map(\.frameNumber), ["1", "2"])
        XCTAssertEqual(rolls[0].frames[0].tv, "1/250")
        XCTAssertEqual(rolls[0].frames[1].tv, "1/500")
        XCTAssertEqual(rolls[1].id, "00-14")
        XCTAssertEqual(rolls[1].frames.count, 1)
        XCTAssertEqual(rolls[1].frames[0].av, "f/2.8")
        XCTAssertEqual(rolls[1].frames[0].afMode, "AI Servo")
    }

    func testLoadFilmRollsHandlesAQuotedFieldContainingACommaAndAnEscapedQuote() throws {
        // The pre-Phase-3.4 hand-rolled splitter toggled quote state on every `"` and split on
        // every `,` regardless of quoting, so a quoted field like "Shot, ""handheld""" would
        // have been shredded into extra columns. CSVSupport's parser handles this correctly.
        let row = "00-13,2026:01:01,10:00:00,1,50,1.8,1/250,f/1.8,100,,0,0,\"Shot, \"\"handheld\"\"\",Evaluative,Off,Normal,One-Shot,Center,Center,Off,2026:01:01,10:00:01,2026:01:01,09:00:00"
        let url = try writeCSV([row])
        defer { try? FileManager.default.removeItem(at: url) }

        let rolls = EOS1VSessionController.loadFilmRolls(from: url)

        XCTAssertEqual(rolls.count, 1)
        XCTAssertEqual(rolls[0].frames.count, 1)
        XCTAssertEqual(rolls[0].frames[0].shootingMode, "Shot, \"handheld\"")
        // A field downstream of the quoted one must still land correctly -- proof the quoted
        // comma wasn't mistaken for a column separator.
        XCTAssertEqual(rolls[0].frames[0].meteringMode, "Evaluative")
    }

    func testLoadFilmRollsSkipsRowsWithNoFilmIdentifier() throws {
        let url = try writeCSV([
            ",2026:01:01,10:00:00,1,50,1.8,1/250,f/1.8,100,,0,0,Manual,Evaluative,Off,Normal,One-Shot,Center,Center,Off,2026:01:01,10:00:01,2026:01:01,09:00:00",
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(EOS1VSessionController.loadFilmRolls(from: url).isEmpty)
    }

    func testLoadFilmRollsReturnsEmptyForAMissingFile() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EOS1VSessionControllerTests-missing-\(UUID().uuidString).csv")
        XCTAssertTrue(EOS1VSessionController.loadFilmRolls(from: missing).isEmpty)
    }
}
