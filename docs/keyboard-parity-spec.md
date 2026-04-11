# Keyboard Parity Spec

Purpose: define exact keyboard behavior expected after SharedUI list/gallery migration, before any further refactors.

## Scope

- Ledger browser pane behavior (list + gallery), sidebar focus switching, and inspector field navigation.
- Focus gating rules for when shortcuts should and should not run.
- Shared behavior contract to later move into SharedUI for Librarian adoption.

## Focus Contexts

- `sidebar`: first responder is sidebar or descendant.
- `browser-list`: first responder is list/table view or descendant.
- `browser-gallery`: first responder is gallery/collection view or descendant.
- `inspector`: first responder is inspector or descendant.
- `editable-text`: first responder is editable `NSTextView` (takes priority over other contexts).

## Command Rules

1. `Tab` / `Shift+Tab` pane toggle
- Active when focus is in `sidebar` or `browser-*`.
- Inactive when `editable-text` is true.
- Toggles only between sidebar and browser pane.
- Does not trigger inspector field navigation.

2. Inspector field tab navigation
- Active only when focus is in `inspector`.
- `Tab` advances to next inspector field.
- `Shift+Tab` moves to previous inspector field.
- Does not trigger pane toggle while in inspector.

3. Return / Enter browser activation
- In `browser-list`: Return focuses inspector entry field (if selection exists).
- In `browser-gallery`: Return focuses inspector entry field (if selection exists).
- In `editable-text`: native text behavior only.

4. Escape clear selection
- Active in browser contexts (`browser-list`, `browser-gallery`).
- Clears current selection.
- In `editable-text`: native text behavior only.

5. Selection commands
- `⌘A`: select all filtered browser items (browser contexts only).
- `⌘D`: clear browser selection (browser contexts only).
- In `editable-text`: native text behavior only.

6. Arrow navigation
- Browser contexts only.
- No modifiers:
  - List: up/down move single selection.
  - Gallery: left/right/up/down move single selection based on grid.
- `Shift`:
  - List + gallery: extend contiguous range.
- `⌘Shift`:
  - Extend selection to boundary in movement direction.

7. Gallery zoom
- `⌘+` / `⌘-` active when browser view mode is gallery and zoom can change.
- Should work when key window is active and not blocked by modal/sheet.
- In other modes: ignored.

## AppKit-Native Preference

- Prefer responder-chain/menu-command handling where possible.
- Keep custom behavior only for:
  - pane-toggle policy
  - inspector field navigation policy
  - model-driven selection movement semantics
  - gallery shift-range parity if native behavior is insufficient

## Behavior Loss If Custom Selection/Keyboard Logic Is Stripped

- Sidebar/browser `Tab` pane toggle would be lost.
Current implementation: `MainContentView.installSpacebarQuickLookMonitorIfNeeded()` + `KeyboardShortcutSupport.shouldHandlePaneTabSwitch(...)` / `togglePaneFocus(...)`.

- Inspector-specific `Tab` / `Shift+Tab` field navigation policy would be lost.
Current implementation: `MainContentView` posts `.inspectorDidRequestFieldNavigation`; `InspectorView.moveInspectorFieldFocus(backward:)` applies ordered field focus.

- Browser `Return`/`Enter` -> inspector entry focus behavior would be lost or become inconsistent.
Current implementation: list path via `SharedBrowserListTableView` `onActivateSelection` -> `BrowserListView.focusInspectorFromBrowser()`;
gallery path via `SharedGalleryCollectionView.handlesActivateOnReturn` + `onActivateSelection` -> `BrowserGalleryView.focusInspectorFromBrowser()`;
global path currently also routed in `BrowserKeyboardRouter` consumed by `MainContentView`.

- Browser-wide `Esc`, `Cmd-A`, `Cmd-D` command policy would be lost.
Current implementation: `SharedUI/Utilities/BrowserKeyboardRouter.swift` + `MainContentView.handleBrowserKeyboardCommand(...)`.

- Cross-view arrow movement policy (including when list ignores left/right) would be lost.
Current implementation: `BrowserKeyboardRouter` routes movement; execution in `MainContentView` calls model movement APIs.

- `Cmd+Shift+Arrow` extend-to-boundary behavior would be lost.
Current implementation: `BrowserKeyboardRouter` -> `AppModel.extendSelectionToBoundary(towardStart:)`.

- App-model-driven contiguous range semantics for list/gallery keyboard extension would be lost.
Current implementation: `AppModel+Editing` (`moveSelectionInList`, `moveSelectionInGallery`, anchor/focus tracking).

- Window-level gallery zoom shortcuts (`Cmd+` / `Cmd-`) active from browser/inspector contexts would be lost.
Current implementation: `BrowserKeyboardRouter` + `MainContentView.handleBrowserKeyboardCommand(.zoomIn/.zoomOut)` with toolbar sync.

## Deferred Items (tracked separately)

- Restore deterministic Return/Tab parity after native selection changes.
- Reintroduce gallery `Shift` contiguous-range semantics distinct from `⌘` toggle.

## Acceptance Checklist

- [ ] Return parity: list + gallery focus inspector entry.
- [ ] Tab parity: pane toggle and inspector tab behavior are mutually exclusive by context.
- [ ] Browser command parity: Esc / Cmd-A / Cmd-D / arrow variants match expected behavior.
- [ ] Gallery zoom shortcuts parity.
- [ ] No shortcut handling while editable text responder is active.
- [ ] Behavior documented for SharedUI router extraction.
