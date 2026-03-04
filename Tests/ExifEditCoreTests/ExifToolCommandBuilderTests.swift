import ExifEditCore
import XCTest

final class ExifToolCommandBuilderTests: XCTestCase {
    func testReadArgumentsIncludeJSONAndFiles() {
        let builder = ExifToolCommandBuilder()
        let files = [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.jpg")
        ]

        let args = builder.readArguments(for: files)

        XCTAssertEqual(args.prefix(3), ["-j", "-G1", "-n"])
        XCTAssertTrue(args.contains("/tmp/a.jpg"))
        XCTAssertTrue(args.contains("/tmp/b.jpg"))
    }

    func testWriteArgumentsIncludeNamespaceTags() {
        let builder = ExifToolCommandBuilder()
        let operation = EditOperation(
            targetFiles: [URL(fileURLWithPath: "/tmp/a.jpg")],
            changes: [
                MetadataPatch(key: "Artist", namespace: .exif, newValue: "Chris"),
                MetadataPatch(key: "Title", namespace: .xmp, newValue: "Sunset")
            ]
        )

        let args = builder.writeArguments(for: operation, file: URL(fileURLWithPath: "/tmp/a.jpg"))

        XCTAssertTrue(args.contains("-EXIF:Artist=Chris"))
        XCTAssertTrue(args.contains("-XMP:Title=Sunset"))
        XCTAssertEqual(args.last, "/tmp/a.jpg")
    }

    func testWriteArgumentsRouteGPSKeysToGPSGroup() {
        let builder = ExifToolCommandBuilder()
        let operation = EditOperation(
            targetFiles: [URL(fileURLWithPath: "/tmp/a.jpg")],
            changes: [
                MetadataPatch(key: "GPSLatitude", namespace: .exif, newValue: "51.5007"),
                MetadataPatch(key: "GPSLatitudeRef", namespace: .exif, newValue: "N"),
                MetadataPatch(key: "GPSLongitude", namespace: .exif, newValue: "0.1246"),
                MetadataPatch(key: "GPSLongitudeRef", namespace: .exif, newValue: "W"),
            ]
        )

        let args = builder.writeArguments(for: operation, file: URL(fileURLWithPath: "/tmp/a.jpg"))

        XCTAssertTrue(args.contains("-GPS:GPSLatitude=51.5007"))
        XCTAssertTrue(args.contains("-GPS:GPSLatitudeRef=N"))
        XCTAssertTrue(args.contains("-GPS:GPSLongitude=0.1246"))
        XCTAssertTrue(args.contains("-GPS:GPSLongitudeRef=W"))
    }
}
