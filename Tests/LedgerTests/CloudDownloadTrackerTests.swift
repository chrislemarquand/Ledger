@testable import Ledger
import Foundation
import XCTest

// v1.4 follow-up: `requestDownload` used to swallow a `startDownloadingUbiquitousItem` failure
// via `try?` while the optimistic `.downloading` state it had already published stayed in
// place forever — a permanent spinner with no retry possible (the pending-set guard
// suppressed it). Verifies the fix's immediately-testable half: a start failure against a
// plain local file (not tracked by any ubiquity container, so `startDownloadingUbiquitousItem`
// throws) correctly reverts to `.notDownloaded` and releases the guard.
//
// Injected provider/state/clock/sleep closures exercise timeout and same-URL restart
// ordering without iCloud infrastructure. Real provider behavior still belongs in §8.
@MainActor
final class CloudDownloadTrackerTests: XCTestCase {
    func testAcceptedDownloadTimesOutAndAllowsRetry() async {
        let url = URL(fileURLWithPath: "/test-placeholder.jpg")
        let clock = PollClock()
        let sleeper = PollSleeper()
        let reverted = expectation(description: "timeout reverted state")
        var states: [CloudFileState] = []
        let tracker = CloudDownloadTracker(
            pollTimeout: 120, startDownload: { _ in }, resolveState: { _ in .notDownloaded },
            now: { clock.date }, sleep: { await sleeper.wait() }
        )
        tracker.start(for: [url]) { update, _ in
            guard let state = update[url] else { return }
            states.append(state)
            if state == .notDownloaded { reverted.fulfill() }
        }
        defer { tracker.stop(); sleeper.releaseAll() }
        tracker.requestDownload(for: url)
        await sleeper.waitUntilSleeping(test: self)
        clock.date.addTimeInterval(121)
        sleeper.releaseAll()
        await fulfillment(of: [reverted], timeout: 2)
        tracker.requestDownload(for: url)
        XCTAssertEqual(states, [.downloading, .notDownloaded, .downloading])
    }

    func testStoppedPollCannotExpireReplacementForSameURL() async {
        let url = URL(fileURLWithPath: "/test-placeholder.jpg")
        let clock = PollClock()
        let sleeper = PollSleeper()
        let tracker = CloudDownloadTracker(
            pollTimeout: 120, startDownload: { _ in }, resolveState: { _ in .notDownloaded },
            now: { clock.date }, sleep: { await sleeper.wait() }
        )
        var states: [CloudFileState] = []
        tracker.start(for: [url]) { _, _ in }
        tracker.requestDownload(for: url)
        await sleeper.waitUntilSleeping(test: self)
        tracker.stop()
        clock.date.addTimeInterval(119)
        tracker.start(for: [url]) { update, _ in
            if let state = update[url] { states.append(state) }
        }
        tracker.requestDownload(for: url)
        await sleeper.waitUntilSleeping(test: self, count: 2)
        clock.date.addTimeInterval(2) // old deadline expired; replacement has 118 seconds left
        sleeper.releaseAll()
        await sleeper.waitUntilSleeping(test: self) // replacement completed a poll and sleeps again
        XCTAssertEqual(states, [.downloading])
        tracker.stop()
        sleeper.releaseAll()
    }

    func testRequestDownloadStartFailureRevertsToNotDownloadedAndReleasesGuard() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CloudDownloadTrackerTests-\(UUID().uuidString).jpg")
        try Data("x".utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let tracker = CloudDownloadTracker()
        defer { tracker.stop() }
        var updates: [[URL: CloudFileState]] = []
        tracker.start(for: [temp]) { states, _ in
            updates.append(states)
        }

        tracker.requestDownload(for: temp)

        // First update is the optimistic `.downloading`; a plain local file (not part of any
        // ubiquity container) makes `startDownloadingUbiquitousItem` throw synchronously, so
        // the revert to `.notDownloaded` should follow immediately in the same call — no
        // polling, no delay.
        XCTAssertEqual(updates.count, 2, "expected an optimistic .downloading update followed immediately by a revert on start failure")
        XCTAssertEqual(updates.first?[temp], .downloading)
        XCTAssertEqual(updates.last?[temp], .notDownloaded)

        // The pending-set guard must have been released — a second request should produce
        // another optimistic `.downloading` update, not be silently suppressed.
        tracker.requestDownload(for: temp)
        XCTAssertEqual(updates.count, 4, "a start failure should release the pending-download guard so a retry is possible")
        XCTAssertEqual(updates[2][temp], .downloading)
    }
}

@MainActor
private final class PollClock {
    var date = Date(timeIntervalSince1970: 0)
}

@MainActor
private final class PollSleeper {
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    func waitUntilSleeping(test: XCTestCase, count: Int = 1) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while waiters.count < count, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(waiters.count, count, "poll never reached sleep")
    }
}
