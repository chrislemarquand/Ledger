# v1.0.0 Bug Backlog

## Severity rubric
- `S0`: data loss, crash, or corruption.
- `S1`: broken core workflow.
- `S2`: polish and usability issues.

## Open issues
- [ ] `S1` **B24** Gallery zoom display regression: zoom level changes (toolbar/menu correctly enable/disable at range limits) but `NSCollectionView` layout does not refresh until the user clicks a thumbnail. Regression from previous builds.
- [ ] `S1` **B25** Sidebar/browser mismatch after unpin: unpinning a Favourites item leaves the sidebar selection label pointing at the wrong folder; browser shows content of the now-unpinned folder, not the selected one.
- [ ] `S1` **B26** List view selection grey/inactive after gallery→list mode switch: selection is preserved but renders as unfocused highlight and cannot be manipulated without re-clicking.
- [ ] `S1` Verify context-menu parity and enabled states in list/gallery/menu bar across mixed selections.
- [ ] `S1` Trace and eliminate intermittent `Publishing changes from within view updates is not allowed` warning (2026-03-01 log) from remaining SwiftUI surfaces. (Three inspector paths fixed 2026-03-02; verify no further occurrences on smoke path.)
- [ ] `S2` **B27** Stale sidebar entries not pruned on relaunch: deleted-from-disk pinned folders (Trash emptied) still appear in Favourites/Recents after relaunch. Clicking shows "Folder Unavailable" correctly, but entry should be removed.
- [ ] `S2` **B28** Scroll-into-view on mode switch: works gallery→list only; list→gallery direction does not scroll selected item into view.
- [ ] `S2` **B29** QuickLook panel height inconsistency: panel occasionally uses a different vertical size rather than maintaining a locked height (intermittent, hard to reproduce).
- [ ] `S2` **B30** QuickLook re-centring after drag inconsistent: pressing arrow keys after dragging panel should re-centre it (Finder behaviour) but only does so sometimes.
- [ ] `S1` **B33** `EXIF:DateTimeDigitized` not writable: exiftool exits with code 1 (`"doesn't exist or isn't writable"`) on both write and clear for at least some JPEG files. Needs investigation into ExifTool command construction / tag mapping.
- [ ] `S2` **B31** View → Sort By menu order (Name, Kind, Date Created, Size) is inconsistent with toolbar sort menu and list column order (Name, Date Created, Size, Kind). View menu should match.
- [ ] `S2` **B32** Gallery thumbnail pending-edit dot does not refresh after editing metadata — tile only updates when a different image is selected. List view shows the dot immediately. Same display-refresh failure as B24.
- [ ] `S1` **B35** Partial apply failure is silent: when one file fails (e.g. DateTimeDigitized not writable), no failure count appears in the subtitle. Error swallowed rather than counted in partial-failure tally.
- [ ] `S2` **B34** Apply success subtitle shows "Metadata applied" instead of "Applied N images". Count-based message not being used.
- [ ] `S2` **B36** Undo/redo in text fields is character-by-character, not field-level. Expected: single undo step per edit session, matching standard macOS undo coalescing.
- [ ] `S1` **B37** "Restore from Backup" stays enabled after a restore — should disable once no backup remains for the selection.
- [ ] `S2` **B38** Inspector section expand/collapse still animates with Reduce Motion on. Regression of P13.
- [ ] `S2` **B39** Sidebar section collapse/expand still animates with Reduce Motion on. Regression of P4.
- [ ] `S2` **B40** QuickLook open/close not simplified with Reduce Motion on. Possibly framework-constrained.
- [ ] `S2` **B41** Preset names not enforced as unique — "Keep Both" allows duplicates. Should prevent saving and prompt for a different name.
- [ ] `S2` **B42** App writes through macOS advisory file locks silently. Fix: pre-write check via `URLResourceKey.isLockedKey` at app level (no exiftool changes needed).
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
