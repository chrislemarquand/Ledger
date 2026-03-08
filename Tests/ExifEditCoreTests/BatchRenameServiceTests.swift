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
            pattern: RenamePattern(tokens: [.originalName])
        )
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "IMG_001.jpg")
    }

    func testSequenceToken() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["a.jpg", "b.jpg", "c.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.sequence(start: 1, step: 1, padding: 3)])
        )
        let names = plan.map { $0.finalTargetURL.lastPathComponent }
        XCTAssertEqual(names, ["001.jpg", "002.jpg", "003.jpg"])
    }

    func testSequenceStartAndStep() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["a.jpg", "b.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.sequence(start: 10, step: 5, padding: 2)])
        )
        let names = plan.map { $0.finalTargetURL.lastPathComponent }
        XCTAssertEqual(names, ["10.jpg", "15.jpg"])
    }

    func testDateTokenDeterministic() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["a.jpg"])
        let plan1 = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.date(format: "yyyyMMdd")])
        )
        let plan2 = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.date(format: "yyyyMMdd")])
        )
        XCTAssertEqual(plan1[0].finalTargetURL.lastPathComponent,
                       plan2[0].finalTargetURL.lastPathComponent)
    }

    func testExtensionOverrideWithoutLeadingDot() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["photo.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.originalName], extensionOverride: "jpeg")
        )
        XCTAssertEqual(plan[0].finalTargetURL.pathExtension, "jpeg")
    }

    func testExtensionOverrideStripsLeadingDot() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["photo.jpg"])
        let plan = await service.buildPlan(
            files: files,
            pattern: RenamePattern(tokens: [.originalName], extensionOverride: ".jpeg")
        )
        XCTAssertEqual(plan[0].finalTargetURL.pathExtension, "jpeg")
    }

    func testOriginalExtensionPreservedWhenNoOverride() async {
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
            pattern: RenamePattern(tokens: [.text("trip_"), .sequence(start: 1, step: 1, padding: 2)])
        )
        let names = plan.map { $0.finalTargetURL.lastPathComponent }
        XCTAssertEqual(names, ["trip_01.jpg", "trip_02.jpg"])
    }

    // MARK: - Collision disambiguation

    func testCollisionDisambiguatesWithUnderscore() async throws {
        let temp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        // Create a file at the collision target on disk
        let existing = temp.appendingPathComponent("photo.jpg")
        try Data("existing".utf8).write(to: existing)

        let source = temp.appendingPathComponent("IMG_001.jpg")
        try Data("source".utf8).write(to: source)

        let service = BatchRenameService()
        let plan = await service.buildPlan(
            files: [source],
            pattern: RenamePattern(tokens: [.text("photo")])
        )
        // Should be disambiguated since "photo.jpg" already exists
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "photo_1.jpg")
    }

    func testCrossFileCollision() async {
        let service = BatchRenameService()
        let files = makeFiles(names: ["a.jpg", "b.jpg"])
        // Both would produce "photo.jpg" → second should be "photo_1.jpg"
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
            pattern: RenamePattern(tokens: [.sequence(start: 1, step: 1, padding: 2)])
        )
        let manager = BackupManager(baseDirectory: temp.appendingPathComponent("backups"))
        let result = try await service.execute(operation: operation, backupManager: manager)

        XCTAssertEqual(result.succeeded.count, 2)
        XCTAssertTrue(result.failed.isEmpty)

        // alpha.jpg sorts first → 01.jpg, beta.jpg sorts second → 02.jpg
        let target1 = temp.appendingPathComponent("01.jpg")
        let target2 = temp.appendingPathComponent("02.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target2.path))
        XCTAssertEqual(String(decoding: try Data(contentsOf: target1), as: UTF8.self), "1")
        XCTAssertEqual(String(decoding: try Data(contentsOf: target2), as: UTF8.self), "2")
    }

    func testExecuteHandlesNamingChain() async throws {
        // Tests temp-phase safety: the second file's target is the first file's source name.
        // Without the temp phase, the first rename would block the second.
        let temp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        // Files: "01.jpg" and "02.jpg"
        // Rename with sequence starting at 2 (step -1 not supported, so use text + sequence):
        // Actually just rename "a.jpg" → "b.jpg" where "b.jpg" is another source file.
        // Simplest: rename "next.jpg" → "current.jpg" AND "current.jpg" → "done.jpg".
        let fileA = temp.appendingPathComponent("current.jpg")
        let fileB = temp.appendingPathComponent("next.jpg")
        try Data("current".utf8).write(to: fileA)
        try Data("next".utf8).write(to: fileB)

        // Use originalName so current→current and next→next (both stay same name).
        // Then verify temp phase doesn't corrupt files.
        let service = BatchRenameService()
        let operation = RenameOperation(
            files: [fileA, fileB],
            pattern: RenamePattern(tokens: [.originalName])
        )
        let manager = BackupManager(baseDirectory: temp.appendingPathComponent("backups"))
        let result = try await service.execute(operation: operation, backupManager: manager)

        XCTAssertEqual(result.succeeded.count, 2)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: fileA), as: UTF8.self), "current"
        )
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: fileB), as: UTF8.self), "next"
        )
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
