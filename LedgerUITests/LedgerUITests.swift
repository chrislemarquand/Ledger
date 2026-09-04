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

    /// A stray `Ledger` process left over from a prior test run, a killed
    /// `xcodebuild test` invocation, or a stuck Xcode debug session blocks
    /// every subsequent `XCUIApplication.launch()` call: `launch()` first
    /// tries to terminate any already-running same-bundle-ID instance, and
    /// if that instance doesn't respond (observed: a debugger-suspended
    /// process in particular never will), the whole test hangs for ~60s and
    /// then fails with "Failed to terminate com.chrislemarquand.Ledger:<pid>"
    /// — attributed to whichever `launch()` call happens to hit it, not to
    /// the actual cause. Confirmed by reproducing directly: killing a real
    /// stray process by hand turned a 60s failure into a 6s pass with no
    /// other change. Force-terminating any pre-existing instance before each
    /// test removes the precondition entirely instead of chasing the
    /// resulting timeout.
    private func terminateAnyRunningLedgerInstance() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.chrislemarquand.Ledger")
        guard !running.isEmpty else { return }
        for instance in running {
            instance.forceTerminate()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let stillRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.chrislemarquand.Ledger")
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
