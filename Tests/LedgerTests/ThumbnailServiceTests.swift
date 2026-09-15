@testable import Ledger
import Foundation
import XCTest

// v1.4 Phase 3.3: the disk thumbnail cache previously had no size bound at all. These verify
// the eviction policy directly (pure selection logic) and end-to-end against a real temporary
// cache directory (per the plan's "unit-test selection/deletion with a temporary cache").
final class ThumbnailServiceTests: XCTestCase {
    func testEvictionSelectsNothingWhenUnderBudget() {
        let items = [
            (url: URL(fileURLWithPath: "/tmp/a.jpg"), size: 100, modifiedAt: Date(timeIntervalSince1970: 1)),
            (url: URL(fileURLWithPath: "/tmp/b.jpg"), size: 100, modifiedAt: Date(timeIntervalSince1970: 2)),
        ]
        let evicted = ThumbnailService.urlsToEvictForDiskCacheMaintenance(
            items: items, totalSize: 200, budgetBytes: 1000, trimTargetBytes: 800
        )
        XCTAssertTrue(evicted.isEmpty)
    }

    func testEvictionRemovesOldestFirstUntilAtOrUnderTrimTarget() {
        // Four 100-byte entries, oldest to newest, total 400. Budget 300, trim target 200:
        // over budget by 100, must evict the oldest until remaining <= 200 -- exactly the two
        // oldest (400 -> 300 after one eviction, still > 200 -> 200 after a second).
        let items = [
            (url: URL(fileURLWithPath: "/tmp/oldest.jpg"), size: 100, modifiedAt: Date(timeIntervalSince1970: 1)),
            (url: URL(fileURLWithPath: "/tmp/second.jpg"), size: 100, modifiedAt: Date(timeIntervalSince1970: 2)),
            (url: URL(fileURLWithPath: "/tmp/third.jpg"), size: 100, modifiedAt: Date(timeIntervalSince1970: 3)),
            (url: URL(fileURLWithPath: "/tmp/newest.jpg"), size: 100, modifiedAt: Date(timeIntervalSince1970: 4)),
        ]
        let evicted = ThumbnailService.urlsToEvictForDiskCacheMaintenance(
            items: items, totalSize: 400, budgetBytes: 300, trimTargetBytes: 200
        )
        XCTAssertEqual(evicted, [
            URL(fileURLWithPath: "/tmp/oldest.jpg"),
            URL(fileURLWithPath: "/tmp/second.jpg"),
        ])
    }

    func testEvictionOrdersByModificationDateRegardlessOfInputOrder() {
        let items = [
            (url: URL(fileURLWithPath: "/tmp/newest.jpg"), size: 50, modifiedAt: Date(timeIntervalSince1970: 100)),
            (url: URL(fileURLWithPath: "/tmp/oldest.jpg"), size: 50, modifiedAt: Date(timeIntervalSince1970: 1)),
            (url: URL(fileURLWithPath: "/tmp/middle.jpg"), size: 50, modifiedAt: Date(timeIntervalSince1970: 50)),
        ]
        let evicted = ThumbnailService.urlsToEvictForDiskCacheMaintenance(
            items: items, totalSize: 150, budgetBytes: 100, trimTargetBytes: 60
        )
        // Must evict oldest first regardless of array order; stop once remaining <= 60.
        XCTAssertEqual(evicted, [
            URL(fileURLWithPath: "/tmp/oldest.jpg"),
            URL(fileURLWithPath: "/tmp/middle.jpg"),
        ])
    }

    func testPerformDiskCacheMaintenanceDeletesOldestFilesOnARealTemporaryDirectory() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThumbnailServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Three 1KB files, given distinct modification dates via setAttributes since creation
        // order alone isn't a reliable proxy for mtime ordering under fast test execution.
        let payload = Data(repeating: 0x42, count: 1024)
        let fileNames = ["oldest.jpg", "middle.jpg", "newest.jpg"]
        for (i, name) in fileNames.enumerated() {
            let url = tempDir.appendingPathComponent(name)
            try payload.write(to: url)
            let date = Date(timeIntervalSince1970: Double(i + 1) * 1000)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        // Budget smaller than the real 3KB total forces eviction; trim target keeps exactly
        // the newest file (1KB) once the two oldest (2KB) are removed. Passing explicit
        // budget/trimTarget (rather than the real 1GB/800MB production constants) is exactly
        // why performDiskCacheMaintenance takes them as overridable parameters.
        ThumbnailService.performDiskCacheMaintenance(in: tempDir, budgetBytes: 2048, trimTargetBytes: 1024)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(Set(remaining), ["newest.jpg"])
    }

    func testPerformDiskCacheMaintenanceToleratesAnEmptyOrMissingDirectory() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThumbnailServiceTests-missing-\(UUID().uuidString)", isDirectory: true)
        // Must not crash or throw when the directory doesn't exist at all.
        ThumbnailService.performDiskCacheMaintenance(in: missing, budgetBytes: 1, trimTargetBytes: 0)
    }
}
