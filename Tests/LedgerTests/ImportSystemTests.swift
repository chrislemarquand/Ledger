import AppKit
import ExifEditCore
@testable import ExifEditMac
import Foundation
import XCTest

@MainActor
final class ImportSystemTests: XCTestCase {
    func testCSVDefaultsToRowParity() {
        let options = ImportRunOptions.defaults(for: .csv)
        XCTAssertEqual(options.matchStrategy, .rowParity)
    }

    func testCSVImportAdapterParsesFilenameAliasAndMappedFields() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("input.csv")
        try """
        SourceFile,[XMP] Title,[EXIF] ISO
        a.jpg,Alpha,400
        """.write(to: csv, atomically: true, encoding: .utf8)

        var options = ImportRunOptions.defaults(for: .csv)
        options.matchStrategy = .filename
        let context = ImportParseContext(
            options: options,
            sourceURL: csv,
            auxiliaryURLs: [],
            targetFiles: [],
            tagCatalog: [
                .init(id: "xmp-title", key: "Title", namespace: .xmp, label: "Title", section: "Descriptive"),
                .init(id: "exif-iso", key: "ISO", namespace: .exif, label: "ISO", section: "Capture"),
            ],
            metadataByFile: [:]
        )

        let result = try CSVImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows.first?.sourceIdentifier, "a.jpg")
        XCTAssertEqual(result.rows.first?.fields.count, 2)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testCSVImportAdapterSupportsRowParityWithoutFilenameColumn() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("input.csv")
        try """
        [XMP] Title,[EXIF] ISO
        Alpha,400
        Beta,200
        """.write(to: csv, atomically: true, encoding: .utf8)

        var options = ImportRunOptions.defaults(for: .csv)
        options.matchStrategy = .rowParity
        let context = ImportParseContext(
            options: options,
            sourceURL: csv,
            auxiliaryURLs: [],
            targetFiles: [],
            tagCatalog: [
                .init(id: "xmp-title", key: "Title", namespace: .xmp, label: "Title", section: "Descriptive"),
                .init(id: "exif-iso", key: "ISO", namespace: .exif, label: "ISO", section: "Capture"),
            ],
            metadataByFile: [:]
        )

        let result = try CSVImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0].targetSelector, .rowNumber(1))
        XCTAssertEqual(result.rows[1].targetSelector, .rowNumber(2))
    }

    func testCSVImportAdapterRejectsNonExifToolSchema() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("non-exiftool.csv")
        try """
        Title,ISO
        Alpha,400
        """.write(to: csv, atomically: true, encoding: .utf8)

        var options = ImportRunOptions.defaults(for: .csv)
        options.matchStrategy = .rowParity
        let context = ImportParseContext(
            options: options,
            sourceURL: csv,
            auxiliaryURLs: [],
            targetFiles: [],
            tagCatalog: [
                .init(id: "xmp-title", key: "Title", namespace: .xmp, label: "Title", section: "Descriptive"),
                .init(id: "exif-iso", key: "ISO", namespace: .exif, label: "ISO", section: "Capture"),
            ],
            metadataByFile: [:]
        )

        XCTAssertThrowsError(try CSVImportAdapter().parse(context: context)) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("exiftool format"))
        }
    }

    func testCSVImportAdapterIgnoresUnknownExifToolColumns() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("unknown-columns.csv")
        try """
        SourceFile,[XMP] Title,[MakerNotes] Unexpected
        /tmp/a.jpg,Alpha,ignored
        """.write(to: csv, atomically: true, encoding: .utf8)

        var options = ImportRunOptions.defaults(for: .csv)
        options.matchStrategy = .filename
        let context = ImportParseContext(
            options: options,
            sourceURL: csv,
            auxiliaryURLs: [],
            targetFiles: [],
            tagCatalog: [
                .init(id: "xmp-title", key: "Title", namespace: .xmp, label: "Title", section: "Descriptive"),
            ],
            metadataByFile: [:]
        )

        let result = try CSVImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].fields.count, 1)
        XCTAssertEqual(result.rows[0].fields[0].tagID, "xmp-title")
        XCTAssertEqual(result.rows[0].fields[0].value, "Alpha")
    }

    func testCSVImportAdapterFilenameModeRequiresSourceFileColumn() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("filename-required.csv")
        try """
        [XMP] Title
        A
        """.write(to: csv, atomically: true, encoding: .utf8)

        var options = ImportRunOptions.defaults(for: .csv)
        options.matchStrategy = .filename
        let context = ImportParseContext(
            options: options,
            sourceURL: csv,
            auxiliaryURLs: [],
            targetFiles: [],
            tagCatalog: [
                .init(id: "xmp-title", key: "Title", namespace: .xmp, label: "Title", section: "Descriptive"),
            ],
            metadataByFile: [:]
        )

        XCTAssertThrowsError(try CSVImportAdapter().parse(context: context)) { error in
            let message = error.localizedDescription.lowercased()
            XCTAssertTrue(message.contains("exiftool format"))
        }
    }

    func testCSVImportAdapterInvalidEnumValueSkipsFieldWithWarning() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("enum-invalid.csv")
        try """
        SourceFile,Flash
        a.jpg,maybe
        """.write(to: csv, atomically: true, encoding: .utf8)

        var options = ImportRunOptions.defaults(for: .csv)
        options.matchStrategy = .filename

        let context = ImportParseContext(
            options: options,
            sourceURL: csv,
            auxiliaryURLs: [],
            targetFiles: [],
            tagCatalog: [
                .init(
                    id: "exif-flash",
                    key: "Flash",
                    namespace: .exif,
                    label: "Flash",
                    section: "Capture",
                    inputKind: .enumChoice([.init(value: "0", label: "No Flash"), .init(value: "1", label: "Fired")])
                ),
            ],
            metadataByFile: [:]
        )

        let result = try CSVImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertTrue(result.rows[0].fields.isEmpty)
        XCTAssertTrue(result.warnings.contains(where: { $0.message.localizedCaseInsensitiveContains("invalid") }))
    }

    func testCSVImportAdapterRowParityRespectsStartAndCount() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("input.csv")
        try """
        SourceFile,[XMP] Title
        001.jpg,A
        002.jpg,B
        003.jpg,C
        004.jpg,D
        """.write(to: csv, atomically: true, encoding: .utf8)

        var options = ImportRunOptions.defaults(for: .csv)
        options.matchStrategy = .rowParity
        options.rowParityStartRow = 2
        options.rowParityRowCount = 2
        let context = ImportParseContext(
            options: options,
            sourceURL: csv,
            auxiliaryURLs: [],
            targetFiles: [],
            tagCatalog: [
                .init(id: "xmp-title", key: "Title", namespace: .xmp, label: "Title", section: "Descriptive"),
            ],
            metadataByFile: [:]
        )

        let result = try CSVImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0].sourceIdentifier, "002.jpg")
        XCTAssertEqual(result.rows[0].targetSelector, .rowNumber(1))
        XCTAssertEqual(result.rows[1].sourceIdentifier, "003.jpg")
        XCTAssertEqual(result.rows[1].targetSelector, .rowNumber(2))
    }

    func testMatcherFlagsDuplicateSourceIdentifiersAsConflicts() {
        let rows: [ImportRow] = [
            .init(
                sourceLine: 2,
                sourceIdentifier: "dup.jpg",
                targetSelector: .filename("dup.jpg"),
                fields: [.init(tagID: "xmp-title", value: "One")]
            ),
            .init(
                sourceLine: 3,
                sourceIdentifier: "dup.jpg",
                targetSelector: .filename("dup.jpg"),
                fields: [.init(tagID: "xmp-title", value: "Two")]
            ),
        ]
        let parse = ImportParseResult(rows: rows, warnings: [])
        let target = URL(fileURLWithPath: "/tmp/dup.jpg")
        let match = ImportMatcher().match(parseResult: parse, targetFiles: [target])

        XCTAssertTrue(match.matched.isEmpty)
        XCTAssertEqual(match.conflicts.count, 2)
        XCTAssertTrue(match.conflicts.allSatisfy { $0.kind == .duplicateSourceIdentifier })
    }

    func testMatcherMapsRowParityToProvidedTargetOrder() {
        let rows: [ImportRow] = [
            .init(
                sourceLine: 2,
                sourceIdentifier: "Row 001",
                targetSelector: .rowNumber(1),
                fields: [.init(tagID: "xmp-title", value: "One")]
            ),
            .init(
                sourceLine: 3,
                sourceIdentifier: "Row 002",
                targetSelector: .rowNumber(2),
                fields: [.init(tagID: "xmp-title", value: "Two")]
            ),
        ]
        let parse = ImportParseResult(rows: rows, warnings: [])
        let b = URL(fileURLWithPath: "/tmp/002.jpg")
        let a = URL(fileURLWithPath: "/tmp/001.jpg")
        let match = ImportMatcher().match(parseResult: parse, targetFiles: [b, a])

        XCTAssertEqual(match.matched.count, 2)
        XCTAssertEqual(match.matched[0].targetURL.lastPathComponent, "002.jpg")
        XCTAssertEqual(match.matched[1].targetURL.lastPathComponent, "001.jpg")
    }

    func testCoordinatorEOSSchemaInvalidDoesNotFallbackToCSV() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("generic.csv")
        try """
        filename,Title
        a.jpg,Hello
        """.write(to: csv, atomically: true, encoding: .utf8)

        let model = makeModel()
        let target = URL(fileURLWithPath: "/tmp/a.jpg")
        let coordinator = ImportCoordinator()
        var options = ImportRunOptions.defaults(for: .eos1v)
        options.sourceURLPath = csv.path
        options.matchStrategy = .filename
        options.scope = .folder

        do {
            _ = try await coordinator.prepareRun(
                options: options,
                targetFiles: [target],
                tagCatalog: model.importTagCatalog,
                metadataProvider: { _ in [:] }
            )
            XCTFail("Expected EOS parse to fail without CSV fallback")
        } catch {
            let message = error.localizedDescription.lowercased()
            XCTAssertTrue(message.contains("eos"))
            XCTAssertFalse(message.contains("fallback"))
            XCTAssertFalse(message.contains("generic csv"))
        }
    }

    func testEOSAdapterParsesCanonLayoutWithLeadingBlankColumn() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("canon.csv")
        try """
        ,Film ID,00-013,Title,,Date and time film loaded,8/10/2025,12:27:00,Frame count,36,ISO (DX),400
        ,Remarks,

        ,Frame No.,Focal length,Max. aperture,Tv,Av,ISO (M),Exposure compensation,Flash exposure compensation,Flash mode,Metering mode,Shooting mode,Film advance mode,AF mode,Bulb exposure time,Date,Time,Multiple exposure,Battery-loaded date,Battery-loaded time,Remarks
        ,1,50mm,1.8,="1/60",1.8,200,0.0,0.0,OFF,Evaluative,Shutter-speed-priority AE,Single-frame,One-Shot AF,,8/10/2025,12:33:42,OFF,1/1/2000,00:00:00,
        ,2,100mm,4.0,="1/60",8.0,,0.0,0.0,OFF,Evaluative,Shutter-speed-priority AE,Single-frame,One-Shot AF,,8/10/2025,13:09:15,OFF,1/1/2000,00:00:00,
        """.write(to: csv, atomically: true, encoding: .utf8)

        let model = makeModel()
        let targetA = URL(fileURLWithPath: "/tmp/001.jpg")
        let targetB = URL(fileURLWithPath: "/tmp/002.jpg")
        let coordinator = ImportCoordinator()
        var options = ImportRunOptions.defaults(for: .eos1v)
        options.sourceURLPath = csv.path
        options.scope = .folder

        let prepared = try await coordinator.prepareRun(
            options: options,
            targetFiles: [targetA, targetB],
            tagCatalog: model.importTagCatalog,
            metadataProvider: { _ in [:] }
        )

        XCTAssertEqual(prepared.parseResult.rows.count, 2)
        XCTAssertEqual(prepared.parseResult.rows[0].sourceIdentifier.lowercased(), "001.jpg")
        XCTAssertEqual(prepared.parseResult.rows[1].sourceIdentifier.lowercased(), "002.jpg")
        XCTAssertTrue(prepared.parseResult.rows[1].fields.contains(where: { $0.tagID == "exif-iso" && $0.value == "400" }))
    }

    func testEOSAdapterAcceptsHeaderVariantWithoutFrameDot() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("canon-variant.csv")
        try """
        ,ISO (DX),400
        ,Frame No,Focal length,Tv,Av,ISO (M),Exposure compensation,Flash mode,Metering mode,Shooting mode,Date,Time
        ,1,40mm,="1/60",2.8,,+1/3,OFF,Evaluative,Aperture-priority AE,8/10/2025,12:33:42
        """.write(to: csv, atomically: true, encoding: .utf8)

        let model = makeModel()
        let target = URL(fileURLWithPath: "/tmp/001.jpg")
        let coordinator = ImportCoordinator()
        var options = ImportRunOptions.defaults(for: .eos1v)
        options.sourceURLPath = csv.path

        let prepared = try await coordinator.prepareRun(
            options: options,
            targetFiles: [target],
            tagCatalog: model.importTagCatalog,
            metadataProvider: { _ in [:] }
        )

        XCTAssertEqual(prepared.parseResult.rows.count, 1)
        XCTAssertTrue(prepared.parseResult.rows[0].fields.contains(where: { $0.tagID == "datetime-created" && $0.value == "2025:10:08 12:33:42" }))
        XCTAssertTrue(prepared.parseResult.rows[0].fields.contains(where: { $0.tagID == "exif-iso" && $0.value == "400" }))
    }

    func testEOSFallbackErrorMessageIsNotGenericFilenameColumn() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("invalid.csv")
        try """
        only,unsupported,columns
        a,b,c
        """.write(to: csv, atomically: true, encoding: .utf8)

        let model = makeModel()
        let coordinator = ImportCoordinator()
        var options = ImportRunOptions.defaults(for: .eos1v)
        options.sourceURLPath = csv.path
        options.matchStrategy = .filename

        do {
            _ = try await coordinator.prepareRun(
                options: options,
                targetFiles: [URL(fileURLWithPath: "/tmp/001.jpg")],
                tagCatalog: model.importTagCatalog,
                metadataProvider: { _ in [:] }
            )
            XCTFail("Expected invalid schema error")
        } catch {
            let message = error.localizedDescription.lowercased()
            XCTAssertTrue(message.contains("eos"))
            XCTAssertFalse(message.contains("generic csv"))
        }
    }

    func testEOSAdapterParsesRowsWithoutFrameNumberWhenCaptureFieldsPresent() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("eos-no-frame.csv")
        try """
        ,Date,Time,Tv,Av,ISO (M),Focal length,Metering mode,Shooting mode
        ,8/10/2025,12:33:42,="1/60",2.8,200,40mm,Evaluative,Aperture-priority AE
        ,8/10/2025,12:35:42,="1/125",4.0,200,50mm,Evaluative,Shutter-speed-priority AE
        """.write(to: csv, atomically: true, encoding: .utf8)

        let model = makeModel()
        let coordinator = ImportCoordinator()
        var options = ImportRunOptions.defaults(for: .eos1v)
        options.sourceURLPath = csv.path

        let prepared = try await coordinator.prepareRun(
            options: options,
            targetFiles: [
                URL(fileURLWithPath: "/tmp/001.jpg"),
                URL(fileURLWithPath: "/tmp/002.jpg"),
            ],
            tagCatalog: model.importTagCatalog,
            metadataProvider: { _ in [:] }
        )

        XCTAssertEqual(prepared.parseResult.rows.count, 2)
        XCTAssertEqual(prepared.parseResult.rows[0].sourceIdentifier.lowercased(), "001.jpg")
        XCTAssertEqual(prepared.parseResult.rows[1].sourceIdentifier.lowercased(), "002.jpg")
    }

    func testEOSAdapterParsesSemicolonDelimitedInput() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("eos-semicolon.csv")
        try """
        ;Frame No.;Focal length;Tv;Av;ISO (M);Exposure compensation;Flash mode;Metering mode;Shooting mode;Date;Time
        ;1;40mm;=\"1/60\";2.8;200;0.0;OFF;Evaluative;Aperture-priority AE;8/10/2025;12:33:42
        ;2;50mm;=\"1/125\";4.0;200;0.0;OFF;Evaluative;Shutter-speed-priority AE;8/10/2025;12:35:42
        """.write(to: csv, atomically: true, encoding: .utf8)

        let model = makeModel()
        let coordinator = ImportCoordinator()
        var options = ImportRunOptions.defaults(for: .eos1v)
        options.sourceURLPath = csv.path

        let prepared = try await coordinator.prepareRun(
            options: options,
            targetFiles: [
                URL(fileURLWithPath: "/tmp/001.jpg"),
                URL(fileURLWithPath: "/tmp/002.jpg"),
            ],
            tagCatalog: model.importTagCatalog,
            metadataProvider: { _ in [:] }
        )

        XCTAssertEqual(prepared.parseResult.rows.count, 2)
    }

    func testEOSAdapterParsesCarriageReturnOnlyLineEndings() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("eos-cr-only.csv")
        let content = ",Frame No.,Focal length,Tv,Av,ISO (M),Date,Time\r,1,40mm,=\"1/60\",2.8,200,8/10/2025,12:33:42\r,2,50mm,=\"1/125\",4.0,200,8/10/2025,12:35:42\r"
        try content.data(using: .utf8)?.write(to: csv)

        let model = makeModel()
        let coordinator = ImportCoordinator()
        var options = ImportRunOptions.defaults(for: .eos1v)
        options.sourceURLPath = csv.path

        let prepared = try await coordinator.prepareRun(
            options: options,
            targetFiles: [
                URL(fileURLWithPath: "/tmp/001.jpg"),
                URL(fileURLWithPath: "/tmp/002.jpg"),
            ],
            tagCatalog: model.importTagCatalog,
            metadataProvider: { _ in [:] }
        )

        XCTAssertEqual(prepared.parseResult.rows.count, 2)
    }

    func testEOSAdapterStripsExcelEqualsFromShutterSpeed() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("eos-tv-equals.csv")
        try """
        ,Frame No.,Tv,Av,ISO (M),Date,Time
        ,1,="1/200",2.8,200,8/10/2025,12:33:42
        """.write(to: csv, atomically: true, encoding: .utf8)

        let model = makeModel()
        let coordinator = ImportCoordinator()
        var options = ImportRunOptions.defaults(for: .eos1v)
        options.sourceURLPath = csv.path

        let prepared = try await coordinator.prepareRun(
            options: options,
            targetFiles: [URL(fileURLWithPath: "/tmp/001.jpg")],
            tagCatalog: model.importTagCatalog,
            metadataProvider: { _ in [:] }
        )

        let shutter = prepared.parseResult.rows.first?.fields.first(where: { $0.tagID == "exif-shutter" })?.value
        XCTAssertEqual(shutter, "1/200")
    }

    func testEOSAdapterParsesUnicodeLineSeparatorLineEndings() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("eos-unicode-newline.csv")
        let ls = "\u{2028}"
        let content = ",Frame No.,Focal length,Tv,Av,ISO (M),Date,Time\(ls),1,40mm,=\"1/60\",2.8,200,8/10/2025,12:33:42\(ls),2,50mm,=\"1/125\",4.0,200,8/10/2025,12:35:42\(ls)"
        try content.data(using: .utf8)?.write(to: csv)

        let model = makeModel()
        let coordinator = ImportCoordinator()
        var options = ImportRunOptions.defaults(for: .eos1v)
        options.sourceURLPath = csv.path

        let prepared = try await coordinator.prepareRun(
            options: options,
            targetFiles: [
                URL(fileURLWithPath: "/tmp/001.jpg"),
                URL(fileURLWithPath: "/tmp/002.jpg"),
            ],
            tagCatalog: model.importTagCatalog,
            metadataProvider: { _ in [:] }
        )

        XCTAssertEqual(prepared.parseResult.rows.count, 2)
    }

    func testEOSAdapterRowParityRespectsStartAndCount() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("eos-window.csv")
        try """
        ,Frame No.,Tv,Av,ISO (M),Date,Time
        ,1,="1/60",2.8,200,8/10/2025,12:33:42
        ,2,="1/125",4.0,200,8/10/2025,12:35:42
        ,3,="1/250",5.6,200,8/10/2025,12:37:42
        """.write(to: csv, atomically: true, encoding: .utf8)

        let model = makeModel()
        let coordinator = ImportCoordinator()
        var options = ImportRunOptions.defaults(for: .eos1v)
        options.sourceURLPath = csv.path
        options.matchStrategy = .rowParity
        options.rowParityStartRow = 2
        options.rowParityRowCount = 1

        let prepared = try await coordinator.prepareRun(
            options: options,
            targetFiles: [
                URL(fileURLWithPath: "/tmp/001.jpg"),
                URL(fileURLWithPath: "/tmp/002.jpg"),
            ],
            tagCatalog: model.importTagCatalog,
            metadataProvider: { _ in [:] }
        )

        XCTAssertEqual(prepared.parseResult.rows.count, 1)
        XCTAssertEqual(prepared.parseResult.rows[0].sourceIdentifier.lowercased(), "002.jpg")
        XCTAssertEqual(prepared.parseResult.rows[0].targetSelector, .rowNumber(1))
    }

    func testGPXImportAdapterParsesTimestampsWithoutFractionalSeconds() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let gpx = temp.appendingPathComponent("track.gpx")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test">
          <trk>
            <trkseg>
              <trkpt lat="51.5007000" lon="-0.1246000">
                <ele>35.0</ele>
                <time>2026-01-01T12:00:00Z</time>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>
        """.write(to: gpx, atomically: true, encoding: .utf8)

        let file = URL(fileURLWithPath: "/tmp/001.jpg")
        var options = ImportRunOptions.defaults(for: .gpx)
        options.sourceURLPath = gpx.path
        options.gpxToleranceSeconds = 60
        let context = ImportParseContext(
            options: options,
            sourceURL: gpx,
            auxiliaryURLs: [],
            targetFiles: [file],
            tagCatalog: [],
            metadataByFile: [
                file: FileMetadataSnapshot(
                    fileURL: file,
                    fields: [
                        MetadataField(key: "CreateDate", namespace: .exif, value: "2026:01:01 12:00:00"),
                    ]
                ),
            ]
        )

        let result = try GPXImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testGPXImportAdapterParsesNamespacedTrackPointAndTime() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let gpx = temp.appendingPathComponent("track-namespaced.gpx")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test">
          <trk>
            <trkseg>
              <x:trkpt lat="51.5007000" lon="-0.1246000">
                <x:ele>35.0</x:ele>
                <x:time>2026-01-01T12:00:00.000Z</x:time>
              </x:trkpt>
            </trkseg>
          </trk>
        </gpx>
        """.write(to: gpx, atomically: true, encoding: .utf8)

        let file = URL(fileURLWithPath: "/tmp/001.jpg")
        var options = ImportRunOptions.defaults(for: .gpx)
        options.sourceURLPath = gpx.path
        options.gpxToleranceSeconds = 60
        let context = ImportParseContext(
            options: options,
            sourceURL: gpx,
            auxiliaryURLs: [],
            targetFiles: [file],
            tagCatalog: [],
            metadataByFile: [
                file: FileMetadataSnapshot(
                    fileURL: file,
                    fields: [
                        MetadataField(key: "CreateDate", namespace: .exif, value: "2026:01:01 12:00:00"),
                    ]
                ),
            ]
        )

        let result = try GPXImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testReferenceFolderImportAdapterDoesNotReportEmptyFolderWhenMetadataReadFails() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceFolder = temp.appendingPathComponent("ref", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let image = sourceFolder.appendingPathComponent("0001.jpg")
        try Data().write(to: image)

        var options = ImportRunOptions.defaults(for: .referenceFolder)
        options.sourceURLPath = sourceFolder.path
        let context = ImportParseContext(
            options: options,
            sourceURL: sourceFolder,
            auxiliaryURLs: [],
            targetFiles: [],
            tagCatalog: [],
            metadataByFile: [:]
        )

        let result = try ReferenceFolderImportAdapter().parse(context: context)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertTrue(result.warnings.contains(where: { $0.message.contains("Couldn’t read metadata for reference file 0001.jpg.") }))
        XCTAssertFalse(result.warnings.contains(where: { $0.message.contains("no supported image files") }))
    }

    func testReferenceImportSupportSignsGPSLongitudeFromRef() {
        let snapshot = FileMetadataSnapshot(
            fileURL: URL(fileURLWithPath: "/tmp/001.jpg"),
            fields: [
                MetadataField(key: "GPSLongitude", namespace: .exif, value: "0.218891666666667"),
                MetadataField(key: "GPSLongitudeRef", namespace: .exif, value: "W"),
            ]
        )
        let descriptors: [ImportTagDescriptor] = [
            .init(id: "exif-gps-lon", key: "GPSLongitude", namespace: .exif, label: "Longitude", section: "Location"),
        ]

        let fields = ReferenceImportSupport.fieldsFromSnapshot(snapshot: snapshot, descriptors: descriptors)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].tagID, "exif-gps-lon")
        XCTAssertEqual(fields[0].value, "-0.218891666667")
    }

    func testReferenceImageImportUsesReferenceFilenameAsSourceIdentifier() throws {
        let source = URL(fileURLWithPath: "/tmp/reference.jpg")
        let targetA = URL(fileURLWithPath: "/tmp/001.jpg")
        let targetB = URL(fileURLWithPath: "/tmp/002.jpg")
        let descriptors: [ImportTagDescriptor] = [
            .init(id: "xmp-title", key: "Title", namespace: .xmp, label: "Title", section: "Descriptive"),
        ]
        var options = ImportRunOptions.defaults(for: .referenceImage)
        options.sourceURLPath = source.path
        options.selectedTagIDs = ["xmp-title"]

        let context = ImportParseContext(
            options: options,
            sourceURL: source,
            auxiliaryURLs: [],
            targetFiles: [targetA, targetB],
            tagCatalog: descriptors,
            metadataByFile: [
                source: FileMetadataSnapshot(
                    fileURL: source,
                    fields: [MetadataField(key: "Title", namespace: .xmp, value: "Reference Title")]
                ),
            ]
        )

        let result = try ReferenceImageImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0].sourceIdentifier, "reference.jpg")
        XCTAssertEqual(result.rows[1].sourceIdentifier, "reference.jpg")
        XCTAssertEqual(result.rows[0].targetSelector, .direct(targetA))
        XCTAssertEqual(result.rows[1].targetSelector, .direct(targetB))
    }


    func testStageImportAssignmentsRespectsEmptyPolicy() throws {
        let model = makeModel()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")

        let clearSummary = model.stageImportAssignments(
            [ImportAssignment(targetURL: file, fields: [.init(tagID: "xmp-title", value: "")])],
            sourceKind: .csv,
            emptyValuePolicy: .clear,
            pendingPolicy: .merge
        )
        XCTAssertEqual(clearSummary.skippedFields, 0)

        model.clearPendingEdits(for: [file])

        let skipSummary = model.stageImportAssignments(
            [ImportAssignment(targetURL: file, fields: [.init(tagID: "xmp-title", value: "")])],
            sourceKind: .csv,
            emptyValuePolicy: .skip,
            pendingPolicy: .merge
        )
        XCTAssertEqual(skipSummary.skippedFields, 1)
    }

    func testImportMetadataSnapshotsOverlaysStagedDateValues() async throws {
        let model = makeModel()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        model.metadataByFile = [
            file: FileMetadataSnapshot(
                fileURL: file,
                fields: [
                    MetadataField(key: "Make", namespace: .exif, value: "Canon"),
                ]
            ),
        ]

        _ = model.stageImportAssignments(
            [ImportAssignment(targetURL: file, fields: [.init(tagID: "datetime-created", value: "2026:01:04 14:24:03")])],
            sourceKind: .eos1v,
            emptyValuePolicy: .clear,
            pendingPolicy: .merge
        )

        let snapshots = await model.importMetadataSnapshots(for: [file])
        let date = snapshots[file]?.fields.first(where: { $0.namespace == .exif && $0.key == "DateTimeOriginal" })?.value
        XCTAssertEqual(date, "2026:01:04 14:24:03")
    }

    private func makeModel() -> AppModel {
        AppModel(
            exifToolService: StubExifToolService(),
            presetStore: InMemoryPresetStore(),
            favoritesStore: InMemoryFavoritesStore(),
            recentLocationsStore: InMemoryRecentLocationsStore()
        )
    }

    private func makeTempDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct StubExifToolService: ExifToolServiceProtocol {
    func readMetadata(files _: [URL]) async throws -> [FileMetadataSnapshot] { [] }
    func writeMetadata(operation: EditOperation) async -> OperationResult {
        OperationResult(operationID: operation.id, succeeded: operation.targetFiles, failed: [], backupLocation: nil, duration: 0)
    }
}

private struct InMemoryPresetStore: PresetStoreProtocol {
    func loadPresets() throws -> [MetadataPreset] { [] }
    func savePresets(_: [MetadataPreset]) throws {}
}

private final class InMemoryFavoritesStore: SidebarFavoritesStoreProtocol {
    func loadFavorites() throws -> [SidebarFavorite] { [] }
    func saveFavorites(_: [SidebarFavorite]) throws {}
}

private final class InMemoryRecentLocationsStore: RecentLocationsStoreProtocol {
    func loadRecentLocations() throws -> [RecentLocation] { [] }
    func saveRecentLocations(_: [RecentLocation]) throws {}
}
