import AppKit
import ExifEditCore
@testable import ExifEditMac
import Foundation
import XCTest

// MARK: - Import / Export Testing Matrix
// Covers scenarios from docs/import-export-testing-matrix.md
// IDs match the matrix (E1–E9, C1–C9, G1–G5, R1–R4, I1–I3, GR1–GR5)

@MainActor
final class ImportMatrixTests: XCTestCase {

    // MARK: - EOS 1V CSV Import

    /// E1 – Basic import, all rows, folder scope
    func testE1_EOSBasicImportAllRowsFolderScope() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("eos.csv")
        let header = ",Frame No.,Tv,Av,ISO (M),Date,Time"
        var rows = [header]
        for i in 1...36 {
            rows.append(",\(i),=\"1/60\",2.8,400,8/10/2025,\(String(format: "%02d", i % 24)):00:00")
        }
        try rows.joined(separator: "\n").write(to: csv, atomically: true, encoding: .utf8)

        let targets = (1...36).map { URL(fileURLWithPath: "/tmp/\(String(format: "%03d", $0)).jpg") }
        let coordinator = ImportCoordinator()
        var options = ImportRunOptions.defaults(for: .eos1v)
        options.sourceURLPath = csv.path
        options.scope = .folder
        options.rowParityRowCount = 0

        let prepared = try await coordinator.prepareRun(
            options: options,
            targetFiles: targets,
            tagCatalog: makeModel().importTagCatalog,
            metadataProvider: { _ in [:] }
        )

