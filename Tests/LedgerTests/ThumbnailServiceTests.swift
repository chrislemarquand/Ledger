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

    // MARK: - Broker permit accounting (v1.4 follow-up)
    //
    // Direct against a fresh `Broker` instance (not the shared static one), which is why
    // `Broker`/`RequestKey` are `internal` rather than `private` — same testability
    // convention as the disk-cache functions above.

    /// Reproduces the waiter-overflow eviction bug: with `maxWaiters == 200` (a private
    /// constant on `Broker`), submitting more than `maxConcurrent + 200` requests used to
    /// resume the oldest overflowing waiter *without* granting it a permit, so its `work()`
    /// ran uncounted against `maxConcurrent`. 250 requests against a limit of 2 forces well
    /// past that threshold.
    func testBrokerNeverExceedsMaxConcurrentDuringWaiterOverflow() async {
        let broker = ThumbnailService.Broker(maxConcurrent: 2)
        let tracker = ConcurrencyTracker()
        let gate = TestGate()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<250 {
                let key = ThumbnailService.RequestKey(url: URL(fileURLWithPath: "/tmp/overflow-\(i).jpg"), side: 64)
                group.addTask {
                    _ = await broker.request(key: key, priority: .utility) {
                        await tracker.enter()
                        await gate.wait()
                        await tracker.exit()
                        return nil
                    }
                    await tracker.requestCompleted()
                }
            }
            // Two running + 200 queued + 48 denied proves the overflow path ran.
            let overflowReached = await waitUntil {
                guard await tracker.completedRequests >= 48 else { return false }
                return await broker.queuedRequestCount == 200
            }
            XCTAssertTrue(overflowReached, "requests never reached waiter overflow")
            await gate.open()
        }

        let peak = await tracker.peak
        XCTAssertLessThanOrEqual(peak, 2, "broker admitted more concurrent work than maxConcurrent during waiter overflow")
    }

    /// Reproduces the `cancelAll` premature-reset bug: `generate(fileURL:maxPixelSize:)`, the
    /// real work closure, has no internal cancellation checks, so a permit-holding task keeps
    /// running to physical completion regardless of `cancelAll`. A fresh request submitted
    /// right after `cancelAll` must therefore queue behind that still-executing old work —
    /// not be admitted immediately on top of it — and must still be admitted (no permanent
    /// leak/starvation) once the old work genuinely finishes.
    func testCancelAllQueuesFreshRequestsBehindStillRunningOldWorkThenAdmitsThemOnce() async {
        let broker = ThumbnailService.Broker(maxConcurrent: 2)
        let oldGate = TestGate() // deliberately not opened until after the assertion below
        let oldTracker = ConcurrencyTracker()

        var oldTasks: [Task<NSImage?, Never>] = []
        for i in 0..<2 {
            let key = ThumbnailService.RequestKey(url: URL(fileURLWithPath: "/tmp/old-\(i).jpg"), side: 64)
            oldTasks.append(Task {
                await broker.request(key: key, priority: .utility) {
                    await oldTracker.enter()
                    await oldGate.wait()
                    await oldTracker.exit()
                    return nil
                }
            })
        }
        let oldStarted = await waitUntil { await oldTracker.current == 2 }
        XCTAssertTrue(oldStarted, "old work did not acquire both permits")

        await broker.cancelAll()

        let freshTracker = ConcurrencyTracker()
        let freshKey = ThumbnailService.RequestKey(url: URL(fileURLWithPath: "/tmp/fresh.jpg"), side: 64)
        let freshTask = Task {
            await broker.request(key: freshKey, priority: .utility) {
                await freshTracker.enter()
                await freshTracker.exit()
                return nil
            }
        }

        // Give the fresh request every chance to (incorrectly) run while old work still
        // physically holds both permits.
        let freshSubmitted = await waitUntil {
            if await broker.queuedRequestCount == 1 { return true }
            return await freshTracker.totalRuns > 0
        }
        XCTAssertTrue(freshSubmitted, "fresh request never reached the broker")
        let ranWhileOldStillHeldPermits = await freshTracker.totalRuns
        XCTAssertEqual(
            ranWhileOldStillHeldPermits, 0,
            "a fresh request ran while cancelled-but-still-executing work still held every permit"
        )

        // Now let the old work actually finish — its permits become genuinely free, and the
        // fresh, still-queued request must then be admitted with no leak or permanent
        // starvation.
        await oldGate.open()
        for task in oldTasks { await finish(task) }
        await finish(freshTask)

        let ranAfterOldFinished = await freshTracker.totalRuns
        XCTAssertEqual(ranAfterOldFinished, 1, "fresh request was never admitted after old work's permits genuinely freed up")
    }

    /// Reproduces the `inflight[key] = nil` clobber bug precisely: an old request's cleanup
    /// used to unconditionally clear `inflight[key]` on completion, even if a *replacement*
    /// request for the same key was still genuinely in flight — breaking deduplication for a
    /// still-later, third request that arrives while the replacement is running. (A test that
    /// only checks "the replacement's own work ran once" doesn't actually distinguish this —
    /// the replacement's task runs regardless of whether its dictionary entry survives; only a
    /// third, deduplicating request can observe the erased entry.)
    func testStaleCleanupDoesNotBreakDeduplicationForAThirdRequestAgainstAReplacement() async {
        let broker = ThumbnailService.Broker(maxConcurrent: 2)
        let key = ThumbnailService.RequestKey(url: URL(fileURLWithPath: "/tmp/shared.jpg"), side: 64)
        let oldGate = TestGate()
        let replacementGate = TestGate()
        let replacementTracker = ConcurrencyTracker()
        let oldStarted = expectation(description: "old request holds a permit")
        let replacementStarted = expectation(description: "replacement registered")
        let duplicateRan = expectation(description: "duplicate must not execute")
        duplicateRan.isInverted = true

        // Old request: holds a permit, blocks until released.
        let oldTask = Task {
            await broker.request(key: key, priority: .utility) {
                oldStarted.fulfill()
                await oldGate.wait()
                return nil
            }
        }
        await fulfillment(of: [oldStarted], timeout: 2)

        // Clears inflight[key] (the old entry) without stopping the old task itself — it
        // keeps running to completion regardless (no internal cancellation checks, matching
        // the real decode path). Without this, "replacement" below would just dedupe against
        // the still-present old entry via request()'s fast path instead of registering a
        // genuinely new, separate task — which is what actually reproduces the original bug.
        await broker.cancelAll()

        // Replacement: registered for the SAME key after cancelAll cleared the old entry, so
        // this is a genuinely new registration, not a dedup against the old one.
        let replacementTask = Task {
            await broker.request(key: key, priority: .utility) {
                await replacementTracker.enter()
                replacementStarted.fulfill()
                await replacementGate.wait()
                await replacementTracker.exit()
                return nil
            }
        }
        await fulfillment(of: [replacementStarted], timeout: 2)

        // Let the OLD request finish — this is the moment its cleanup runs and, under the
        // original bug, would unconditionally erase inflight[key] even though the
        // replacement is still genuinely running.
        await oldGate.open()
        await finish(oldTask)

        // A THIRD request for the same key, submitted while the replacement is still
        // in-flight, must dedupe against it rather than starting its own separate execution.
        let thirdTask = Task {
            await broker.request(key: key, priority: .utility) {
                XCTFail("a third request should have deduplicated against the still-running replacement, not started its own work")
                duplicateRan.fulfill()
                return nil
            }
        }
        await fulfillment(of: [duplicateRan], timeout: 0.1)

        await replacementGate.open()
        await finish(replacementTask)
        await finish(thirdTask)

        let replacementRuns = await replacementTracker.totalRuns
        XCTAssertEqual(replacementRuns, 1, "the replacement's own work should have run exactly once")
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    private func finish(_ task: Task<NSImage?, Never>) async {
        let completed = expectation(description: "request completed")
        Task { _ = await task.value; completed.fulfill() }
        await fulfillment(of: [completed], timeout: 2)
    }
}

/// Test-only concurrency signal: work closures suspend on `wait()` until `open()` is called,
/// so a test can control exactly when queued/running work is allowed to complete.
private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Test-only counter: tracks how many `enter()`/`exit()`-bracketed work closures are
/// concurrently running at once (`peak`), and how many have run in total (`totalRuns`).
private actor ConcurrencyTracker {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var totalRuns = 0
    private(set) var completedRequests = 0

    func requestCompleted() { completedRequests += 1 }

    func enter() {
        current += 1
        peak = max(peak, current)
        totalRuns += 1
    }

    func exit() {
        current -= 1
    }
}
