import ExifEditCore
import XCTest

final class MetadataValidatorTests: XCTestCase {
    func testRejectsEmptyPatchList() {
        let validator = MetadataValidator()

        XCTAssertThrowsError(try validator.validate(patches: []))
    }

    func testRejectsNonWritableKey() {
        let validator = MetadataValidator()
        let patch = MetadataPatch(key: "FileName", namespace: .xmp, newValue: "new")

        XCTAssertThrowsError(try validator.validate(patches: [patch]))
    }

    func testAcceptsISODate() throws {
        let validator = MetadataValidator()
        let patch = MetadataPatch(
            key: "DateTimeOriginal",
            namespace: .exif,
            newValue: "2026-02-20T12:34:56.000Z",
            valueType: .date
        )

        XCTAssertNoThrow(try validator.validate(patches: [patch]))
    }
}
