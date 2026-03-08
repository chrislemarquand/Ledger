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

    func testImportSessionGPXResetsAdvancedOptionsOnOpen() {
        let defaults = UserDefaults.standard
        let key = "\(AppBrand.identifierPrefix).import.options.\(ImportSourceKind.gpx.rawValue)"
        let previousData = defaults.data(forKey: key)
        defer {
            if let previousData {
                defaults.set(previousData, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        var persisted = ImportRunOptions.defaults(for: .gpx)
        persisted.gpxToleranceSeconds = 321
        persisted.gpxCameraOffsetSeconds = 45
        ImportCoordinator().persist(options: persisted)

        let model = makeModel()
        let session = ImportSession(model: model, sourceKind: .gpx)
        let gpxDefaults = ImportRunOptions.defaults(for: .gpx)

        XCTAssertEqual(session.options.gpxToleranceSeconds, gpxDefaults.gpxToleranceSeconds)
        XCTAssertEqual(session.options.gpxCameraOffsetSeconds, gpxDefaults.gpxCameraOffsetSeconds)
    }

    func testCSVImportAdapterParsesFilenameAliasAndMappedFields() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("input.csv")
        try """
        SourceFile,[XMP] Title,[EXIF] ISO
        a.jpg,Alpha,400
        """.write(to: csv, atomically: true, encoding: .utf8)

        let options = ImportRunOptions.defaults(for: .csv)
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
        XCTAssertEqual(result.rows.first?.targetSelector, .filename("a.jpg"))
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

        let options = ImportRunOptions.defaults(for: .csv)
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

        let options = ImportRunOptions.defaults(for: .csv)
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

        let options = ImportRunOptions.defaults(for: .csv)
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

    func testCSVImportAdapterFallsBackToRowParityWhenSourceFileValuesAreIncomplete() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("fallback-row-order.csv")
        try """
        SourceFile,[XMP] Title
        /tmp/001.jpg,A
        ,B
        """.write(to: csv, atomically: true, encoding: .utf8)

        let options = ImportRunOptions.defaults(for: .csv)
        let context = ImportParseContext(
            options: options,
            sourceURL: csv,
            auxiliaryURLs: [],
            targetFiles: [
                URL(fileURLWithPath: "/tmp/001.jpg"),
                URL(fileURLWithPath: "/tmp/002.jpg"),
            ],
            tagCatalog: [
                .init(id: "xmp-title", key: "Title", namespace: .xmp, label: "Title", section: "Descriptive"),
            ],
            metadataByFile: [:]
        )

        let result = try CSVImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0].sourceIdentifier, "Row 001")
        XCTAssertEqual(result.rows[1].sourceIdentifier, "Row 002")
        XCTAssertEqual(result.rows[0].targetSelector, .rowNumber(1))
        XCTAssertEqual(result.rows[1].targetSelector, .rowNumber(2))
        XCTAssertTrue(
            result.warnings.contains(where: { $0.message.localizedCaseInsensitiveContains("using row-order matching") })
        )
    }

    func testCSVImportAdapterInvalidEnumValueSkipsFieldWithWarning() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("enum-invalid.csv")
        try """
        SourceFile,Flash
        a.jpg,maybe
        """.write(to: csv, atomically: true, encoding: .utf8)

        let options = ImportRunOptions.defaults(for: .csv)

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

    func testCSVImportAdapterParsesExifToolRoundTripFormats() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("exiftool-roundtrip.csv")
        try """
        SourceFile,Copy1:CreateDate,DateTimeDigitized,ExposureProgram,FocalLength,GPSAltitude,Flash
        a.jpg,2025:10:09 15:29:48+01:00,2025:10:09 15:29:48+01:00,Shutter speed priority AE,50.0 mm,9.1 m Above Sea Level,"Off, Did not fire"
        """.write(to: csv, atomically: true, encoding: .utf8)

        var options = ImportRunOptions.defaults(for: .csv)
        options.cameraTimezoneIdentifier = "Europe/London"
        let context = ImportParseContext(
            options: options,
            sourceURL: csv,
            auxiliaryURLs: [],
            targetFiles: [],
            tagCatalog: [
                .init(id: "datetime-digitized", key: "CreateDate", namespace: .exif, label: "Date Time Digitized", section: "Date and Time", inputKind: .dateTime),
                .init(
                    id: "exif-exposure-program",
                    key: "ExposureProgram",
                    namespace: .exif,
                    label: "Exposure Program",
                    section: "Capture",
                    inputKind: .enumChoice([
                        .init(value: "0", label: "Unknown"),
                        .init(value: "1", label: "Manual"),
                        .init(value: "2", label: "Program AE"),
                        .init(value: "3", label: "Aperture Priority"),
                        .init(value: "4", label: "Shutter Priority"),
                    ])
                ),
                .init(id: "exif-focal", key: "FocalLength", namespace: .exif, label: "Focal Length", section: "Capture", inputKind: .decimal),
                .init(id: "exif-gps-alt", key: "GPSAltitude", namespace: .exif, label: "Altitude", section: "Location", inputKind: .decimal),
                .init(
                    id: "exif-flash",
                    key: "Flash",
                    namespace: .exif,
                    label: "Flash",
                    section: "Capture",
                    inputKind: .enumChoice([
                        .init(value: "0", label: "No Flash"),
                        .init(value: "1", label: "Fired"),
                        .init(value: "16", label: "Off"),
                    ])
                ),
            ],
            metadataByFile: [:]
        )

        let result = try CSVImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertTrue(result.warnings.isEmpty, "ExifTool CSV round-trip formats should parse without invalid-value warnings.")

        let fieldsByTag = Dictionary(uniqueKeysWithValues: result.rows[0].fields.map { ($0.tagID, $0.value) })
        XCTAssertEqual(fieldsByTag["datetime-digitized"], "2025:10:09 15:29:48")
        XCTAssertEqual(fieldsByTag["exif-exposure-program"], "4")
        XCTAssertEqual(fieldsByTag["exif-focal"], "50")
        XCTAssertEqual(fieldsByTag["exif-gps-alt"], "9.1")
        XCTAssertEqual(fieldsByTag["exif-flash"], "16")

        let digitizedCount = result.rows[0].fields.filter { $0.tagID == "datetime-digitized" }.count
        XCTAssertEqual(digitizedCount, 1, "Duplicate columns mapping to the same tag should collapse to one field.")
    }

    func testCSVImportAdapterParsesLatLonCompassDirectionsWithoutSignRegression() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("gps-directions.csv")
        let csvContent = [
            "SourceFile,GPSLatitude,GPSLongitude",
            #"a.jpg,"51 deg 28' 0.86"" N","0 deg 13' 45.41"" W""#,
            #"b.jpg,"33 deg 52' 0.00"" S","151 deg 12' 0.00"" E""#,
            "c.jpg,-33.865143,-151.209900",
            #"d.jpg,51,"-0 deg 13' 45.41"""#,
        ].joined(separator: "\n")
        try csvContent.write(to: csv, atomically: true, encoding: .utf8)

        let options = ImportRunOptions.defaults(for: .csv)
        let context = ImportParseContext(
            options: options,
            sourceURL: csv,
            auxiliaryURLs: [],
            targetFiles: [],
            tagCatalog: [
                .init(id: "exif-gps-lat", key: "GPSLatitude", namespace: .exif, label: "Latitude", section: "Location", inputKind: .gpsCoordinate),
                .init(id: "exif-gps-lon", key: "GPSLongitude", namespace: .exif, label: "Longitude", section: "Location", inputKind: .gpsCoordinate),
            ],
            metadataByFile: [:]
        )

        let result = try CSVImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 4)
        XCTAssertTrue(result.warnings.isEmpty)

        let row1 = Dictionary(uniqueKeysWithValues: result.rows[0].fields.map { ($0.tagID, $0.value) })
        XCTAssertEqual(row1["exif-gps-lat"], "51.466905555556")
        XCTAssertEqual(row1["exif-gps-lon"], "-0.229280555556")

        let row2 = Dictionary(uniqueKeysWithValues: result.rows[1].fields.map { ($0.tagID, $0.value) })
        XCTAssertEqual(row2["exif-gps-lat"], "-33.866666666667")
        XCTAssertEqual(row2["exif-gps-lon"], "151.2")

        let row3 = Dictionary(uniqueKeysWithValues: result.rows[2].fields.map { ($0.tagID, $0.value) })
        XCTAssertEqual(row3["exif-gps-lat"], "-33.865143")
        XCTAssertEqual(row3["exif-gps-lon"], "-151.2099")

        let row4 = Dictionary(uniqueKeysWithValues: result.rows[3].fields.map { ($0.tagID, $0.value) })
        XCTAssertEqual(row4["exif-gps-lat"], "51")
        XCTAssertEqual(row4["exif-gps-lon"], "-0.229280555556")
    }

    func testCSVImportAdapterParsesExifToolLocationFieldsWithCopyVariants() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("exiftool-location-roundtrip.csv")
        let csvContent = [
            "SourceFile,Copy1:GPSAltitude,Copy1:GPSLatitude,Copy1:GPSLongitude,GPSAltitude,GPSLatitude,GPSLongitude,GPSImgDirection",
            #"a.jpg,9.1 m,"51 deg 28' 0.86""","0 deg 13' 45.41""",9.1 m Above Sea Level,"51 deg 28' 0.86"" N","0 deg 13' 45.41"" W",171.0121766"#,
        ].joined(separator: "\n")
        try csvContent.write(to: csv, atomically: true, encoding: .utf8)

        let options = ImportRunOptions.defaults(for: .csv)
        let context = ImportParseContext(
            options: options,
            sourceURL: csv,
            auxiliaryURLs: [],
            targetFiles: [],
            tagCatalog: [
                .init(id: "exif-gps-lat", key: "GPSLatitude", namespace: .exif, label: "Latitude", section: "Location", inputKind: .gpsCoordinate),
                .init(id: "exif-gps-lon", key: "GPSLongitude", namespace: .exif, label: "Longitude", section: "Location", inputKind: .gpsCoordinate),
                .init(id: "exif-gps-alt", key: "GPSAltitude", namespace: .exif, label: "Altitude", section: "Location", inputKind: .decimal),
                .init(id: "exif-gps-direction", key: "GPSImgDirection", namespace: .exif, label: "Direction", section: "Location", inputKind: .decimal),
            ],
            metadataByFile: [:]
        )

        let result = try CSVImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertTrue(result.warnings.isEmpty, "ExifTool location columns should parse without invalid-value warnings.")

        let row = Dictionary(uniqueKeysWithValues: result.rows[0].fields.map { ($0.tagID, $0.value) })
        XCTAssertEqual(row["exif-gps-lat"], "51.466905555556")
        XCTAssertEqual(row["exif-gps-lon"], "-0.229280555556")
        XCTAssertEqual(row["exif-gps-alt"], "9.1")
        XCTAssertEqual(row["exif-gps-direction"], "171.0121766")
    }

    func testCSVImportAdapterRowParityRespectsStartAndCount() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("input.csv")
        try """
        [XMP] Title
        A
        B
        C
        D
        """.write(to: csv, atomically: true, encoding: .utf8)

        var options = ImportRunOptions.defaults(for: .csv)
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
        XCTAssertEqual(result.rows[0].sourceIdentifier, "Row 002")
        XCTAssertEqual(result.rows[0].targetSelector, .rowNumber(1))
        XCTAssertEqual(result.rows[1].sourceIdentifier, "Row 003")
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

    func testMatcherReferenceFolderFallbackAppliesUnmatchedRowsInTargetOrder() {
        let rows: [ImportRow] = [
            .init(
                sourceLine: 2,
                sourceIdentifier: "match.jpg",
                targetSelector: .filename("match.jpg"),
                fields: [.init(tagID: "xmp-title", value: "Match")]
            ),
            .init(
                sourceLine: 3,
                sourceIdentifier: "missing-a.jpg",
                targetSelector: .filename("missing-a.jpg"),
                fields: [.init(tagID: "xmp-title", value: "Fallback A")]
            ),
            .init(
                sourceLine: 4,
                sourceIdentifier: "missing-b.jpg",
                targetSelector: .filename("missing-b.jpg"),
                fields: [.init(tagID: "xmp-title", value: "Fallback B")]
            ),
        ]
        let parse = ImportParseResult(rows: rows, warnings: [])
        let targetFallbackA = URL(fileURLWithPath: "/tmp/0001.jpg")
        let targetMatch = URL(fileURLWithPath: "/tmp/match.jpg")
        let targetFallbackB = URL(fileURLWithPath: "/tmp/0002.jpg")
        var options = ImportRunOptions.defaults(for: .referenceFolder)
        options.referenceFolderRowFallbackEnabled = true

        let match = ImportMatcher().match(
            parseResult: parse,
            targetFiles: [targetFallbackA, targetMatch, targetFallbackB],
            options: options
        )

        XCTAssertEqual(match.matched.count, 3)
        XCTAssertTrue(match.conflicts.isEmpty)
        XCTAssertEqual(match.matched[0].row.sourceIdentifier, "match.jpg")
        XCTAssertEqual(match.matched[0].targetURL.lastPathComponent, "match.jpg")
        XCTAssertEqual(match.matched[1].row.sourceIdentifier, "missing-a.jpg")
        XCTAssertEqual(match.matched[1].targetURL.lastPathComponent, "0001.jpg")
        XCTAssertEqual(match.matched[2].row.sourceIdentifier, "missing-b.jpg")
        XCTAssertEqual(match.matched[2].targetURL.lastPathComponent, "0002.jpg")
        XCTAssertTrue(match.warnings.contains(where: { $0.message.localizedCaseInsensitiveContains("row-order fallback") }))
    }

    func testMatcherReferenceFolderWithoutFallbackKeepsMissingTargetConflicts() {
        let rows: [ImportRow] = [
            .init(
                sourceLine: 2,
                sourceIdentifier: "match.jpg",
                targetSelector: .filename("match.jpg"),
                fields: [.init(tagID: "xmp-title", value: "Match")]
            ),
            .init(
                sourceLine: 3,
                sourceIdentifier: "missing-a.jpg",
                targetSelector: .filename("missing-a.jpg"),
                fields: [.init(tagID: "xmp-title", value: "Fallback A")]
            ),
        ]
        let parse = ImportParseResult(rows: rows, warnings: [])
        let target = URL(fileURLWithPath: "/tmp/match.jpg")
        var options = ImportRunOptions.defaults(for: .referenceFolder)
        options.referenceFolderRowFallbackEnabled = false

        let match = ImportMatcher().match(parseResult: parse, targetFiles: [target], options: options)
        XCTAssertEqual(match.matched.count, 1)
        XCTAssertEqual(match.conflicts.count, 1)
        XCTAssertEqual(match.conflicts[0].kind, .missingTarget)
    }

    func testImportSessionPreviewDisplaysRowOrderFallbackWarning() {
        let model = makeModel()
        let session = ImportSession(model: model, sourceKind: .csv)
        let target = URL(fileURLWithPath: "/tmp/001.jpg")
        let row = ImportRow(
            sourceLine: 2,
            sourceIdentifier: "Row 001",
            targetSelector: .rowNumber(1),
            fields: [.init(tagID: "xmp-title", value: "Title")]
        )
        let warning = ImportWarning(
            sourceLine: nil,
            message: "Using row-order matching: duplicate SourceFile identifiers were found in the CSV.",
            severity: .info
        )
        let preparedRun = ImportPreparedRun(
            options: ImportRunOptions.defaults(for: .csv),
            parsedAsSourceKind: .csv,
            parseResult: ImportParseResult(rows: [row], warnings: [warning]),
            matchResult: ImportMatchResult(
                matched: [ImportRowMatch(row: row, targetURL: target)],
                conflicts: [],
                warnings: [warning]
            ),
            previewSummary: ImportPreviewSummary(
                sourceKind: .csv,
                parsedRows: 1,
                matchedRows: 1,
                conflictedRows: 0,
                warnings: 1,
                fieldWrites: 1
            )
        )
        session.preparedRun = preparedRun

        let text = session.previewText
        XCTAssertTrue(text.contains("Warnings (1)"))
        XCTAssertTrue(text.contains("Matching mode: Row order."))
        XCTAssertTrue(text.contains("duplicate SourceFile identifiers"))
    }

    func testCSVFallbackFlowShowsPreviewWarningAndStagesRowOrder() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("fallback-flow.csv")
        try """
        SourceFile,[XMP] Title
        /tmp/001.jpg,A
        ,B
        /tmp/001.jpg,C
        """.write(to: csv, atomically: true, encoding: .utf8)

        let files = [
            URL(fileURLWithPath: "/tmp/001.jpg"),
            URL(fileURLWithPath: "/tmp/002.jpg"),
            URL(fileURLWithPath: "/tmp/003.jpg"),
        ]

        let model = makeModel()
        model.browserItems = files.map {
            AppModel.BrowserItem(
                url: $0,
                name: $0.lastPathComponent,
                modifiedAt: nil,
                createdAt: nil,
                sizeBytes: nil,
                kind: "jpg"
            )
        }
        model.metadataByFile = Dictionary(uniqueKeysWithValues: files.map { file in
            (
                file,
                FileMetadataSnapshot(
                    fileURL: file,
                    fields: [MetadataField(key: "Title", namespace: .xmp, value: "Old-\(file.lastPathComponent)")]
                )
            )
        })

        var options = ImportRunOptions.defaults(for: .csv)
        options.sourceURLPath = csv.path
        options.scope = .folder
        options.selectedTagIDs = ["xmp-title"]
        let coordinator = ImportCoordinator()
        let prepared = try await coordinator.prepareRun(
            options: options,
            targetFiles: files,
            tagCatalog: model.importTagCatalog,
            metadataProvider: { requested in
                await model.importMetadataSnapshots(for: requested)
            }
        )

        XCTAssertEqual(prepared.parseResult.rows.count, 3)
        XCTAssertEqual(prepared.parseResult.rows[0].sourceIdentifier, "Row 001")
        XCTAssertEqual(prepared.parseResult.rows[1].sourceIdentifier, "Row 002")
        XCTAssertEqual(prepared.parseResult.rows[2].sourceIdentifier, "Row 003")
        XCTAssertTrue(prepared.matchResult.warnings.contains(where: { $0.message.localizedCaseInsensitiveContains("using row-order matching") }))

        let session = ImportSession(model: model, sourceKind: .csv)
        session.preparedRun = prepared
        let previewText = session.previewText
        XCTAssertTrue(previewText.contains("Row 001"))
        XCTAssertTrue(previewText.contains("Row 002"))
        XCTAssertTrue(previewText.contains("Row 003"))
        XCTAssertTrue(previewText.contains("Warnings (1)"))
        XCTAssertTrue(previewText.contains("Matching mode: Row order."))

        let success = await session.performImport(model: model)
        XCTAssertTrue(success)

        let snapshots = await model.importMetadataSnapshots(for: files)
        let titles = files.map { file in
            snapshots[file]?.fields.first(where: { $0.namespace == .xmp && $0.key == "Title" })?.value
        }
        XCTAssertEqual(titles, ["A", "B", "C"])
    }

    func testConflictResolverResolvedConflictOverwritesMatchedFieldWithWarning() {
        let target = URL(fileURLWithPath: "/tmp/target.jpg")
        let matchedRow = ImportRow(
            sourceLine: 2,
            sourceIdentifier: "matched.jpg",
            targetSelector: .filename("target.jpg"),
            fields: [.init(tagID: "xmp-title", value: "Matched Title")]
        )
        let conflict = ImportConflict(
            id: UUID(),
            kind: .multipleTargets,
            sourceLine: 3,
            sourceIdentifier: "conflict.jpg",
            rowFields: [.init(tagID: "xmp-title", value: "Resolved Title")],
            candidateTargets: [target],
            message: "Conflict"
        )
        let matchResult = ImportMatchResult(
            matched: [.init(row: matchedRow, targetURL: target)],
            conflicts: [conflict],
            warnings: []
        )

        let result = ImportConflictResolver().resolve(
            matchResult: matchResult,
            resolutions: [conflict.id: .target(target)]
        )

        XCTAssertEqual(result.unresolvedConflicts.count, 0)
        XCTAssertEqual(result.assignments.count, 1)
        XCTAssertEqual(result.assignments[0].targetURL, target)
        XCTAssertEqual(result.assignments[0].fields.count, 1)
        XCTAssertEqual(result.assignments[0].fields[0].tagID, "xmp-title")
        XCTAssertEqual(result.assignments[0].fields[0].value, "Resolved Title")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].localizedCaseInsensitiveContains("collision"))
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
        XCTAssertFalse(prepared.parseResult.rows[0].fields.contains(where: { $0.tagID == "exif-lens" }))
        XCTAssertFalse(prepared.parseResult.rows[1].fields.contains(where: { $0.tagID == "exif-lens" }))
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

    func testGPXImportAdapterParsesTrackPointWhenTimePrecedesEle() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let gpx = temp.appendingPathComponent("track-time-before-ele.gpx")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test">
          <trk>
            <trkseg>
              <trkpt lat="51.5007000" lon="-0.1246000">
                <time>2026-01-01T12:00:00Z</time>
                <ele>35.0</ele>
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
        XCTAssertEqual(result.rows[0].fields.first(where: { $0.tagID == "exif-gps-alt" })?.value, "35")
    }

    func testGPXImportAdapterPrefersEarlierPointWhenEquidistant() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let gpx = temp.appendingPathComponent("track-equal-distance.gpx")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test">
          <trk>
            <trkseg>
              <trkpt lat="40.0" lon="-70.0">
                <time>2026-01-01T11:59:30Z</time>
              </trkpt>
              <trkpt lat="41.0" lon="-71.0">
                <time>2026-01-01T12:00:30Z</time>
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
        XCTAssertEqual(result.rows[0].fields.first(where: { $0.tagID == "exif-gps-lat" })?.value, "40")
        XCTAssertEqual(result.rows[0].fields.first(where: { $0.tagID == "exif-gps-lon" })?.value, "-70")
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
            emptyValuePolicy: .clear
        )
        XCTAssertEqual(clearSummary.skippedFields, 0)

        model.clearPendingEdits(for: [file])

        let skipSummary = model.stageImportAssignments(
            [ImportAssignment(targetURL: file, fields: [.init(tagID: "xmp-title", value: "")])],
            sourceKind: .csv,
            emptyValuePolicy: .skip
        )
        XCTAssertEqual(skipSummary.skippedFields, 1)
    }

    func testImportSessionCSVClearPolicyClearsMissingFieldsOnMatchedFile() async throws {
        let model = makeModel()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        model.browserItems = [
            AppModel.BrowserItem(url: file, name: file.lastPathComponent, modifiedAt: nil, createdAt: nil, sizeBytes: nil, kind: "jpg"),
        ]
        model.metadataByFile = [
            file: FileMetadataSnapshot(
                fileURL: file,
                fields: [
                    MetadataField(key: "Title", namespace: .xmp, value: "Old Title"),
                    MetadataField(key: "Make", namespace: .exif, value: "Canon"),
                ]
            ),
        ]

        var options = ImportRunOptions.defaults(for: .csv)
        options.scope = .folder
        options.emptyValuePolicy = .clear

        let row = ImportRow(
            sourceLine: 2,
            sourceIdentifier: file.lastPathComponent,
            targetSelector: .filename(file.lastPathComponent),
            fields: [.init(tagID: "xmp-title", value: "New Title")]
        )
        let preparedRun = ImportPreparedRun(
            options: options,
            parsedAsSourceKind: .csv,
            parseResult: ImportParseResult(rows: [row], warnings: []),
            matchResult: ImportMatchResult(
                matched: [ImportRowMatch(row: row, targetURL: file)],
                conflicts: [],
                warnings: []
            ),
            previewSummary: ImportPreviewSummary(
                sourceKind: .csv,
                parsedRows: 1,
                matchedRows: 1,
                conflictedRows: 0,
                warnings: 0,
                fieldWrites: 1
            )
        )

        let session = ImportSession(model: model, sourceKind: .csv)
        session.preparedRun = preparedRun
        session.options.emptyValuePolicy = .clear
        let success = await session.performImport(model: model)
        XCTAssertTrue(success)

        let snapshots = await model.importMetadataSnapshots(for: [file])
        let title = snapshots[file]?.fields.first(where: { $0.namespace == .xmp && $0.key == "Title" })?.value
        let make = snapshots[file]?.fields.first(where: { $0.namespace == .exif && $0.key == "Make" })?.value
        XCTAssertEqual(title, "New Title")
        XCTAssertNil(make, "Clear policy should remove missing Make field from matched file.")
    }

    func testImportSessionCSVSkipPolicyRetainsMissingFieldsOnMatchedFile() async throws {
        let model = makeModel()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        model.browserItems = [
            AppModel.BrowserItem(url: file, name: file.lastPathComponent, modifiedAt: nil, createdAt: nil, sizeBytes: nil, kind: "jpg"),
        ]
        model.metadataByFile = [
            file: FileMetadataSnapshot(
                fileURL: file,
                fields: [
                    MetadataField(key: "Title", namespace: .xmp, value: "Old Title"),
                    MetadataField(key: "Make", namespace: .exif, value: "Canon"),
                ]
            ),
        ]

        var options = ImportRunOptions.defaults(for: .csv)
        options.scope = .folder
        options.emptyValuePolicy = .skip

        let row = ImportRow(
            sourceLine: 2,
            sourceIdentifier: file.lastPathComponent,
            targetSelector: .filename(file.lastPathComponent),
            fields: [.init(tagID: "xmp-title", value: "New Title")]
        )
        let preparedRun = ImportPreparedRun(
            options: options,
            parsedAsSourceKind: .csv,
            parseResult: ImportParseResult(rows: [row], warnings: []),
            matchResult: ImportMatchResult(
                matched: [ImportRowMatch(row: row, targetURL: file)],
                conflicts: [],
                warnings: []
            ),
            previewSummary: ImportPreviewSummary(
                sourceKind: .csv,
                parsedRows: 1,
                matchedRows: 1,
                conflictedRows: 0,
                warnings: 0,
                fieldWrites: 1
            )
        )

        let session = ImportSession(model: model, sourceKind: .csv)
        session.preparedRun = preparedRun
        session.options.emptyValuePolicy = .skip
        let success = await session.performImport(model: model)
        XCTAssertTrue(success)

        let snapshots = await model.importMetadataSnapshots(for: [file])
        let title = snapshots[file]?.fields.first(where: { $0.namespace == .xmp && $0.key == "Title" })?.value
        let make = snapshots[file]?.fields.first(where: { $0.namespace == .exif && $0.key == "Make" })?.value
        XCTAssertEqual(title, "New Title")
        XCTAssertEqual(make, "Canon", "Skip policy should retain missing Make field on matched file.")
    }

    func testImportSessionEOSAutoStagesLensForSingleCandidateFocalLength() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let mappingCSV = temp.appendingPathComponent("lensfocalength.csv")
        try """
        Focal length (mm),Lens 1,Lens 2,Lens 3
        36,EF24-105mm f4L IS USM,,
        """.write(to: mappingCSV, atomically: true, encoding: .utf8)

        let model = makeModel()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        model.browserItems = [
            AppModel.BrowserItem(url: file, name: file.lastPathComponent, modifiedAt: nil, createdAt: nil, sizeBytes: nil, kind: "jpg"),
        ]

        var options = ImportRunOptions.defaults(for: .eos1v)
        options.scope = .folder
        let row = ImportRow(
            sourceLine: 2,
            sourceIdentifier: "001.jpg",
            targetSelector: .rowNumber(1),
            fields: [
                .init(tagID: "exif-focal", value: "36 mm"),
                .init(tagID: "xmp-title", value: "Shot 1"),
            ]
        )
        let preparedRun = ImportPreparedRun(
            options: options,
            parsedAsSourceKind: .eos1v,
            parseResult: ImportParseResult(rows: [row], warnings: []),
            matchResult: ImportMatchResult(
                matched: [ImportRowMatch(row: row, targetURL: file)],
                conflicts: [],
                warnings: []
            ),
            previewSummary: ImportPreviewSummary(
                sourceKind: .eos1v,
                parsedRows: 1,
                matchedRows: 1,
                conflictedRows: 0,
                warnings: 0,
                fieldWrites: 2
            )
        )

        let session = ImportSession(model: model, sourceKind: .eos1v, eosLensMappingURL: mappingCSV)
        session.preparedRun = preparedRun
        let success = await session.performImport(model: model)
        XCTAssertTrue(success)

        // Seed a baseline snapshot so importMetadataSnapshots can overlay staged import values.
        model.metadataByFile = [file: FileMetadataSnapshot(fileURL: file, fields: [])]
        let snapshots = await model.importMetadataSnapshots(for: [file])
        let lens = snapshots[file]?.fields.first(where: { $0.namespace == .exif && $0.key == "LensModel" })?.value
        XCTAssertEqual(lens, "EF24-105mm f4L IS USM")
    }

    func testImportSessionEOSAutoStageDoesNotCrashWhenMatchedTargetsContainDuplicates() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let mappingCSV = temp.appendingPathComponent("lensfocalength.csv")
        try """
        Focal length (mm),Lens 1,Lens 2,Lens 3
        36,EF24-105mm f4L IS USM,,
        """.write(to: mappingCSV, atomically: true, encoding: .utf8)

        let model = makeModel()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        model.browserItems = [
            AppModel.BrowserItem(url: file, name: file.lastPathComponent, modifiedAt: nil, createdAt: nil, sizeBytes: nil, kind: "jpg"),
        ]
        model.metadataByFile = [file: FileMetadataSnapshot(fileURL: file, fields: [])]

        var options = ImportRunOptions.defaults(for: .eos1v)
        options.scope = .folder
        let row1 = ImportRow(
            sourceLine: 2,
            sourceIdentifier: "001.jpg",
            targetSelector: .rowNumber(1),
            fields: [.init(tagID: "exif-focal", value: "36 mm")]
        )
        let row2 = ImportRow(
            sourceLine: 3,
            sourceIdentifier: "002.jpg",
            targetSelector: .rowNumber(2),
            fields: [.init(tagID: "exif-focal", value: "36 mm")]
        )
        let preparedRun = ImportPreparedRun(
            options: options,
            parsedAsSourceKind: .eos1v,
            parseResult: ImportParseResult(rows: [row1, row2], warnings: []),
            matchResult: ImportMatchResult(
                matched: [
                    ImportRowMatch(row: row1, targetURL: file),
                    ImportRowMatch(row: row2, targetURL: file),
                ],
                conflicts: [],
                warnings: []
            ),
            previewSummary: ImportPreviewSummary(
                sourceKind: .eos1v,
                parsedRows: 2,
                matchedRows: 2,
                conflictedRows: 0,
                warnings: 0,
                fieldWrites: 2
            )
        )

        let session = ImportSession(model: model, sourceKind: .eos1v, eosLensMappingURL: mappingCSV)
        session.preparedRun = preparedRun
        let success = await session.performImport(model: model)
        XCTAssertTrue(success)

        let snapshots = await model.importMetadataSnapshots(for: [file])
        let lens = snapshots[file]?.fields.first(where: { $0.namespace == .exif && $0.key == "LensModel" })?.value
        XCTAssertEqual(lens, "EF24-105mm f4L IS USM")
    }

    func testImportSessionEOSPromptsForEachAmbiguousRowAndStagesChosenLens() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let mappingCSV = temp.appendingPathComponent("lensfocalength.csv")
        try """
        Focal length (mm),Lens 1,Lens 2,Lens 3
        40,EF24-105mm f4L IS USM,EF40mm f2.8 STM,
        """.write(to: mappingCSV, atomically: true, encoding: .utf8)

        let model = makeModel()
        let fileA = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-a.jpg")
        let fileB = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-b.jpg")
        model.browserItems = [
            AppModel.BrowserItem(url: fileA, name: fileA.lastPathComponent, modifiedAt: nil, createdAt: nil, sizeBytes: nil, kind: "jpg"),
            AppModel.BrowserItem(url: fileB, name: fileB.lastPathComponent, modifiedAt: nil, createdAt: nil, sizeBytes: nil, kind: "jpg"),
        ]
        model.metadataByFile = [
            fileA: FileMetadataSnapshot(
                fileURL: fileA,
                fields: [MetadataField(key: "Make", namespace: .exif, value: "Canon")]
            ),
            fileB: FileMetadataSnapshot(
                fileURL: fileB,
                fields: [MetadataField(key: "Make", namespace: .exif, value: "Canon")]
            ),
        ]

        var options = ImportRunOptions.defaults(for: .eos1v)
        options.scope = .folder
        let rowA = ImportRow(
            sourceLine: 2,
            sourceIdentifier: "001.jpg",
            targetSelector: .rowNumber(1),
            fields: [.init(tagID: "exif-focal", value: "40 mm")]
        )
        let rowB = ImportRow(
            sourceLine: 3,
            sourceIdentifier: "002.jpg",
            targetSelector: .rowNumber(2),
            fields: [.init(tagID: "exif-focal", value: "40 mm")]
        )
        let preparedRun = ImportPreparedRun(
            options: options,
            parsedAsSourceKind: .eos1v,
            parseResult: ImportParseResult(rows: [rowA, rowB], warnings: []),
            matchResult: ImportMatchResult(
                matched: [
                    ImportRowMatch(row: rowA, targetURL: fileA),
                    ImportRowMatch(row: rowB, targetURL: fileB),
                ],
                conflicts: [],
                warnings: []
            ),
            previewSummary: ImportPreviewSummary(
                sourceKind: .eos1v,
                parsedRows: 2,
                matchedRows: 2,
                conflictedRows: 0,
                warnings: 0,
                fieldWrites: 2
            )
        )

        var prompts: [ImportSession.EOSLensChoiceRequest] = []
        let session = ImportSession(
            model: model,
            sourceKind: .eos1v,
            eosLensMappingURL: mappingCSV,
            lensChoiceProvider: { request in
                prompts.append(request)
                if request.sourceLine == 2 {
                    return "EF24-105mm f4L IS USM"
                }
                return "EF40mm f2.8 STM"
            }
        )
        session.preparedRun = preparedRun
        let success = await session.performImport(model: model)
        XCTAssertTrue(success)
        XCTAssertEqual(prompts.count, 2)

        let snapshots = await model.importMetadataSnapshots(for: [fileA, fileB])
        let lensA = snapshots[fileA]?.fields.first(where: { $0.namespace == .exif && $0.key == "LensModel" })?.value
        let lensB = snapshots[fileB]?.fields.first(where: { $0.namespace == .exif && $0.key == "LensModel" })?.value
        XCTAssertEqual(lensA, "EF24-105mm f4L IS USM")
        XCTAssertEqual(lensB, "EF40mm f2.8 STM")
    }

    func testImportSessionEOSApplyToRemainingAtFocalPromptsOnce() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let mappingCSV = temp.appendingPathComponent("lensfocalength.csv")
        try """
        Focal length (mm),Lens 1,Lens 2,Lens 3
        40,EF24-105mm f4L IS USM,EF40mm f2.8 STM,
        """.write(to: mappingCSV, atomically: true, encoding: .utf8)

        let model = makeModel()
        let fileA = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-a.jpg")
        let fileB = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-b.jpg")
        let fileC = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-c.jpg")
        model.browserItems = [
            AppModel.BrowserItem(url: fileA, name: fileA.lastPathComponent, modifiedAt: nil, createdAt: nil, sizeBytes: nil, kind: "jpg"),
            AppModel.BrowserItem(url: fileB, name: fileB.lastPathComponent, modifiedAt: nil, createdAt: nil, sizeBytes: nil, kind: "jpg"),
            AppModel.BrowserItem(url: fileC, name: fileC.lastPathComponent, modifiedAt: nil, createdAt: nil, sizeBytes: nil, kind: "jpg"),
        ]
        model.metadataByFile = [
            fileA: FileMetadataSnapshot(fileURL: fileA, fields: []),
            fileB: FileMetadataSnapshot(fileURL: fileB, fields: []),
            fileC: FileMetadataSnapshot(fileURL: fileC, fields: []),
        ]

        var options = ImportRunOptions.defaults(for: .eos1v)
        options.scope = .folder
        let rowA = ImportRow(
            sourceLine: 2,
            sourceIdentifier: "001.jpg",
            targetSelector: .rowNumber(1),
            fields: [.init(tagID: "exif-focal", value: "40 mm")]
        )
        let rowB = ImportRow(
            sourceLine: 3,
            sourceIdentifier: "002.jpg",
            targetSelector: .rowNumber(2),
            fields: [.init(tagID: "exif-focal", value: "40 mm")]
        )
        let rowC = ImportRow(
            sourceLine: 4,
            sourceIdentifier: "003.jpg",
            targetSelector: .rowNumber(3),
            fields: [.init(tagID: "exif-focal", value: "40 mm")]
        )
        let preparedRun = ImportPreparedRun(
            options: options,
            parsedAsSourceKind: .eos1v,
            parseResult: ImportParseResult(rows: [rowA, rowB, rowC], warnings: []),
            matchResult: ImportMatchResult(
                matched: [
                    ImportRowMatch(row: rowA, targetURL: fileA),
                    ImportRowMatch(row: rowB, targetURL: fileB),
                    ImportRowMatch(row: rowC, targetURL: fileC),
                ],
                conflicts: [],
                warnings: []
            ),
            previewSummary: ImportPreviewSummary(
                sourceKind: .eos1v,
                parsedRows: 3,
                matchedRows: 3,
                conflictedRows: 0,
                warnings: 0,
                fieldWrites: 3
            )
        )

        var prompts: [ImportSession.EOSLensChoiceRequest] = []
        let session = ImportSession(
            model: model,
            sourceKind: .eos1v,
            eosLensMappingURL: mappingCSV,
            lensChoiceDecisionProvider: { request in
                prompts.append(request)
                return ImportSession.EOSLensChoiceDecision(
                    lens: "EF24-105mm f4L IS USM",
                    applyToRemainingAtFocal: true
                )
            }
        )
        session.preparedRun = preparedRun
        let success = await session.performImport(model: model)
        XCTAssertTrue(success)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?.remainingRowsAtFocal, 2)

        let snapshots = await model.importMetadataSnapshots(for: [fileA, fileB, fileC])
        let lenses = [fileA, fileB, fileC].map { file in
            snapshots[file]?.fields.first(where: { $0.namespace == .exif && $0.key == "LensModel" })?.value
        }
        XCTAssertEqual(lenses, ["EF24-105mm f4L IS USM", "EF24-105mm f4L IS USM", "EF24-105mm f4L IS USM"])
    }

    func testImportSessionEOSAmbiguousLensChoiceCancelAbortsImport() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let mappingCSV = temp.appendingPathComponent("lensfocalength.csv")
        try """
        Focal length (mm),Lens 1,Lens 2,Lens 3
        40,EF24-105mm f4L IS USM,EF40mm f2.8 STM,
        """.write(to: mappingCSV, atomically: true, encoding: .utf8)

        let model = makeModel()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        model.browserItems = [
            AppModel.BrowserItem(url: file, name: file.lastPathComponent, modifiedAt: nil, createdAt: nil, sizeBytes: nil, kind: "jpg"),
        ]
        model.metadataByFile = [
            file: FileMetadataSnapshot(
                fileURL: file,
                fields: [MetadataField(key: "Make", namespace: .exif, value: "Canon")]
            ),
        ]

        var options = ImportRunOptions.defaults(for: .eos1v)
        options.scope = .folder
        let row = ImportRow(
            sourceLine: 2,
            sourceIdentifier: "001.jpg",
            targetSelector: .rowNumber(1),
            fields: [
                .init(tagID: "exif-focal", value: "40 mm"),
                .init(tagID: "xmp-title", value: "Should Not Stage"),
            ]
        )
        let preparedRun = ImportPreparedRun(
            options: options,
            parsedAsSourceKind: .eos1v,
            parseResult: ImportParseResult(rows: [row], warnings: []),
            matchResult: ImportMatchResult(
                matched: [ImportRowMatch(row: row, targetURL: file)],
                conflicts: [],
                warnings: []
            ),
            previewSummary: ImportPreviewSummary(
                sourceKind: .eos1v,
                parsedRows: 1,
                matchedRows: 1,
                conflictedRows: 0,
                warnings: 0,
                fieldWrites: 2
            )
        )

        let session = ImportSession(
            model: model,
            sourceKind: .eos1v,
            eosLensMappingURL: mappingCSV,
            lensChoiceProvider: { _ in nil }
        )
        session.preparedRun = preparedRun
        let success = await session.performImport(model: model)
        XCTAssertFalse(success)
        XCTAssertEqual(session.previewError, "Import was cancelled while choosing EOS lens values.")

        let snapshots = await model.importMetadataSnapshots(for: [file])
        let lens = snapshots[file]?.fields.first(where: { $0.namespace == .exif && $0.key == "LensModel" })?.value
        let title = snapshots[file]?.fields.first(where: { $0.namespace == .xmp && $0.key == "Title" })?.value
        XCTAssertNil(lens)
        XCTAssertNil(title)
    }

    func testImportSessionUsesCurrentEmptyPolicyWhenPreparedRunExists() async throws {
        let model = makeModel()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        model.browserItems = [
            AppModel.BrowserItem(url: file, name: file.lastPathComponent, modifiedAt: nil, createdAt: nil, sizeBytes: nil, kind: "jpg"),
        ]
        model.metadataByFile = [
            file: FileMetadataSnapshot(
                fileURL: file,
                fields: [
                    MetadataField(key: "Title", namespace: .xmp, value: "Old Title"),
                    MetadataField(key: "Make", namespace: .exif, value: "Canon"),
                ]
            ),
        ]

        var staleOptions = ImportRunOptions.defaults(for: .csv)
        staleOptions.scope = .folder
        staleOptions.emptyValuePolicy = .clear

        let row = ImportRow(
            sourceLine: 2,
            sourceIdentifier: file.lastPathComponent,
            targetSelector: .filename(file.lastPathComponent),
            fields: [.init(tagID: "xmp-title", value: "New Title")]
        )
        let stalePreparedRun = ImportPreparedRun(
            options: staleOptions,
            parsedAsSourceKind: .csv,
            parseResult: ImportParseResult(rows: [row], warnings: []),
            matchResult: ImportMatchResult(
                matched: [ImportRowMatch(row: row, targetURL: file)],
                conflicts: [],
                warnings: []
            ),
            previewSummary: ImportPreviewSummary(
                sourceKind: .csv,
                parsedRows: 1,
                matchedRows: 1,
                conflictedRows: 0,
                warnings: 0,
                fieldWrites: 1
            )
        )

        let session = ImportSession(model: model, sourceKind: .csv)
        session.preparedRun = stalePreparedRun
        session.options.emptyValuePolicy = .skip // changed after preview
        let success = await session.performImport(model: model)
        XCTAssertTrue(success)

        let snapshots = await model.importMetadataSnapshots(for: [file])
        let title = snapshots[file]?.fields.first(where: { $0.namespace == .xmp && $0.key == "Title" })?.value
        let make = snapshots[file]?.fields.first(where: { $0.namespace == .exif && $0.key == "Make" })?.value
        XCTAssertEqual(title, "New Title")
        XCTAssertEqual(make, "Canon", "Skip policy should retain missing fields when current options changed after preview.")
    }

    func testImportSessionUsesCurrentSelectedTagsWhenPreparedRunExists() async throws {
        let model = makeModel()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        model.browserItems = [
            AppModel.BrowserItem(url: file, name: file.lastPathComponent, modifiedAt: nil, createdAt: nil, sizeBytes: nil, kind: "jpg"),
        ]
        model.metadataByFile = [
            file: FileMetadataSnapshot(
                fileURL: file,
                fields: [
                    MetadataField(key: "Title", namespace: .xmp, value: "Old Title"),
                    MetadataField(key: "Make", namespace: .exif, value: "Canon"),
                ]
            ),
        ]

        var options = ImportRunOptions.defaults(for: .csv)
        options.scope = .folder
        options.selectedTagIDs = [] // stale preview options = all fields

        let row = ImportRow(
            sourceLine: 2,
            sourceIdentifier: file.lastPathComponent,
            targetSelector: .filename(file.lastPathComponent),
            fields: [
                .init(tagID: "xmp-title", value: "New Title"),
                .init(tagID: "exif-make", value: "Nikon"),
            ]
        )
        let preparedRun = ImportPreparedRun(
            options: options,
            parsedAsSourceKind: .csv,
            parseResult: ImportParseResult(rows: [row], warnings: []),
            matchResult: ImportMatchResult(
                matched: [ImportRowMatch(row: row, targetURL: file)],
                conflicts: [],
                warnings: []
            ),
            previewSummary: ImportPreviewSummary(
                sourceKind: .csv,
                parsedRows: 1,
                matchedRows: 1,
                conflictedRows: 0,
                warnings: 0,
                fieldWrites: 2
            )
        )

        let session = ImportSession(model: model, sourceKind: .csv)
        session.preparedRun = preparedRun
        session.options.selectedTagIDs = ["xmp-title"] // changed after preview
        let success = await session.performImport(model: model)
        XCTAssertTrue(success)

        let snapshots = await model.importMetadataSnapshots(for: [file])
        let title = snapshots[file]?.fields.first(where: { $0.namespace == .xmp && $0.key == "Title" })?.value
        let make = snapshots[file]?.fields.first(where: { $0.namespace == .exif && $0.key == "Make" })?.value
        XCTAssertEqual(title, "New Title")
        XCTAssertEqual(make, "Canon", "Only currently selected fields should stage when import is committed.")
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
            emptyValuePolicy: .clear
        )

        let snapshots = await model.importMetadataSnapshots(for: [file])
        let date = snapshots[file]?.fields.first(where: { $0.namespace == .exif && $0.key == "DateTimeOriginal" })?.value
        XCTAssertEqual(date, "2026:01:04 14:24:03")
    }

    func testExifToolCSVExportServiceRejectsEmptyInput() async throws {
        do {
            try await ExifToolCSVExportService().export(
                fileURLs: [],
                destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).csv")
            )
            XCTFail("Expected no-files export error")
        } catch let error as ExifToolCSVExportService.ExportError {
            guard case .noFiles = error else {
                XCTFail("Expected .noFiles error, got: \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testExifToolCSVExportServiceUsesOptionTerminatorBeforeFilePaths() {
        let files = [
            URL(fileURLWithPath: "/tmp/-leading-dash.jpg"),
            URL(fileURLWithPath: "/tmp/normal.jpg"),
        ]

        let arguments = ExifToolCSVExportService.exportArguments(for: files)
        XCTAssertEqual(arguments.prefix(4), ["-G4", "-a", "-csv", "--"])
        XCTAssertEqual(Array(arguments.dropFirst(4)), files.map(\.path))
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
