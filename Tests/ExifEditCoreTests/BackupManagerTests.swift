import ExifEditCore
import Foundation
import XCTest

final class BackupManagerTests: XCTestCase {
    func testCreateAndRestoreBackup() throws {
        let operationID = UUID()
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: temp)
        }

        let file = temp.appendingPathComponent("test.jpg")
        try Data("original".utf8).write(to: file)

        let manager = BackupManager(baseDirectory: temp.appendingPathComponent("backups"))
        _ = try manager.createBackup(operationID: operationID, files: [file])

        try Data("updated".utf8).write(to: file)

        let result = try manager.restoreBackup(operationID: operationID)

        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), "original")
    }

    func testRestoreFailsGracefullyWhenManifestMissing() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let manager = BackupManager(baseDirectory: temp)
        let nonExistentID = UUID()

        XCTAssertThrowsError(try manager.restoreBackup(operationID: nonExistentID)) { error in
            guard let editError = error as? ExifEditError, case .backupNotFound = editError else {
                XCTFail("Expected ExifEditError.backupNotFound, got \(error)")
                return
            }
        }
    }

    func testPruneOperationsKeepsLastN() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // Use a subdirectory as the backup base so the dummy file doesn't contaminate counts.
        let backupsDir = temp.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let manager = BackupManager(baseDirectory: backupsDir)

        let file = temp.appendingPathComponent("dummy.jpg")
        try Data("x".utf8).write(to: file)

        // Create 5 operations
        for _ in 0..<5 {
            _ = try manager.createBackup(operationID: UUID(), files: [file])
        }

        let operationsBefore = try FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        XCTAssertEqual(operationsBefore.count, 5)

        try manager.pruneOperations(keepLast: 3)

        let operationsAfter = try FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        XCTAssertEqual(operationsAfter.count, 3)
    }

    func testPruneOperationsIsNoopWhenBaseDirectoryMissing() throws {
        let missingDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = BackupManager(baseDirectory: missingDir)
        XCTAssertNoThrow(try manager.pruneOperations(keepLast: 10))
    }
}
