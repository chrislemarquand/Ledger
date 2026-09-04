import ExifEditCore
import Foundation
import XCTest

final class ExifToolServiceTests: XCTestCase {
    /// Writes an executable fake-exiftool shell script and a matching source file into a
    /// fresh temp directory, mirroring `testReadMetadataPreservesSpecificXMPNamespaces`'s
    /// existing pattern — `ExifToolService(executableURL:)` accepts any executable, so no
    /// real exiftool binary or real photo is needed for write/timeout/partial-failure
    /// coverage.
    private func makeFixture(scriptBody: String) throws -> (source: URL, script: URL, cleanup: () -> Void) {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let source = temp.appendingPathComponent("photo.jpg")
        try Data().write(to: source)

        let script = temp.appendingPathComponent("fake-exiftool.sh")
        try scriptBody.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        return (source, script, { try? FileManager.default.removeItem(at: temp) })
    }

    private func makeOperation(targetFiles: [URL]) -> EditOperation {
        EditOperation(
            targetFiles: targetFiles,
            changes: [MetadataPatch(key: "Title", namespace: .xmp, newValue: "New Title")]
        )
    }

    func testWriteMetadataSucceedsForAllFiles() async throws {
        let (source, script, cleanup) = try makeFixture(scriptBody: """
        #!/bin/zsh
        exit 0
        """)
        defer { cleanup() }

        let service = try ExifToolService(executableURL: script)
        let result = await service.writeMetadata(operation: makeOperation(targetFiles: [source]))

        XCTAssertEqual(result.succeeded, [source])
        XCTAssertTrue(result.failed.isEmpty)
    }

    func testWriteMetadataPartialFailureReportsPerFileErrorAndOthersStillSucceed() async throws {
        // A script that fails only for a file whose path contains "bad" — lets one
        // operation cover both a succeeding and a failing file in the same batch, matching
        // AppModel+ApplyRestore.swift's real per-file EditOperation loop shape.
        let (goodSource, script, cleanup) = try makeFixture(scriptBody: """
        #!/bin/zsh
        for arg in "$@"; do
          if [[ "$arg" == *bad* ]]; then
            echo "Error: fake failure" >&2
            exit 1
          fi
        done
        exit 0
        """)
        defer { cleanup() }

        let badSource = goodSource.deletingLastPathComponent().appendingPathComponent("bad-photo.jpg")
        try Data().write(to: badSource)

        let service = try ExifToolService(executableURL: script)
        let goodResult = await service.writeMetadata(operation: makeOperation(targetFiles: [goodSource]))
        let badResult = await service.writeMetadata(operation: makeOperation(targetFiles: [badSource]))

        XCTAssertEqual(goodResult.succeeded, [goodSource])
        XCTAssertTrue(goodResult.failed.isEmpty)

        XCTAssertTrue(badResult.succeeded.isEmpty)
        XCTAssertEqual(badResult.failed.map(\.fileURL), [badSource])
        XCTAssertTrue(badResult.failed.first?.message.contains("fake failure") ?? false)
    }

    func testWriteMetadataTimesOutWhenExifToolHangs() async throws {
        let (source, script, cleanup) = try makeFixture(scriptBody: """
        #!/bin/zsh
        sleep 30
        exit 0
        """)
        defer { cleanup() }

        // A short writeTimeout keeps this test fast — the deadline/kill mechanism in
        // ExifToolService.run() is timeout-value-relative, not hardcoded, so this exercises
        // the same real code path production traffic uses with its 25s default.
        let service = try ExifToolService(executableURL: script, writeTimeout: 1)
        let start = Date()
        let result = await service.writeMetadata(operation: makeOperation(targetFiles: [source]))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result.succeeded.isEmpty)
        XCTAssertEqual(result.failed.map(\.fileURL), [source])
        XCTAssertTrue(result.failed.first?.message.contains("Timed out") ?? false)
        // Confirms the hung process was actually killed, not merely reported as failed
        // while still running in the background — well under the fake script's 30s sleep.
        XCTAssertLessThan(elapsed, 5)
    }

    func testReadMetadataPreservesSpecificXMPNamespaces() async throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let source = temp.appendingPathComponent("photo.jpg")
        try Data().write(to: source)

        let script = temp.appendingPathComponent("fake-exiftool.sh")
        let scriptContents = """
        #!/bin/zsh
        cat <<'EOF'
        [
          {
            "SourceFile": "\(source.path)",
            "XMP-photoshop:CaptionWriter": "Testing",
            "XMP-iptcCore:Location": "Studio",
            "XMP-xmpRights:UsageTerms": "Editorial use only",
            "XMP-xmpDM:Pick": "1",
            "XMP:Title": "Sunset"
          }
        ]
        EOF
        """
        try scriptContents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let service = try ExifToolService(executableURL: script)
        let snapshots = try await service.readMetadata(files: [source])

        let fields = try XCTUnwrap(snapshots.first?.fields)
        XCTAssertTrue(fields.contains(.init(key: "CaptionWriter", namespace: .xmpPhotoshop, value: "Testing")))
        XCTAssertTrue(fields.contains(.init(key: "Location", namespace: .xmpIptcCore, value: "Studio")))
        XCTAssertTrue(fields.contains(.init(key: "UsageTerms", namespace: .xmpRights, value: "Editorial use only")))
        XCTAssertTrue(fields.contains(.init(key: "Pick", namespace: .xmpDM, value: "1")))
        XCTAssertTrue(fields.contains(.init(key: "Title", namespace: .xmp, value: "Sunset")))
    }
}
