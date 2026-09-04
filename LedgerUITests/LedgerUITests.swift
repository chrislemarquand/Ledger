//
//  LedgerUITests.swift
//  LedgerUITests
//

import AppKit
import XCTest

final class LedgerUITests: XCTestCase {

    /// The instance this specific test launched, if any — `tearDown()` terminates only this,
    /// never anything discovered by scanning for other processes with the same bundle ID.
    ///
    /// **History, read before changing this file's process-lifecycle handling again.** Two
    /// prior versions of "clean up a stray Ledger process so `XCUIApplication.launch()` doesn't
    /// hang ~60s trying to terminate it" both caused real harm:
    /// 1. Force-terminating *any* running `com.chrislemarquand.Ledger` instance in `setUp`
    ///    crashed the user's live, paused Xcode debug session — indistinguishable from an
    ///    abandoned stray by PID or process state alone (confirmed via the resulting crash
    ///    report: "External Modification Warnings: Debugger attached to process").
    /// 2. The fix for that — skip any instance with the kernel's `P_TRACED` flag set — turned
    ///    out to be too broad in the other direction: `xcodebuild test` itself launches the
    ///    app under test with a debugger attached for every ordinary UI test run (that's what
    ///    `-NSDocumentRevisionsDebugMode YES` on the launched process signals), which is
    ///    *routine*, not evidence of the user's own interactive session. `P_TRACED` can't tell
    ///    the two apart, so it ended up protecting test-spawned processes from cleanup too —
    ///    reintroducing the original hang, just from ordinary test-to-test leakage instead of a
    ///    genuinely abandoned process.
    ///
    /// Neither version should have existed: sweeping by bundle ID and guessing which matches
    /// are safe to kill is the wrong shape of fix regardless of the heuristic. The actual fix is
    /// to never do that — each test owns exactly the one instance it launched and is
    /// responsible for terminating it itself, via `XCUIApplication.terminate()` (the API this
    /// is meant for), not `NSRunningApplication`/`kill` against a PID found by scanning.
    private var currentApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        currentApp?.terminate()
        currentApp = nil
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
        currentApp = app
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
