# Settings Menu Handoff (Unresolved)

## Problem Summary
`App menu -> Settings…` does nothing, and `Cmd+,` also does nothing.

## Expected Behavior
Clicking `Settings…` or pressing `Cmd+,` should open the app's Settings window.

## Actual Behavior
No visible action. No settings window appears.

## Repro
1. Launch Ledger.
2. Open app menu.
3. Click `Settings…`.
4. Press `Cmd+,`.

Both are no-op.

## Implemented Settings Window (working code path exists)
The Settings window infrastructure is implemented and present:
- `SettingsWindowController` exists and creates/shows native AppKit Settings window.
- `AppDelegate.showSettingsWindowAction(_:)` creates and shows `SettingsWindowController`.

Current code references:
- `/Users/chrislemarquand/Documents/Photography/Apps/Ledger/Sources/Ledger/SettingsWindowController.swift`
- `/Users/chrislemarquand/Documents/Photography/Apps/Ledger/Sources/Ledger/LedgerApp.swift:80`

## Attempted Fixes (Chronological)
1. Added app-menu Settings item from `MainContentView` app-menu rebuild logic.
- Used `#selector(AppDelegate.showSettingsWindowAction(_:))`.
- Tried target as `NSApp.delegate`.
- Result: no-op.

2. Added/normalized app-menu top section in `MainContentView`.
- Forced menu shape: About, divider, Settings, divider, Services...
- Added SF Symbols (`info.circle`, `gear`).
- Result: no-op persisted.

3. Rewired Settings action through local controller forwarding method.
- Added `showSettingsFromAppMenuAction(_:)` on `NativeThreePaneSplitViewController`.
- Method forwarded to `(NSApp.delegate as? AppDelegate)?.showSettingsWindowAction(nil)`.
- Result: no-op persisted.

4. Reverted forwarding and switched to native-style selector name.
- Added `@objc(showSettingsWindow:) func showSettingsWindow(_:)` in `AppDelegate`.
- Pointed menu items to `#selector(AppDelegate.showSettingsWindow(_:))`.
- Tried `target = nil` responder-chain dispatch.
- Result: no-op persisted.

5. Removed app-menu ownership from `MainContentView` entirely.
- Deleted app-menu injection/rebuild paths from `MainContentView`.
- `MainContentView` now only manages File/Edit/View/Image/Help dynamic menus.
- Result: no-op persisted.

6. Moved app-menu ownership to `AppDelegate` only (current state).
- Added `configureApplicationMenu()` called in `applicationDidFinishLaunching`.
- Builds app menu explicitly:
  - About (`info.circle`)
  - divider
  - Settings (`gear`, `Cmd+,`)
  - divider
  - Services
  - divider
  - Hide / Hide Others / Show All
  - divider
  - Quit
- Wired Settings to `#selector(showSettingsWindowAction(_:))` with `target = self`.
- Result: still no-op reported by user.

Current code references:
- `/Users/chrislemarquand/Documents/Photography/Apps/Ledger/Sources/Ledger/LedgerApp.swift:93`
- `/Users/chrislemarquand/Documents/Photography/Apps/Ledger/Sources/Ledger/LedgerApp.swift:207`
- `/Users/chrislemarquand/Documents/Photography/Apps/Ledger/Sources/Ledger/MainContentView.swift:332`
- `/Users/chrislemarquand/Documents/Photography/Apps/Ledger/Sources/Ledger/MainContentView.swift:1142`

## Current Architecture Snapshot
- App menu: now built in `AppDelegate` at launch (`configureApplicationMenu()`).
- Non-app menus: dynamically injected/rebuilt in `MainContentView`.
- Settings window controller: lazily created in `AppDelegate` and retained by `settingsWindowController` property.

## What Was Ruled Out
- Compile errors: none.
- Selector presence: both `showSettingsWindowAction(_:)` and `showSettingsWindow(_:)` exist on `AppDelegate`.
- `SettingsWindowController` missing: not missing.
- Menu item missing: item is visible.

## High-Value Next Debug Steps
1. Add logging to verify dispatch entry.
- Log inside `showSettingsWindowAction(_:)` to confirm whether the action fires at all.

2. Log runtime menu item action/target at launch and before click.
- Confirm visible `Settings…` item has expected action and target.

3. Verify whether app menu is replaced later.
- Observe if another system/SwiftUI path rebuilds top-level app menu after `configureApplicationMenu()`.

4. Add a known-good trigger outside menu.
- Temporary toolbar/button command calling `showSettingsWindowAction(nil)` directly.
- If this works, problem is strictly menu command routing.

5. If action fires but window does not appear, instrument guard path.
- Check `appModel` at click time.
- Check `settingsWindowController?.window` lifecycle/state.

## Notes
- The work was intentionally moved away from ad hoc patching toward a single app-level native AppKit ownership model for the app menu.
- Despite this, user still reports Settings command no-op, so root cause likely requires runtime command-dispatch inspection rather than further static rewiring.
