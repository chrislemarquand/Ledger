# v1.0.0 Bug Backlog

## Severity rubric
- `S0`: data loss, crash, or corruption.
- `S1`: broken core workflow.
- `S2`: polish and usability issues.

## Open issues
- [ ] `S1` Verify context-menu parity and enabled states in list/gallery/menu bar across mixed selections.
- [ ] `S1` Verify favorites pin/unpin/reorder flows after relaunch and invalid path cleanup.
- [ ] `S1` Trace and eliminate intermittent `Publishing changes from within view updates is not allowed` warning (2026-03-01 log) from remaining SwiftUI surfaces. (Three inspector paths fixed 2026-03-02; verify no further occurrences on smoke path.)
- [ ] `S2` Monitor repeated `CMPhotoJFIFUtilities err=-17102` and `IOSurface creation failed: e00002c2` decode/surface-allocation log spam during heavy thumbnail loads; escalate only if tied to visible breakage.
- [ ] `S2` Validate reduced-motion behavior for inspector section expand/collapse and field focus scrolling.
- [ ] `S2` Full manual QA matrix execution and sign-off (open/apply/refresh/restore, presets, GPX import).

## Closed during this pass
- [x] `S1` Folder-switch UX regression: fixed. Two-part fix: (1) `BrowserView.body` restructured so `browserContent` is always the root view with overlays applied via `.overlay()`, eliminating the structural identity changes that destroyed/recreated AppKit VCs on every overlay transition; (2) `selectSidebar` sets `isFolderContentLoading = true` and defers `loadFiles` to the next task, giving SwiftUI a render pass to show the loading skeleton before the gallery's `reloadData()` flash is visible. Root cause of previous fix failures: `defer` cleared the flag before SwiftUI rendered (fix 1), and async minimum-delay kept the flag true but the structural identity change destroyed AppKit VCs causing a different flash (fix 2).
- [x] `S2` Gallery thumbnail corner-style regression: resolved. Thumbnail shape remains consistent from first paint through pending-edit dot appearance; no corner-style transition between unedited/edited states.
- [x] `S2` Inspector preview loading spinner alignment: resolved. Spinner is centered in the preview placeholder while loading.
- [x] `S1` Gallery zoom keyboard shortcuts with inspector focus: resolved. `⌘+` and `⌘−` now trigger zoom in gallery mode even when focus is inside inspector controls.
- [x] `S1` Remove actor isolation warning for split resize observer callback (`MainContentView.swift`).
- [x] `S1` `NSHostingView is being laid out reentrantly` fault from inspector: fixed. Three synchronous @Published/AppKit mutations during SwiftUI update phases: (1) `TextField` binding `set` calling `model.updateValue` synchronously — now deferred via `DispatchQueue.main.async`, consistent with all other inspector field types; (2) `.onChange(of: model.selectedFileURLs)` setting `focusedTagID = nil` synchronously — setting `@FocusState` during the update phase triggers an AppKit first-responder change that calls `layout()` on the `NSHostingView` mid-render, now deferred; (3) `InspectorLocationMapView.updateNSView` calling `addAnnotation`/`setRegion` synchronously — these propagate `setNeedsLayout` up to the `NSHostingView`, now deferred via `DispatchQueue.main.async { [weak view] in … }`.
