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
}