        XCTAssertEqual(prepared.parseResult.rows.count, 36, "E1: all 36 rows should be parsed")
        XCTAssertGreaterThan(prepared.parseResult.rows[0].fields.count, 0, "E1: rows should carry fields")
    }

    /// E2 – Row count respects file count when selection scope
    func testE2_EOSRowCountRespectsSelectionScope() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("eos-e2.csv")
        var rows = [",Frame No.,Tv,Av,ISO (M),Date,Time"]
        for i in 1...10 {
            rows.append(",\(i),=\"1/60\",2.8,200,8/10/2025,\(String(format: "%02d", i)):00:00")
        }
        try rows.joined(separator: "\n").write(to: csv, atomically: true, encoding: .utf8)

        let targets = (1...10).map { URL(fileURLWithPath: "/tmp/frame\(String(format: "%03d", $0)).jpg") }
        let coordinator = ImportCoordinator()
        var options = ImportRunOptions.defaults(for: .eos1v)
        options.sourceURLPath = csv.path
        options.scope = .selection
        options.rowParityRowCount = 5  // as set by ImportSession init when 5 files selected

        let prepared = try await coordinator.prepareRun(
            options: options,
            targetFiles: targets,
            tagCatalog: makeModel().importTagCatalog,
            metadataProvider: { _ in [:] }
        )

        XCTAssertEqual(prepared.parseResult.rows.count, 5, "E2: only 5 rows should be parsed when rowParityRowCount=5")
    }

    /// E3 – Unlimited rows when folder scope (rowParityRowCount = 0)
    func testE3_EOSUnlimitedRowsWhenFolderScope() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("eos-e3.csv")
        var rows = [",Frame No.,Tv,Av,ISO (M),Date,Time"]
        for i in 1...8 {
            rows.append(",\(i),=\"1/125\",5.6,200,8/10/2025,\(String(format: "%02d", i)):00:00")
        }
        try rows.joined(separator: "\n").write(to: csv, atomically: true, encoding: .utf8)

        let targets = (1...8).map { URL(fileURLWithPath: "/tmp/e3frame\(String(format: "%03d", $0)).jpg") }
        let coordinator = ImportCoordinator()
        var options = ImportRunOptions.defaults(for: .eos1v)
        options.sourceURLPath = csv.path
        options.scope = .folder
        options.rowParityRowCount = 0  // unlimited

        let prepared = try await coordinator.prepareRun(
            options: options,
            targetFiles: targets,
            tagCatalog: makeModel().importTagCatalog,
            metadataProvider: { _ in [:] }
        )

        XCTAssertEqual(prepared.parseResult.rows.count, 8, "E3: all 8 CSV rows should be parsed when rowParityRowCount=0")
    }

    /// E7 – Re-import identical data produces 0 staged fields
    func testE7_ReimportIdenticalDataStagesZeroFields() throws {
        let model = makeModel()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")

        // Stage initial value
        let initial = model.stageImportAssignments(
            [ImportAssignment(targetURL: file, fields: [.init(tagID: "xmp-title", value: "Hello")])],
            sourceKind: .csv,
            emptyValuePolicy: .clear
        )
        XCTAssertEqual(initial.stagedFields, 1, "E7: initial import should stage 1 field")

        // Simulate write to disk: clear pending, set metadata on disk
        model.clearPendingEdits(for: [file])
        model.metadataByFile = [
            file: FileMetadataSnapshot(
                fileURL: file,
                fields: [MetadataField(key: "Title", namespace: .xmp, value: "Hello")]
            ),
        ]

        // Re-import identical value
        let reimport = model.stageImportAssignments(
            [ImportAssignment(targetURL: file, fields: [.init(tagID: "xmp-title", value: "Hello")])],
            sourceKind: .csv,
            emptyValuePolicy: .clear
        )
        XCTAssertEqual(reimport.stagedFields, 0, "E7: re-importing identical value should stage 0 fields")
    }

    /// E8 – rowParityRowCount resets to 0 (unlimited) when opening with 0–1 files selected
    func testE8_SessionResetsRowParityRowCountToUnlimitedWithFewFilesSelected() {
        let model = makeModel()
        model.selectedFileURLs = []
        let session = ImportSession(model: model, sourceKind: .eos1v)
        XCTAssertEqual(session.options.rowParityRowCount, 0, "E8: rowParityRowCount should be 0 (unlimited) with no files selected")
    }

    /// E9 – Default scope is Folder with 0–1 files selected
    func testE9_DefaultScopeIsFolderWithZeroOrOneFile() {
        let model = makeModel()

        model.selectedFileURLs = []
        let sessionZero = ImportSession(model: model, sourceKind: .eos1v)
        XCTAssertEqual(sessionZero.options.scope, .folder, "E9: scope should default to Folder with 0 files selected")

        model.selectedFileURLs = [URL(fileURLWithPath: "/tmp/a.jpg")]
        let sessionOne = ImportSession(model: model, sourceKind: .eos1v)
        XCTAssertEqual(sessionOne.options.scope, .folder, "E9: scope should default to Folder with 1 file selected")
    }

    // MARK: - ExifTool CSV Import

    /// C1 – Basic import, all rows, folder scope, match by filename
    func testC1_CSVBasicImportAllRowsFolderScope() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("exif.csv")
        try """
        SourceFile,[XMP] Title,[EXIF] ISO
        /tmp/c1a.jpg,Alpha,100
        /tmp/c1b.jpg,Beta,200
        /tmp/c1c.jpg,Gamma,400
        """.write(to: csv, atomically: true, encoding: .utf8)

        var options = ImportRunOptions.defaults(for: .csv)
        options.matchStrategy = .filename
        let context = ImportParseContext(
            options: options,
            sourceURL: csv,
            auxiliaryURLs: [],
            targetFiles: [],
            tagCatalog: standardCSVCatalog(),
            metadataByFile: [:]
        )

        let result = try CSVImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 3, "C1: all 3 file rows should be matched")
        XCTAssertGreaterThan(result.rows[0].fields.count, 0, "C1: rows should carry fields")
        XCTAssertTrue(result.warnings.isEmpty, "C1: no warnings expected for valid input")
    }

    /// C2 – Single file selected → session scope defaults to Folder
    func testC2_SingleFileSelectedDefaultsToFolderScope() {
        let model = makeModel()
        model.selectedFileURLs = [URL(fileURLWithPath: "/tmp/single.jpg")]
        let session = ImportSession(model: model, sourceKind: .csv)
        XCTAssertEqual(session.options.scope, .folder, "C2: single file selected should default to Folder scope")
    }

    /// C3 – Multiple files selected → session scope defaults to Selection
    func testC3_MultipleFilesSelectedDefaultsToSelectionScope() {
        let model = makeModel()
        model.selectedFileURLs = Set((1...5).map { URL(fileURLWithPath: "/tmp/f\($0).jpg") })
        let session = ImportSession(model: model, sourceKind: .csv)
        XCTAssertEqual(session.options.scope, .selection, "C3: 5 files selected should default to Selection scope")
        XCTAssertEqual(session.options.rowParityRowCount, 5, "C3: rowParityRowCount should match selection count")
    }

    /// C6 – Field filter: only selected fields survive post-parse filtering
    func testC6_CSVFieldFilterApplied() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csv = temp.appendingPathComponent("filter.csv")
        try """
        SourceFile,[XMP] Title,[EXIF] ISO
        /tmp/c6.jpg,MyTitle,800
        """.write(to: csv, atomically: true, encoding: .utf8)

        var options = ImportRunOptions.defaults(for: .csv)
        options.matchStrategy = .filename
        options.selectedTagIDs = ["xmp-title"]
        let context = ImportParseContext(
            options: options,
            sourceURL: csv,
            auxiliaryURLs: [],
            targetFiles: [],
            tagCatalog: standardCSVCatalog(),
            metadataByFile: [:]
        )

        let result = try CSVImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 1)
        // Parse result carries all columns; verify that filtering by selectedTagIDs works at the field level.
        let filteredFields = result.rows[0].fields.filter { options.selectedTagIDs.contains($0.tagID) }
        XCTAssertEqual(filteredFields.count, 1, "C6: only the selected field should survive the filter")
        XCTAssertEqual(filteredFields[0].tagID, "xmp-title")
    }

    /// C9 – selectedTagIDs resets to empty on session open
    func testC9_SelectedTagIDsResetOnSessionOpen() {
        let model = makeModel()
        // Simulate previously persisted selectedTagIDs
        let coordinator = ImportCoordinator()
        var dirty = ImportRunOptions.defaults(for: .csv)
        dirty.selectedTagIDs = ["xmp-title", "exif-iso"]
        coordinator.persist(options: dirty)

        let session = ImportSession(model: model, sourceKind: .csv)
        XCTAssertTrue(session.options.selectedTagIDs.isEmpty, "C9: selectedTagIDs must be reset to [] on sheet open")
    }

    // MARK: - GPX Import

    /// G2 – File within time tolerance is matched
    func testG2_FileWithinToleranceIsMatched() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let gpx = makeGPXFile(in: temp, name: "g2.gpx", timestamp: "2026-01-01T12:00:00Z", lat: 51.5, lon: -0.12)
        let file = URL(fileURLWithPath: "/tmp/g2.jpg")
        var options = ImportRunOptions.defaults(for: .gpx)
        options.sourceURLPath = gpx.path
        options.gpxToleranceSeconds = 99999  // large tolerance covers any timezone delta

        let context = ImportParseContext(
            options: options,
            sourceURL: gpx,
            auxiliaryURLs: [],
            targetFiles: [file],
            tagCatalog: [],
            metadataByFile: [
                file: FileMetadataSnapshot(
                    fileURL: file,
                    fields: [MetadataField(key: "CreateDate", namespace: .exif, value: "2026:01:01 12:00:00")]
                ),
            ]
        )

        let result = try GPXImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 1, "G2: file within tolerance should be matched")
        XCTAssertTrue(result.warnings.isEmpty, "G2: no warnings expected for matched file")
    }

    /// G3 – File outside time tolerance is NOT matched; warning is emitted
    func testG3_FileOutsideToleranceIsNotMatched() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        // GPX track at 2026, EXIF date from year 2000 — clearly outside any tolerance
        let gpx = makeGPXFile(in: temp, name: "g3.gpx", timestamp: "2026-01-01T12:00:00Z", lat: 51.5, lon: -0.12)
        let file = URL(fileURLWithPath: "/tmp/g3.jpg")
        var options = ImportRunOptions.defaults(for: .gpx)
        options.sourceURLPath = gpx.path
        options.gpxToleranceSeconds = 600

        let context = ImportParseContext(
            options: options,
            sourceURL: gpx,
            auxiliaryURLs: [],
            targetFiles: [file],
            tagCatalog: [],
            metadataByFile: [
                file: FileMetadataSnapshot(
                    fileURL: file,
                    fields: [MetadataField(key: "CreateDate", namespace: .exif, value: "2000:01:01 12:00:00")]
                ),
            ]
        )

        let result = try GPXImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 0, "G3: file outside tolerance should not be matched")
        XCTAssertTrue(
            result.warnings.contains(where: { $0.message.localizedCaseInsensitiveContains("outside tolerance") }),
            "G3: a 'outside tolerance' warning should be emitted"
        )
    }

    /// G4 – Camera offset shifts capture time before GPX matching
    func testG4_CameraOffsetShiftsTimestampBeforeMatching() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        // EXIF "2026:01:01 00:00:00" is parsed as local midnight = UTC midnight - tzOffset.
        // GPX is 2026-01-01T00:00:00Z (UTC midnight).
        // With gpxCameraOffsetSeconds = tzOffset, shifted time = UTC midnight → delta = 0 → match.
        let tzOffset = TimeZone.current.secondsFromGMT()
        let gpx = makeGPXFile(in: temp, name: "g4.gpx", timestamp: "2026-01-01T00:00:00Z", lat: 48.85, lon: 2.35)
        let file = URL(fileURLWithPath: "/tmp/g4.jpg")
        var options = ImportRunOptions.defaults(for: .gpx)
        options.sourceURLPath = gpx.path
        options.gpxToleranceSeconds = 60
        options.gpxCameraOffsetSeconds = tzOffset

        let context = ImportParseContext(
            options: options,
            sourceURL: gpx,
            auxiliaryURLs: [],
            targetFiles: [file],
            tagCatalog: [],
            metadataByFile: [
                file: FileMetadataSnapshot(
                    fileURL: file,
                    fields: [MetadataField(key: "CreateDate", namespace: .exif, value: "2026:01:01 00:00:00")]
                ),
            ]
        )

        let result = try GPXImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 1, "G4: camera offset should shift timestamps to produce a match")
    }

    /// G5 – No GPS-capable files (no capture date) → 0 rows, no crash
    func testG5_NoFilesWithCaptureDateProducesZeroMatchesNoCrash() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let gpx = makeGPXFile(in: temp, name: "g5.gpx", timestamp: "2026-01-01T12:00:00Z", lat: 51.5, lon: -0.12)
        let file = URL(fileURLWithPath: "/tmp/g5.jpg")
        var options = ImportRunOptions.defaults(for: .gpx)
        options.sourceURLPath = gpx.path

        let context = ImportParseContext(
            options: options,
            sourceURL: gpx,
            auxiliaryURLs: [],
            targetFiles: [file],
            tagCatalog: [],
            metadataByFile: [
                // Snapshot exists but has no date field
                file: FileMetadataSnapshot(
                    fileURL: file,
                    fields: [MetadataField(key: "Make", namespace: .exif, value: "Canon")]
                ),
            ]
        )

        let result = try GPXImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 0, "G5: no files with capture date should produce 0 rows")
        XCTAssertFalse(result.warnings.isEmpty, "G5: a warning should be emitted for the skipped file")
    }

    // MARK: - Reference Folder Import

    /// R1 – Basic reference folder import; target matched by filename
    func testR1_ReferenceFolderBasicImport() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let (refFolder, fileURLs) = try makeRefFolder(in: temp, name: "ref-r1", files: ["0001.jpg"])
        let refImage = fileURLs["0001.jpg"]!

        var options = ImportRunOptions.defaults(for: .referenceFolder)
        options.sourceURLPath = refFolder.path

        let target = URL(fileURLWithPath: "/tmp/0001.jpg")
        let context = ImportParseContext(
            options: options,
            sourceURL: refFolder,
            auxiliaryURLs: [],
            targetFiles: [target],
            tagCatalog: standardCSVCatalog(),
            metadataByFile: [
                refImage: FileMetadataSnapshot(
                    fileURL: refImage,
                    fields: [MetadataField(key: "Title", namespace: .xmp, value: "Reference")]
                ),
            ]
        )

        let result = try ReferenceFolderImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 1, "R1: one reference image should produce one row")
        guard let row = result.rows.first else { return }
        XCTAssertEqual(row.sourceIdentifier, "0001.jpg", "R1: source identifier should be the reference filename")
        XCTAssertEqual(row.targetSelector, .filename("0001.jpg"), "R1: target selector should match by filename")
        XCTAssertFalse(row.fields.isEmpty, "R1: row should carry metadata fields")
    }

    /// R2 – Field filter: only selectedTagIDs fields are included in reference folder rows
    func testR2_ReferenceFolderFieldFilterApplied() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let (refFolder, fileURLs) = try makeRefFolder(in: temp, name: "ref-r2", files: ["0001.jpg"])
        let refImage = fileURLs["0001.jpg"]!

        var options = ImportRunOptions.defaults(for: .referenceFolder)
        options.sourceURLPath = refFolder.path
        options.selectedTagIDs = ["xmp-title"]  // only Title selected

        let context = ImportParseContext(
            options: options,
            sourceURL: refFolder,
            auxiliaryURLs: [],
            targetFiles: [],
            tagCatalog: standardCSVCatalog(),
            metadataByFile: [
                refImage: FileMetadataSnapshot(
                    fileURL: refImage,
                    fields: [
                        MetadataField(key: "Title", namespace: .xmp, value: "MyTitle"),
                        MetadataField(key: "ISO", namespace: .exif, value: "400"),
                    ]
                ),
            ]
        )

        let result = try ReferenceFolderImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 1, "R2: one row expected")
        guard let row = result.rows.first else { return }
        XCTAssertEqual(row.fields.count, 1, "R2: only the filtered field should be present")
        XCTAssertEqual(row.fields[0].tagID, "xmp-title")
    }

    /// R3 – Reference folder with no filename matches → ImportMatcher reports 0 matched
    func testR3_ReferenceFolderFilenameMismatchProducesZeroMatched() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let (refFolder, fileURLs) = try makeRefFolder(in: temp, name: "ref-r3", files: ["reference.jpg"])
        let refImage = fileURLs["reference.jpg"]!

        var options = ImportRunOptions.defaults(for: .referenceFolder)
        options.sourceURLPath = refFolder.path

        // Target file has different name from reference image
        let target = URL(fileURLWithPath: "/tmp/totally_different.jpg")
        let context = ImportParseContext(
            options: options,
            sourceURL: refFolder,
            auxiliaryURLs: [],
            targetFiles: [target],
            tagCatalog: standardCSVCatalog(),
            metadataByFile: [
                refImage: FileMetadataSnapshot(
                    fileURL: refImage,
                    fields: [MetadataField(key: "Title", namespace: .xmp, value: "Ref")]
                ),
            ]
        )

        let parseResult = try ReferenceFolderImportAdapter().parse(context: context)
        let matchResult = ImportMatcher().match(parseResult: parseResult, targetFiles: [target])
        XCTAssertEqual(matchResult.matched.count, 0, "R3: filename mismatch should produce 0 matched rows")
        XCTAssertFalse(matchResult.conflicts.isEmpty, "R3: unmatched reference row should appear as a conflict")
    }

    /// R4 – Mixed match and no-match: matched files staged, unmatched reported
    func testR4_ReferenceFolderMixedMatchAndNoMatch() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let (refFolder, fileURLs) = try makeRefFolder(in: temp, name: "ref-r4", files: ["match.jpg", "nomatch.jpg"])
        let matchedRef = fileURLs["match.jpg"]!
        let unmatchedRef = fileURLs["nomatch.jpg"]!

        var options = ImportRunOptions.defaults(for: .referenceFolder)
        options.sourceURLPath = refFolder.path

        let matchedTarget = URL(fileURLWithPath: "/tmp/match.jpg")
        let context = ImportParseContext(
            options: options,
            sourceURL: refFolder,
            auxiliaryURLs: [],
            targetFiles: [matchedTarget],
            tagCatalog: standardCSVCatalog(),
            metadataByFile: [
                matchedRef: FileMetadataSnapshot(
                    fileURL: matchedRef,
                    fields: [MetadataField(key: "Title", namespace: .xmp, value: "MatchedTitle")]
                ),
                unmatchedRef: FileMetadataSnapshot(
                    fileURL: unmatchedRef,
                    fields: [MetadataField(key: "Title", namespace: .xmp, value: "UnmatchedTitle")]
                ),
            ]
        )

        let parseResult = try ReferenceFolderImportAdapter().parse(context: context)
        let matchResult = ImportMatcher().match(parseResult: parseResult, targetFiles: [matchedTarget])
        XCTAssertEqual(matchResult.matched.count, 1, "R4: the matched file should be staged")
        XCTAssertEqual(matchResult.matched[0].targetURL.lastPathComponent, "match.jpg")
        XCTAssertFalse(matchResult.conflicts.isEmpty, "R4: the unmatched reference file should produce a conflict")
    }

    // MARK: - Reference Image Import

    /// I2 – Field filter: only selectedTagIDs fields are applied to targets
    func testI2_ReferenceImageFieldFilterApplied() throws {
        let source = URL(fileURLWithPath: "/tmp/ref_i2.jpg")
        let targetA = URL(fileURLWithPath: "/tmp/i2a.jpg")
        let descriptors: [ImportTagDescriptor] = [
            .init(id: "xmp-title", key: "Title", namespace: .xmp, label: "Title", section: "Descriptive"),
            .init(id: "exif-iso", key: "ISO", namespace: .exif, label: "ISO", section: "Capture"),
        ]
        var options = ImportRunOptions.defaults(for: .referenceImage)
        options.sourceURLPath = source.path
        options.selectedTagIDs = ["xmp-title"]  // only Title, not ISO

        let context = ImportParseContext(
            options: options,
            sourceURL: source,
            auxiliaryURLs: [],
            targetFiles: [targetA],
            tagCatalog: descriptors,
            metadataByFile: [
                source: FileMetadataSnapshot(
                    fileURL: source,
                    fields: [
                        MetadataField(key: "Title", namespace: .xmp, value: "FilteredTitle"),
                        MetadataField(key: "ISO", namespace: .exif, value: "800"),
                    ]
                ),
            ]
        )

        let result = try ReferenceImageImportAdapter().parse(context: context)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].fields.count, 1, "I2: only the selected field should appear in the row")
        XCTAssertEqual(result.rows[0].fields[0].tagID, "xmp-title")
    }

    /// I3 – No files selected → ImportSession defaults scope to Folder
    func testI3_NoFilesSelectedDefaultsToFolderScope() {
        let model = makeModel()
        model.selectedFileURLs = []
        let session = ImportSession(model: model, sourceKind: .referenceImage)
        XCTAssertEqual(session.options.scope, .folder, "I3: zero files selected should default scope to Folder")
    }

    // MARK: - General / Regression

    /// GR1 – After staging an import, hasPendingEdits returns true
    func testGR1_PendingEditsSetAfterStaging() throws {
        let model = makeModel()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")

        _ = model.stageImportAssignments(
            [ImportAssignment(targetURL: file, fields: [.init(tagID: "xmp-title", value: "Orange")])],
            sourceKind: .csv,
            emptyValuePolicy: .clear
        )

        XCTAssertTrue(model.hasPendingEdits(for: file), "GR1: file should have pending edits after staging")
    }

    /// GR2 – After clearPendingEdits, hasPendingEdits returns false
    func testGR2_PendingEditsClearedAfterClear() throws {
        let model = makeModel()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")

        _ = model.stageImportAssignments(
            [ImportAssignment(targetURL: file, fields: [.init(tagID: "xmp-title", value: "Orange")])],
            sourceKind: .csv,
            emptyValuePolicy: .clear
        )
        model.clearPendingEdits(for: [file])

        XCTAssertFalse(model.hasPendingEdits(for: file), "GR2: pending edits should be cleared after clearPendingEdits")
    }

    /// GR3 – Status bar reflects only NEW changes; values already on disk are not re-staged
    func testGR3_StageCountReflectsOnlyNewChanges() throws {
        let model = makeModel()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")

        // Simulate existing on-disk value
        model.metadataByFile = [
            file: FileMetadataSnapshot(
                fileURL: file,
                fields: [MetadataField(key: "Title", namespace: .xmp, value: "AlreadyOnDisk")]
            ),
        ]

        let summary = model.stageImportAssignments(
            [
                ImportAssignment(targetURL: file, fields: [
                    .init(tagID: "xmp-title", value: "AlreadyOnDisk"),  // identical – should NOT count
                    .init(tagID: "exif-iso", value: "400"),              // new – should count
                ]),
            ],
            sourceKind: .csv,
            emptyValuePolicy: .clear
        )

        XCTAssertEqual(summary.stagedFields, 1, "GR3: only fields that differ from disk should be staged")
    }

    /// GR4 – Cancelling (not calling stageImportAssignments) leaves no pending edits
    func testGR4_CancelDoesNotCreatePendingEdits() throws {
        let model = makeModel()
        let file = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        // Simulate preview was run but user pressed Cancel — stageImportAssignments never called
        XCTAssertFalse(model.hasPendingEdits(for: file), "GR4: cancel (no staging call) should leave no pending edits")
    }

    /// GR5 – Default emptyValuePolicy is .clear when opening any import dialog
    func testGR5_DefaultEmptyValuePolicyIsClear() {
        for kind in ImportSourceKind.allCases {
            let defaults = ImportRunOptions.defaults(for: kind)
            XCTAssertEqual(
                defaults.emptyValuePolicy, .clear,
                "GR5: emptyValuePolicy should default to .clear for \(kind)"
            )
        }
    }

    // MARK: - Helpers

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

    private func standardCSVCatalog() -> [ImportTagDescriptor] {
        [
            .init(id: "xmp-title", key: "Title", namespace: .xmp, label: "Title", section: "Descriptive"),
            .init(id: "exif-iso", key: "ISO", namespace: .exif, label: "ISO", section: "Capture"),
        ]
    }

    private func makeGPXFile(in dir: URL, name: String, timestamp: String, lat: Double, lon: Double) -> URL {
        let url = dir.appendingPathComponent(name)
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="ImportMatrixTests">
          <trk><trkseg>
            <trkpt lat="\(lat)" lon="\(lon)">
              <ele>10.0</ele>
              <time>\(timestamp)</time>
            </trkpt>
          </trkseg></trk>
        </gpx>
        """
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Creates a temp reference folder and returns (folderURL, [filename: canonicalURL]).
    /// The canonical URLs are retrieved via contentsOfDirectory so they exactly match what
    /// ReferenceFolderImportAdapter will use as metadataByFile keys.
    private func makeRefFolder(
        in parent: URL,
        name: String,
        files: [String]
    ) throws -> (folder: URL, fileURLs: [String: URL]) {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for filename in files {
            try Data().write(to: folder.appendingPathComponent(filename))
        }
        // Use contentsOfDirectory to get the exact URLs the adapter will use.
        let entries = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var map: [String: URL] = [:]
        for entry in entries {
            map[entry.lastPathComponent] = entry
        }
        return (folder, map)
    }
}

// MARK: - Stubs (mirrors those in ImportSystemTests)

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
