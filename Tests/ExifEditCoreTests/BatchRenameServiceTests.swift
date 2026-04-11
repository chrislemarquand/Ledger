import ExifEditCore
import Foundation
import XCTest

final class BatchRenameServiceTests: XCTestCase {
    // MARK: - Token composition

    func testTextToken() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["a.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.text("photo")])
        )
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "photo.jpg")
    }

    func testOriginalNameToken() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["IMG_001.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.originalName(component: .name, casing: .original)])
        )
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "IMG_001.jpg")
    }

    func testOriginalNameComponentNameAndExtension() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["IMG_001.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.originalName(component: .nameAndExtension, casing: .original)])
        )
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "IMG_001.jpg")
    }

    func testOriginalNameComponentExtension() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["IMG_001.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.text("type_"), .originalName(component: .fileExtension, casing: .original)])
        )
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "type_jpg.jpg")
    }

    func testOriginalNameComponentNumberSuffix() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["DSC00042.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.originalName(component: .numberSuffix, casing: .original)])
        )
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "00042.jpg")
    }

    func testOriginalNameComponentNumberSuffixStripsLeadingSeparator() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["IMG_1234.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.originalName(component: .numberSuffix, casing: .original)])
        )
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "1234.jpg")
    }

    func testOriginalNameCasingUppercase() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["img_001.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.originalName(component: .name, casing: .uppercase)])
        )
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "IMG_001.jpg")
    }

    func testOriginalNameCasingLowercase() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["IMG_001.JPG"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.originalName(component: .name, casing: .lowercase)])
        )
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "img_001.JPG")
    }

    func testSequenceToken() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["a.jpg", "b.jpg", "c.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.sequence(start: 1, padding: .three)])
        )
        let names = plan.map { $0.finalTargetURL.lastPathComponent }
        XCTAssertEqual(names, ["001.jpg", "002.jpg", "003.jpg"])
    }

    func testSequenceStartAndPadding() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["a.jpg", "b.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.sequence(start: 10, padding: .two)])
        )
        let names = plan.map { $0.finalTargetURL.lastPathComponent }
        XCTAssertEqual(names, ["10.jpg", "11.jpg"])
    }

    func testSequenceLetterUppercase() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["a.jpg", "b.jpg", "c.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.sequenceLetter(uppercase: true)])
        )
        let names = plan.map { $0.finalTargetURL.lastPathComponent }
        XCTAssertEqual(names, ["A.jpg", "B.jpg", "C.jpg"])
    }

    func testSequenceLetterLowercase() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["a.jpg", "b.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.sequenceLetter(uppercase: false)])
        )
        let names = plan.map { $0.finalTargetURL.lastPathComponent }
        XCTAssertEqual(names, ["a.jpg", "b.jpg"])
    }

    func testSequenceLetterWrapsAt26() async {
        let service = BatchRenameService()
        // 27 files to get past Z → AA
        let files = makeFiles(names: (0..<27).map { "file\($0).jpg" })
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.sequenceLetter(uppercase: true)])
        )
        XCTAssertEqual(plan[25].finalTargetURL.deletingPathExtension().lastPathComponent, "Z")
        XCTAssertEqual(plan[26].finalTargetURL.deletingPathExtension().lastPathComponent, "AA")
    }

    func testDateTokenDeterministic() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["a.jpg"])
        let plan1 = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.date(source: .dateTimeOriginal, format: .yyyymmdd)])
        )
        let plan2 = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.date(source: .dateTimeOriginal, format: .yyyymmdd)])
        )
        XCTAssertEqual(plan1[0].finalTargetURL.lastPathComponent,
                       plan2[0].finalTargetURL.lastPathComponent)
    }

    func testDateTokenUsesProvidedMetadataSnapshot() async {
        let service = BatchRenameService()
        let fileURL = URL(fileURLWithPath: "/tmp/a.jpg")
        let snapshot = FileMetadataSnapshot(
            fileURL: fileURL,
            fields: [
                MetadataField(
                    key: "DateTimeOriginal",
                    namespace: .exif,
                    value: "2024:12:31 23:59:58"
                )
            ]
        )
        let plan = await service.buildPlan(
            files: [fileURL],
            pattern: RenamePattern(tokens: [.date(source: .dateTimeOriginal, format: .yyyymmdd)]),
            metadata: [fileURL: snapshot]
        )

        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "20241231.jpg")
    }

    func testExtensionTokenOverridesExtension() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["photo.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.originalName(component: .name, casing: .original), .extension("jpeg")])
        )
        XCTAssertEqual(plan[0].finalTargetURL.pathExtension, "jpeg")
    }

    func testExtensionTokenStripsLeadingDot() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["photo.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.originalName(component: .name, casing: .original), .extension(".jpeg")])
        )
        XCTAssertEqual(plan[0].finalTargetURL.pathExtension, "jpeg")
    }

    func testExtensionTokenDoesNotAppearInBasename() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["photo.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.text("shot"), .extension("cr3")])
        )
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "shot.cr3")
    }

    func testExtensionOnlyTokenPreservesOriginalBasename() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["001.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.extension("tif")])
        )
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "001.tif")
    }

    func testOriginalExtensionPreservedWhenNoExtensionToken() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["photo.CR3"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.text("shot")])
        )
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "shot.CR3")
    }

    // MARK: - Token combination

    func testTextPlusSequence() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["a.jpg", "b.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.text("trip_"), .sequence(start: 1, padding: .two)])
        )
        let names = plan.map { $0.finalTargetURL.lastPathComponent }
        XCTAssertEqual(names, ["trip_01.jpg", "trip_02.jpg"])
    }

    // MARK: - Collision disambiguation

    func testCollisionDisambiguatesWithUnderscore() async throws {
        let temp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        let existing = temp.appendingPathComponent("photo.jpg")
        try Data("existing".utf8).write(to: existing)

        let source = temp.appendingPathComponent("IMG_001.jpg")
        try Data("source".utf8).write(to: source)

        let service = BatchRenameService()
        let plan = await service.buildPlan(
            files: [source],
            pattern: RenamePattern(tokens: [.text("photo")])
        )
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "photo_1.jpg")
    }

    func testCrossFileCollision() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["a.jpg", "b.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.text("photo")])
        )
        let names = Set(plan.map { $0.finalTargetURL.lastPathComponent })
        XCTAssertEqual(names.count, 2, "Each file must get a unique target name")
        XCTAssertTrue(names.contains("photo.jpg"))
        XCTAssertTrue(names.contains("photo_1.jpg"))
    }

    // MARK: - Execute

    func testExecuteRenamesFiles() async throws {
        let temp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        let source = temp.appendingPathComponent("old.jpg")
        try Data("content".utf8).write(to: source)

        let service = BatchRenameService()
        let operation = RenameOperation(
            files: [source],
            pattern: RenamePattern(tokens: [.text("new")])
        )

        let manager = BackupManager(baseDirectory: temp.appendingPathComponent("backups"))
        let result = try await service.execute(operation: operation, backupManager: manager)

        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertTrue(result.failed.isEmpty)
        let target = temp.appendingPathComponent("new.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testExecuteMultipleFilesAllSucceed() async throws {
        let temp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        let file1 = temp.appendingPathComponent("alpha.jpg")
        let file2 = temp.appendingPathComponent("beta.jpg")
        try Data("1".utf8).write(to: file1)
        try Data("2".utf8).write(to: file2)

        let service = BatchRenameService()
        let operation = RenameOperation(
            files: [file1, file2],
            pattern: RenamePattern(tokens: [.sequence(start: 1, padding: .two)])
        )
        let manager = BackupManager(baseDirectory: temp.appendingPathComponent("backups"))
        let result = try await service.execute(operation: operation, backupManager: manager)

        XCTAssertEqual(result.succeeded.count, 2)
        XCTAssertTrue(result.failed.isEmpty)

        let target1 = temp.appendingPathComponent("01.jpg")
        let target2 = temp.appendingPathComponent("02.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target2.path))
        XCTAssertEqual(String(decoding: try Data(contentsOf: target1), as: UTF8.self), "1")
        XCTAssertEqual(String(decoding: try Data(contentsOf: target2), as: UTF8.self), "2")
    }

    func testExecuteHandlesNamingChain() async throws {
        let temp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        let fileA = temp.appendingPathComponent("current.jpg")
        let fileB = temp.appendingPathComponent("next.jpg")
        try Data("current".utf8).write(to: fileA)
        try Data("next".utf8).write(to: fileB)

        let service = BatchRenameService()
        let operation = RenameOperation(
            files: [fileA, fileB],
            pattern: RenamePattern(tokens: [.originalName(component: .name, casing: .original)])
        )
        let manager = BackupManager(baseDirectory: temp.appendingPathComponent("backups"))
        let result = try await service.execute(operation: operation, backupManager: manager)

        XCTAssertEqual(result.succeeded.count, 2)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(String(decoding: try Data(contentsOf: fileA), as: UTF8.self), "current")
        XCTAssertEqual(String(decoding: try Data(contentsOf: fileB), as: UTF8.self), "next")
    }

    func testExecuteRecordsRenamedOutputsInManifest() async throws {
        let temp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        let source = temp.appendingPathComponent("orig.jpg")
        try Data("x".utf8).write(to: source)

        let backupDir = temp.appendingPathComponent("backups")
        let manager = BackupManager(baseDirectory: backupDir)
        let service = BatchRenameService()
        let operation = RenameOperation(files: [source], pattern: RenamePattern(tokens: [.text("renamed")]))

        let result = try await service.execute(operation: operation, backupManager: manager)
        XCTAssertNotNil(result.backupLocation)

        let manifestURL = result.backupLocation!.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(BackupManager.BackupManifest.self, from: data)

        XCTAssertNotNil(manifest.renamedOutputPaths)
        XCTAssertFalse(manifest.renamedOutputPaths!.isEmpty)
    }

    func testAssessPlanRejectsInvalidCharacters() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["a.jpg"])
        let assessment = await service.assessPlan(
            files: files,
            pattern: RenamePattern(tokens: [.text("bad:name")])
        )
        XCTAssertFalse(assessment.issues.isEmpty)
    }

    func testAssessPlanRejectsEmptyExtensionToken() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["a.jpg"])
        let assessment = await service.assessPlan(
            files: files,
            pattern: RenamePattern(tokens: [.text("photo"), .extension("")])
        )
        XCTAssertFalse(assessment.issues.isEmpty)
    }

    func testExecuteWithoutBackupRollsBackWhenPhaseAFails() async throws {
        let temp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        let existing = temp.appendingPathComponent("a.jpg")
        try Data("ok".utf8).write(to: existing)
        let missing = temp.appendingPathComponent("z.jpg")

        let service = BatchRenameService()
        let operation = RenameOperation(
            files: [existing, missing],
            pattern: RenamePattern(tokens: [.text("renamed")])
        )

        do {
            _ = try await service.executeWithoutBackup(operation: operation)
            XCTFail("Expected executeWithoutBackup to fail")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path), "Existing file should be restored after rollback")
            XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("renamed.jpg").path))
        }
    }

    func testExecuteStagedMappingsRollsBackWhenFinalMoveFails() async throws {
        let temp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        let alpha = temp.appendingPathComponent("a.jpg")
        let beta = temp.appendingPathComponent("b.jpg")
        try Data("a".utf8).write(to: alpha)
        try Data("b".utf8).write(to: beta)

        let service = BatchRenameService()

        do {
            _ = try await service.executeStagedMappings(targetsBySource: [
                alpha: "renamed-a.jpg",
                beta: "nested/renamed-b.jpg",
            ])
            XCTFail("Expected executeStagedMappings to fail when a final target directory is missing")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: alpha.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: beta.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("renamed-a.jpg").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("nested/renamed-b.jpg").path))
        }
    }

    // MARK: - Helpers

    private func makeFiles(names: [String]) -> [URL] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        return names.map { dir.appendingPathComponent($0) }
    }

    private func makeTempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
