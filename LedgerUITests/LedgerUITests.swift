//
//  LedgerUITests.swift
//  LedgerUITests
//

import AppKit
import XCTest

final class LedgerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        terminateAnyRunningLedgerInstance()
    }

    /// A stray `Ledger` process left over from a prior test run or a killed
    /// `xcodebuild test` invocation blocks every subsequent
    /// `XCUIApplication.launch()` call: `launch()` first tries to terminate
    /// any already-running same-bundle-ID instance, and if that instance
    /// doesn't respond, the whole test hangs for ~60s and then fails with
    /// "Failed to terminate com.chrislemarquand.Ledger:<pid>" — attributed to
    /// whichever `launch()` call happens to hit it, not the actual cause.
    ///
    /// **This must never terminate a process the user is actively debugging
    /// in Xcode.** An earlier version of this function terminated *any*
    /// running instance unconditionally, including the user's own live,
    /// paused Xcode debug session — indistinguishable from an abandoned
    /// stray by PID or process state alone (both can be reported as
    /// suspended/traced by `ps`). That version crashed a real debug session
    /// (confirmed via the resulting crash report: "External Modification
    /// Warnings: Debugger attached to process", terminated by SIGTRAP when
    /// this code's fallback killed the attached `debugserver`) and is not
    /// something to risk recurring. Fixed by checking the kernel's own
    /// `P_TRACED` flag (`sysctl(KERN_PROC_PID)`, the same signal a debugger
    /// itself sets) before touching a process — a debugger-attached instance
    /// is always skipped, never terminated, no exceptions.
    private func isBeingDebugged(pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }
        let pTraced: Int32 = 0x0000_0800 // P_TRACED, from <sys/proc.h>
        return (Int32(info.kp_proc.p_flag) & pTraced) != 0
    }

    private func terminateAnyRunningLedgerInstance() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.chrislemarquand.Ledger")
            .filter { !isBeingDebugged(pid: $0.processIdentifier) }
        guard !running.isEmpty else { return }
        for instance in running {
            instance.forceTerminate()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let stillRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.chrislemarquand.Ledger")
                .filter { !isBeingDebugged(pid: $0.processIdentifier) }
            if stillRunning.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// The bundled fixture JPEGs' own folder, used directly as the browsed
    /// folder — no copying. The UI test host (`LedgerUITests-Runner`) is
    /// sandboxed with read-only access to all of `/` and write access only
    /// inside its own container (verified via `codesign -d --entitlements`),
    /// so it can't create a shared writable temp folder the separately
    /// launched, unsandboxed Ledger process can also see. Reading the bundle
    /// resources in place sidesteps that entirely for read-only journeys
    /// (browsing, view-mode switching, sorting). A metadata apply/restore
    /// journey needs actual write access from both sides and is deliberately
    /// not attempted here — see docs/v1.4-progress.md.
    private func fixtureFolder() -> URL {
        Bundle(for: Self.self).resourceURL!
    }

    /// Launches Ledger with the fixture folder pre-opened via the
    /// `-openFolderPath` launch argument (LedgerApp.swift) so the test
    /// doesn't have to drive the NSOpenPanel. Runs against the real,
    /// developer-machine Ledger preferences — container isolation blocks the
    /// sandboxed test host from handing Ledger a writable isolated HOME the
    /// same way scripts/performance/run_benchmarks.sh does for its own
    /// direct-executable launches. These tests only touch UI presentation
    /// state (view mode, sort order), never file contents or metadata, so
    /// the acceptable side effect is: your last-used view mode/sort in
    /// Ledger may change after a run.
    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-openFolderPath", fixtureFolder().path, "-disableSparkleAutoupdate"]
        app.launch()
        return app
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["-disableSparkleAutoupdate"]
            app.launch()
        }
    }

    /// Candidate journey: configured-folder selection + first stable paint.
    @MainActor
    func testFolderOpensAndShowsBrowserContent() throws {
        let app = launchApp()
        let collectionView = app.scrollViews.children(matching: .collectionView).firstMatch
        XCTAssertTrue(collectionView.waitForExistence(timeout: 10), "Browser collection view never appeared")
    }

    /// Candidate journey: browser view-mode switching (Icon/List/Gallery).
    /// Segment labels verified against a real accessibility-hierarchy dump —
    /// the source's `labels: ["Icons", "List", "Gallery"]` array does NOT
    /// match what AppKit actually exposes ("Icon", singular).
    @MainActor
    func testBrowserViewModeSwitching() throws {
        let app = launchApp()
        let listButton = app.radioButtons["List"]
        let galleryButton = app.radioButtons["Gallery"]
        let iconButton = app.radioButtons["Icon"]

        XCTAssertTrue(listButton.waitForExistence(timeout: 10))
        XCTAssertTrue(galleryButton.exists)
        XCTAssertTrue(iconButton.exists)

        listButton.click()
        XCTAssertEqual(listButton.value as? Int, 1)

        galleryButton.click()
        XCTAssertEqual(galleryButton.value as? Int, 1)

        iconButton.click()
        XCTAssertEqual(iconButton.value as? Int, 1)
    }

    /// Candidate journey: sorting. The Sort toolbar item is disabled when the
    /// browser is empty (`sortItem?.isEnabled = ... && !model.browserItems.isEmpty`
    /// in MainContentView.swift), so this needs the fixture folder actually
    /// loaded — this is exactly the dependency that made "configured-folder
    /// selection" the plan's first candidate journey.
    @MainActor
    func testSortMenuSelectsOption() throws {
        let app = launchApp()
        let sortButton = app.menuButtons["Sort"]
        XCTAssertTrue(sortButton.waitForExistence(timeout: 10))
        // The Sort menu button only enables once the folder's items have
        // published; the collection view appearing is a reasonable proxy.
        _ = app.scrollViews.children(matching: .collectionView).firstMatch.waitForExistence(timeout: 10)
        XCTAssertTrue(sortButton.isEnabled, "Sort should be enabled once the fixture folder's items have loaded")

        sortButton.click()
        let dateCreatedItem = app.menuItems["Date Created"].firstMatch
        XCTAssertTrue(dateCreatedItem.waitForExistence(timeout: 5))
        dateCreatedItem.click()

        // Reproduce the action and confirm the app is still alive and
        // responsive afterward, per the plan's own scope for this journey —
        // UI automation's role here is timing/reproduction, not an exhaustive
        // state check. Re-opening the menu and reading back the checkmark
        // state was tried and is flaky (stale element matches across the
        // menu's open/close transition); not worth chasing for a smoke test.
        XCTAssertTrue(sortButton.waitForExistence(timeout: 5))
        XCTAssertTrue(sortButton.isEnabled)
    }

    // NOTE: a rapid-sidebar-switching test (Desktop/Downloads/Pictures) was
    // written and run here to investigate the historical "Publishing changes
    // from within view updates is not allowed" SwiftUI warning (ROADMAPOLD.MD
    // B22), then deliberately removed. Clicking those sidebar shortcuts
    // triggers macOS's TCC privacy dialog for each protected folder, and it
    // re-prompts on every run (the UI test runner gets a fresh ad-hoc
    // signature per build, which TCC treats as a new app each time) — a real,
    // unsuppressible automation blocker, not something fixable with a launch
    // argument. The investigation still ran successfully once (with the
    // dialogs manually dismissed) and its finding is recorded in
    // docs/v1.4-progress.md: the warning did not reproduce. Don't re-add a
    // sidebar-click test against these specific protected folders without a
    // real fix for the TCC re-prompt (e.g. pre-approving the built app's
    // stable identity in System Settings, if that ever proves durable across
    // rebuilds).
}
