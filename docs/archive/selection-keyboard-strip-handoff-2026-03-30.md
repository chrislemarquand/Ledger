# Ledger/SharedUI Handoff: Selection + Keyboard Strip-Back
Date: 2026-03-30

## Scope
This handoff covers the strip-back work requested to return browser selection/keyboard behavior to a more AppKit-native baseline, plus follow-up fixes attempted during the same session.

## Repos / Branches
- Ledger: `/Users/chrislemarquand/Xcode Projects/Ledger` on `codex/v1.2`
- SharedUI: `/Users/chrislemarquand/Xcode Projects/SharedUI` on `main`

## Baseline Rollback Tags (Phase 0)
Created before strip phases:
- Ledger tag: `strip-baseline-2026-03-30-ledger` -> `7d44126`
- SharedUI tag: `strip-baseline-2026-03-30-sharedui` -> `e3f85e2`

## User Goal
- Strip out custom keyboard/selection handling that fights native AppKit behavior.
- Keep SharedUI-first implementations where possible.
- Proceed in phases with commits after each phase.

## Work Completed

### Phase 1 (Ledger)
Removed main-window local key monitor and pane-tab interception in `MainContentView`.
- Commit: `d81ae11` `phase 1: strip main-window key monitor and pane tab interception`
- Cleanup: `f9eff58` `chore: revert unintended project version bump`

### Phase 2 (SharedUI + Ledger)
Removed split-view-level local keyboard monitor.
- SharedUI commit: `2db09df` `phase 2: remove split-view local keyboard monitor`
- Ledger commit: `7b50d2e` `phase 2: drop split-view keyboard monitor call site`
- Cleanup: `e40d89a` `chore: revert unintended project version bump`

### Phase 3 (SharedUI + Ledger)
Stripped custom gallery subclass keyboard/mouse overrides in SharedUI and removed Ledger wiring for removed hooks.
- SharedUI commit: `d37033e` `phase 3: strip custom gallery key and mouse overrides`
- Ledger commit: `24b0e24` `phase 3: remove gallery wiring for stripped custom keyboard hooks`
- Cleanup: `bd3f98b` `chore: revert unintended project version bump`

### Phase 4 (SharedUI + Ledger)
Stripped list return/newline custom activation handling and removed Ledger wiring.
- SharedUI commit: `6506f8a` `phase 4: remove list return/newline custom activation handling`
- Ledger commit: `7282a91` `phase 4: remove list activation wiring for stripped key overrides`
- Cleanup: `044ef2a` `chore: revert unintended project version bump`

### Phase 5 (Ledger)
Removed inspector field-navigation notification bridge.
- Ledger commit: `d00ba5d` `phase 5: remove inspector field-navigation notification bridge`
- Cleanup: `7b3d736` `chore: revert unintended project version bump`

### Phase 6 (SharedUI + Ledger)
Restored native focus-ring behavior (removed explicit `focusRingType = .none`).
- SharedUI commit: `24fdfbb` `phase 6: restore native focus ring in shared list view`
- Ledger commit: `9911303` `phase 6: restore native focus ring in gallery view`
- Cleanup: `ae7e944` `chore: revert unintended project version bump`

## Additional Follow-up Fix Attempt
Issue reported: toolbar zoom buttons stayed enabled in list view while menu items correctly disabled.

Attempted fix:
- Added explicit zoom-item enabled-state syncing in toolbar controller state refresh + validation.
- Ledger commit: `516fc8a` `fix toolbar zoom items disabled state in list mode`
- Cleanup: `5157978` `chore: revert unintended project version bump`

User reported this did **not** resolve the issue.

## Current State

### Ledger working tree
Only pre-existing docs edits are unstaged:
- `docs/Roadmap.md`
- `docs/keyboard-parity-spec.md`

### SharedUI working tree
- Clean.

### Build status at handoff
- `swift build` (SharedUI): pass
- `swift build` (Ledger): pass
- `xcodebuild -workspace SharedUI.xcworkspace -scheme Ledger -configuration Debug build`: pass

## Known Unresolved Issue
Toolbar zoom icons are still active in list mode (should be disabled/greyed out), while View-menu zoom items are already correctly disabled in list mode.

## Likely Culprit Areas to Debug Next
1. `MainToolbarController` item identity/state sync in `Ledger/Sources/Ledger/MainContentView.swift`
   - Confirm the on-screen zoom controls are the exact `zoomInItem`/`zoomOutItem` references being updated.
2. Toolbar validation lifecycle in `SharedUI/Sources/SharedUI/Toolbar/ToolbarShellController.swift`
   - Confirm `syncAndValidate` timing and whether visible items are being revalidated after mode switch.
3. `viewModeChanged(_:)` flow in `MainContentView`
   - Verify there is no second toolbar instance or stale delegate references after mode toggles.
4. Check for alternate zoom controls
   - Ensure no other toolbar item/group visually represents zoom buttons and bypasses the enabled-state update.

## Suggested Next Debug Steps (Concrete)
1. Add temporary logging for toolbar item identity and enabled-state transitions:
   - In `syncToolbarState()`, log item identifiers + object addresses + `isEnabled` values.
   - In `validateToolbarItem`, log same.
2. Add temporary logging in `viewModeChanged(_:)`:
   - Log browser mode, then force `window.toolbar?.validateVisibleItems()` after `syncAndValidate`.
3. Verify that `zoomInItem`/`zoomOutItem` are not nil post-install and remain stable after view-mode switches.
4. If mismatch found, update creation path to set `isEnabled` directly at item creation and on every `viewModeChanged` call.

## Process Notes / Pitfall
Repeated commits unintentionally included `Config/Base.xcconfig` (`CURRENT_PROJECT_VERSION` bump). This was cleaned each time with dedicated commits listed above.

Recommended guardrail for next developer:
- Before each commit: `git show --name-only --pretty=format: HEAD` and verify `Config/Base.xcconfig` is not included unless intentional.

## Minimal User-Preferred Run Flow (No CLI Build)
User preference is to:
1. Run reset script only:
   - `cd "/Users/chrislemarquand/Xcode Projects/Ledger"`
   - `./reset_ledger_layout.sh --yes`
2. Build/run from Xcode manually.

