import ExifEditCore
import Foundation
import XCTest

final class ExifToolServiceTests: XCTestCase {
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
