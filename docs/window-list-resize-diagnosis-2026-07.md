# Window / List-Column Resize Diagnosis — 2026-07-25

Root-cause diagnosis for reported bug: window size inconsistent, list columns don't fit available width, and resizing the window makes both worse. Diagnosis only — no code changed. Traced against `main` (Ledger) and `SharedUI`.

## The core anti-pattern (repeats at 3 layers)

The codebase restores **absolute pixel geometry** at three independent layers — window frame, outer split divider, table columns — each via its own AppKit-native autosave key, and only *one* of the three layers (the list's primary column) has logic to reconcile a restored absolute value against the *current* available width. None of the three layers know about each other, and one of them actively re-corrupts its own restored state on every layout pass.

---

## 1. Window size "not consistent"

`MainWindowController.init` (`Sources/Ledger/LedgerApp.swift:339-359`) uses a single, correctly-ordered mechanism: `WindowFramePersistenceController` (`SharedUI/Sources/SharedUI/Window/WindowFramePersistenceController.swift:9-34`) sets `minSize`, then `setFrameUsingName(autosaveName)`, then `setFrameAutosaveName(autosaveName)` — standard AppKit frame autosave, single owner. The controller also manually observes `didMoveNotification`/`didEndLiveResizeNotification` and calls `window.saveFrame(usingName:)` itself (`WindowFramePersistenceController.swift:56-68`) — redundant (AppKit's own autosave already does this) but writes the identical value to the identical key, so not a real conflict, just dead code.

The real inconsistency is **timing, not the frame code itself**: `NSWindow(contentViewController:)` (`LedgerApp.swift:346`) forces `NativeThreePaneSplitViewController`'s view to load and run an initial `viewDidLoad`/`viewDidLayout` pass at whatever transient content-fitting frame AppKit assigns *before* `WindowFramePersistenceController` (constructed several lines later, `LedgerApp.swift:352-358`) applies the restored frame. During that transient pass, `ThreePaneSplitViewController.applyInitialContentSplitIfNeeded()` (`ThreePaneSplitViewController.swift:268-290`) safely no-ops (guarded by a width threshold), but `SharedBrowserListViewController.applyInitialColumnFitIfNeeded()` (`SharedBrowserListViewController.swift:277-291`) only guards `viewportWidth > 0` (line 283) — so on a fresh install this one-shot fit can fire against a near-zero transient frame and permanently set `columnStore.hasAppliedInitialFit = true` (`SharedListColumnStore.swift:42-45`) using a garbage width. The app never gets a second chance to run the "good default fit" logic once the real window size is known.

## 2. Columns don't fill/fit available width

`SharedBrowserListViewController.configureList()` (`SharedUI/Sources/SharedUI/List/SharedBrowserListViewController.swift:121-184`):
- Sets `tableView.columnAutoresizingStyle = .noColumnAutoresizing` (line 137) — AppKit's built-in "resize columns to fill/track table width" is explicitly disabled. All width reconciliation must be done by hand.
- Sets `tableView.autosaveName` + `tableView.autosaveTableColumns = true` (lines 167-168) — hands column-width *persistence and restoration* to NSTableView's own native autosave, which stores **absolute pixel widths** per column keyed only by column identifier, with zero knowledge of table/window width at save time. `SharedListColumnStore.swift:6-7`'s own doc comment confirms this is deliberate: *"NSTableView autosave handles width/order. This store handles visibility and initial-fit sentinel keys."*

The fight: `fitTableToViewportIfNeeded()` (`SharedBrowserListViewController.swift:247-275`) directly mutates `primaryColumn.width` on every `viewDidLayout`/`viewDidAppear`/`reloadData()` call to make the primary column absorb the delta between viewport width and the summed width of the *other* columns. But every `.width` write on a column with `autosaveTableColumns = true` fires `NSTableViewColumnDidResizeNotification`, which NSTableView's own autosave listens to and re-persists — so **every transient, viewport-driven fit computation gets baked back into "the user's saved width."** On next launch, columns restore to whatever raw pixel widths happened to be true at the last quit's window size (`column.width = definition.defaultWidth` at line 157 is immediately overwritten by native autosave restore triggered by `autosaveTableColumns = true` at line 168). If the window is now a different size, `fitTableToViewportIfNeeded` squeezes the primary column to `primaryColumn.minWidth` and — when `minTotal > viewportWidth` (line 263) — **grows the table's own frame past the viewport** (`frame.size.width = ceil(minTotal)`, line 266), which is why `hasHorizontalScroller: true` was needed (`Sources/Ledger/BrowserListView.swift:128`): stale secondary-column widths simply don't fit, the table overflows, and a horizontal scrollbar appears. That scrollbar is the literal mechanism behind "columns don't fit."

`applyInitialColumnFitIfNeeded()` — the one genuinely size-aware fit — only runs once per install (gated by `hasAppliedInitialFit`), and per §1 can consume its one shot on a transient pre-restoration frame. After that, only `fitTableToViewportIfNeeded` (primary column only) provides ongoing reconciliation.

## 3. The resize interaction (makes it worse)

During a live window/divider drag, `viewDidLayout` fires repeatedly, and each firing writes `primaryColumn.width` — which, because `autosaveTableColumns = true`, triggers NSTableView's autosave to re-save column state to `UserDefaults` on every intermediate frame of the drag, not just at drag-end. There's no debounce, unlike `WindowFramePersistenceController` (saves only on `didEndLiveResizeNotification`) or `ThreePaneSplitViewController.schedulePaneStateSyncIfCollapseChanged()` (explicitly coalesces/defers past animation, `ThreePaneSplitViewController.swift:239-259`). The list-column layer is the only one of the three geometry layers without write-coalescing, and it's the one directly wired into a feedback loop with its own persistence.

Separately, the **outer** split (sidebar | content) uses NSSplitView's own native autosave (`splitView.autosaveName = mainAutosaveName`, `ThreePaneSplitViewController.swift:148`) — same absolute-pixel-restore-with-no-reconciliation class of bug, but for the sidebar/content divider, and there is *no* fit-to-viewport logic for it at all (only the *inner* content/inspector split has a one-time default-ratio nudge, not ongoing reconciliation). AppKit clamps the restored divider to `sidebarItem.minimumThickness` (220pt) but never proportionally rescales it to the new window width — compounding the "doesn't track window size" perception one layer up from the table.

## Causal chain summary

1. Three independent AppKit-native autosave systems (window frame, split dividers ×2, table columns) each restore absolute pixel values with no awareness of each other or of current available width.
2. Only the list view attempts reconciliation, and only for the primary column — secondary columns' stale widths are never rescaled, so any window-size change either leaves dead space or overflows into a horizontal scrollbar.
3. That reconciliation logic writes into the same `autosaveTableColumns` store it reads from at launch, so every transient viewport-driven width gets treated as durable user intent and re-restored next launch — a self-reinforcing loop with no debounce.
4. The one-shot "good initial fit" mechanism can fire against a transient, pre-restoration frame at window-construction time, burning its only invocation on a bogus width.

## Fix recommendations, in priority order

1. **Stop persisting column width via `NSTableView.autosaveTableColumns`.** Keep it (or `SharedListColumnStore`) for column *order* only. Let `fitTableToViewportIfNeeded` be the single source of truth for width on every layout, proportionally across **all** columns, not just the primary. This removes the read/write-into-same-store loop (`SharedBrowserListViewController.swift:167-168` vs `247-275`).
2. If per-column user-drag widths must persist, snapshot them **only** on `NSTableViewColumnDidResizeNotification` when the resize originated from an actual user drag (guard flag around `fitTableToViewportIfNeeded`'s programmatic writes) — mirrors the pattern already used correctly for pane-collapse state (`schedulePaneStateSyncIfCollapseChanged`, `ThreePaneSplitViewController.swift:246-259`).
3. Fix launch ordering: don't let the initial column fit fire against the transient pre-restoration frame. Either don't attach `NativeThreePaneSplitViewController` to the window until after the frame is restored, or gate the one-shot fit on a `windowDidBecomeVisible`-style callback instead of `viewDidLayout`.
4. Remove the redundant manual `saveFrame(usingName:)` calls in `WindowFramePersistenceController.swift:56-68` — harmless today, but confusing since `setFrameAutosaveName` already covers it.
5. Apply the same width-vs-viewport reconciliation to the **outer** `NSSplitView`'s sidebar divider, which currently has raw autosave with zero rescaling.

## Files referenced

- `Sources/Ledger/LedgerApp.swift:339-365`
- `SharedUI/Sources/SharedUI/Window/WindowFramePersistenceController.swift`
- `SharedUI/Sources/SharedUI/SplitView/ThreePaneSplitViewController.swift:144-297`
- `SharedUI/Sources/SharedUI/List/SharedBrowserListViewController.swift:80-291`
- `SharedUI/Sources/SharedUI/List/SharedListColumnStore.swift`
- `Sources/Ledger/BrowserListView.swift:114-130`
