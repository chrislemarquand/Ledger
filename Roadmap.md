# ROADMAP

Current version: **0.8.2 (RC2)**. Target: **v1.0**.

This file is the working roadmap. Full historical detail is archived in `ROADMAPOLD.MD`.

---

## 1) Still To Do Before v1.0

### Outstanding bugs
- [x] **B22** `Should` Intermittent `Publishing changes from within view updates is not allowed` warning: cannot reproduce after AppKit/SwiftUI interaction rewrites; closed as fixed by those earlier changes.
- [x] **B23** `Nice` Monitor `CMPhotoJFIFUtilities err=-17102` and `IOSurface creation failed: e00002c2` log spam: not reproduced under heavy thumbnail load; no user-visible breakage. Closed as system-framework noise.
- [x] **B24** `Must` Gallery zoom display regression: zoom level changes correctly (toolbar/menu items enable/disable at range limits) but `NSCollectionView` layout does not refresh until the user clicks a thumbnail. Regression from previous builds.
- [x] **B25** `Must` Sidebar/browser mismatch after unpin: unpinning a Favourites item leaves the sidebar selection label (e.g. "Desktop") pointing at the wrong folder — browser content reflects the unpinned entry, not the labelled one.
- [x] **B26** `Must` List view selection renders grey/inactive after switching from gallery. Selection is preserved but appears as an unfocused (non-active) highlight and cannot be manipulated without clicking again.
- [x] **B27** `Should` Stale sidebar entries not pruned on relaunch: fixed. `loadFiles` now detects `NSFileNoSuchFileError`/`NSFileReadNoSuchFileError` on enumeration failure and auto-removes the stale favourite/recent entry and clears selection. Permission errors are left intact.
- [x] **B28** `Should` Scroll-into-view on mode switch is one-directional: fixed. `scrollSelectionIntoView` was calling `collectionView.layoutSubtreeIfNeeded()` but on a list→gallery switch the clip view bounds hadn't been updated yet, leaving item frames stale. Fix: call `scrollView.layoutSubtreeIfNeeded()` instead so the full scroll-view hierarchy is laid out before querying item attributes.
- [x] **B29** `Should` QuickLook panel height inconsistency: fixed. Root cause: `lockedHeight` was only cleared when `!panel.isVisible`, so re-opening while the panel was already visible carried over a stale height from the previous image set. Fix: `lockedHeight = nil` is now unconditional in `present()`, so every session captures a fresh height from its first image.
- [x] **B30** `Should` QuickLook re-centring after drag inconsistent: fixed alongside B29. Without the `panelDidResize` handler, QL anchors its bottom-left corner on resize, causing the panel to jump left/up when aspect ratio changes. The height-lock + re-centre handler is retained; with B29's stale-height bug removed it now fires consistently. Note: QL uses the current panel as a bounding box when sizing the next image — without correcting the frame after each resize, the panel progressively shrinks on every AR-changing navigation. The handler restores `lockedHeight` × current AR to keep the panel a stable size across the session.
- [x] **B31** `Nice` View → Sort By menu order is inconsistent with toolbar sort menu and list column order: fixed. Reordered View → Sort By to Name, Date Created, Size, Kind and renumbered key equivalents ⌘⌃⌥1–4 to match.
- [x] **B32** `Should` Gallery thumbnail pending-edit dot (orange circle) does not appear on a tile after editing metadata — tile only refreshes when a different image is selected. List view shows the dot immediately. Likely the same gallery display-refresh failure as B24.
- [x] **B33** `Must` `EXIF:DateTimeDigitized` not writable: fixed. ExifTool uses `CreateDate` (not `DateTimeDigitized`) as the writable tag name for EXIF 0x9004. Changed `EditableTag` key from `"DateTimeDigitized"` to `"CreateDate"` so the write command uses `-EXIF:CreateDate=...`.
- [x] **B34** `Should` Apply success subtitle shows generic "Metadata applied" instead of the count-based "Applied N images": fixed. Success path now uses `result.succeeded.count` to produce "Applied N image(s)".
- [x] **B35** `Must` Partial apply failure is silent: fixed. exiftool exits 0 on mixed-batch writes (good tags written, bad tag skipped), so `run` never threw. Fix: `ExifToolService.run` now scans stderr for "doesn't exist or isn't writable" on write operations and throws on exit 0 too.
- [x] **B36** `Should` Undo in text fields operates character-by-character: fixed. Added `undoCoalescingTagID` to AppModel. `updateValue` now only pushes a new undo entry on the first keystroke in a field; subsequent keystrokes in the same field are folded in. `endUndoCoalescing()` is called from InspectorView when `focusedTagID` changes (focus leaves a field) and on selection change, so the next edit in any field always gets its own distinct undo entry.
- [x] **B37** `Must` "Restore from Backup" remains enabled after restore: fixed. Removed successfully-restored operation IDs from `lastOperationIDs`/`lastOperationFilesByID` so `hasRestorableBackup` returns false and the menu item disables immediately.
- [x] **B38** `Must` Inspector section expand/collapse with Reduce Motion — cannot reproduce. Closed as not a bug.
- [x] **B39** `Must` Sidebar section collapse/expand with Reduce Motion — cannot reproduce. Closed as not a bug.
- [x] **B40** `Nice` QuickLook open/close transition not simplified with Reduce Motion: closed as framework-constrained. QLPreviewPanel controls its own animation engine; Finder itself shows no difference with Reduce Motion enabled.
- [x] **B41** `Should` Preset names are not enforced as unique: fixed. Removed "Keep Both" button and `saveAsDuplicate()`. The duplicate-name alert now offers only "Replace" and "Cancel" — users who want a different name dismiss and edit the name field.
- [ ] **B42** `Nice` App writes through macOS advisory file locks (set via Finder/Preview lock) without reporting failure. exiftool bypasses the advisory lock flag (`uchg`) since it is not enforced at POSIX level. Fix should be an app-level pre-write check using `URLResourceKey.isUserImmutableKey` before passing files to exiftool, surfacing a clear error rather than claiming success. Does not require changes to exiftool command construction.

### Pre-v1.0 release readiness notes
- **B4** is currently marked cannot-reproduce and remains closed unless it resurfaces.
- **B15** remains accepted as framework-constrained (QuickLook reentrant warning edge case with no visible user impact).

---

## 2) Already Completed Before v1.0

### Bugs (B)
- [x] **B1** Apply metadata menu state.
- [x] **B2** Clear metadata menu state.
- [x] **B3** Restore from backup menu state.
- [x] **B4** Restore-skip bug (cannot reproduce after B17).
- [x] **B5** View mode switching menu commands.
- [x] **B6** Sort-by checkmark state.
- [x] **B7** Zoom command enable/disable state.
- [x] **B8** Sidebar/inspector toggle menu labeling.
- [x] **B9** Stale inspector metadata after Apply.
- [x] **B10** Gallery selector color change on rotate.
- [x] **B11** Thumbnail flicker on rotate/flip.
- [x] **B12** Sidebar shadow rendering triage (system behavior).
- [x] **B13** About panel version/build mismatch.
- [x] **B14** `@Published` mutation during view update (major paths).
- [x] **B15** NSHostingView reentrant layout warning mostly mitigated; residual QuickLook path documented as acceptable for v1.
- [x] **B16** Missing `default.csv` message triaged as non-actionable framework noise.
- [x] **B17** TCC approval left browser empty.
- [x] **B19** No Desktop/Downloads TCC prompt on startup.
- [x] **B20** Gallery thumbnail glitch/reload blocker.
- [x] **B20a** Thumbnail rewrite step 1 baseline.
- [x] **B20b** Thumbnail rewrite step 2 shared thumbnail service.
- [x] **B20c** Thumbnail rewrite step 3 cell-owned lifecycle.
- [x] **B20d** Thumbnail rewrite step 4 native selection baseline.
- [x] **B20e** Thumbnail rewrite step 5 unified inspector preview pipeline.
- [x] **B21** Menu command ownership consolidated under AppKit.

### Polish (P)
- [x] **P1** Context-menu SF Symbol tint normalization.
- [x] **P2** Sidebar resize behavior triaged as intentional system behavior.
- [x] **P3** Sidebar toggle frame drops triaged as expected layout cost.
- [x] **P4** Sidebar section collapse honors Reduce Motion.
- [x] **P5** Recents section animation limitation documented.
- [x] **P6** Favorites relaunch/reconcile flows verified.
- [x] **P7** List column-header sorting implemented.
- [x] **P8** Selection scroll-into-view on list/gallery mode switch.
- [x] **P9** Gallery selection ring superseded by B20d baseline.
- [x] **P10** QuickLook positioning consistency.
- [x] **P11** Dynamic inspector toggle labeling.
- [x] **P12** Inspector toggle placement finalization.
- [x] **P13** Inspector section collapse honors Reduce Motion.
- [x] **P14** Inspector dropdown width limitation documented.
- [x] **P15** Date/time picker layout correction.
- [x] **P16** Folder menu renamed to Image menu.
- [x] **P17** Apply metadata split into selection vs folder actions.
- [x] **P18** Subtitle/status area priority and wording cleanup.
- [x] **P19** Apply/restore partial-failure count messaging.
- [x] **P20** Credits typography + version-source cleanup.
- [x] **P21** Desktop prompt behavior documented (sandbox-dependent).
- [x] **P22** Search bar removed from v1 UI (deferred feature).
- [x] **P23** Sidebar toggle right-alignment limitation documented.
- [x] **P24** Inspector picker invalid empty-tag race resolved.
- [x] **P25** Toolbar pane grouping with tracking separators.
- [x] **P26** Image-menu command scope and menu placement.
- [x] **P27** Final menu structure lock.

### Native UI rewrite cleanup (N)
- [x] **N1** Native `NSMenuToolbarItem` for Sort/Presets.
- [x] **N2** Loading placeholder retained intentionally (no native replacement change).
- [x] **N3** Sidebar count badge replaced with native `.badge(...)`.
- [x] **N4** Focus-ring cleanup superseded by AppKit list/gallery rewrite.
- [x] **N5** Pending-edit dot normalization across SwiftUI/AppKit surfaces.
- [x] **N6** Dynamic inspector toggle label wiring.
- [x] **N7** Inspector map view rewrite deferred to post-v1 AppKit inspector migration.
- [x] **N8** Inspector preview button-style cleanup deferred with inspector migration.
- [x] **N9** Dead preset-editor primary-button property removal.
- [x] **N10** Duplicate alert-message branch simplification.
- [x] **N11** Context-menu item boilerplate reduction helper.

### Architecture and stabilization (A)
- [x] **A1** Split `MainContentView.swift` into focused files.
- [x] **A2** Sidebar count badge preload latency removal.
- [x] **A3** Browser center pane moved to AppKit container.
- [x] **A4** Hybrid AppKit/SwiftUI ownership contract formalized.
- [x] **A5** One-way state flow at SwiftUI boundaries.
- [x] **A6** Deferred boundary writes to avoid update-cycle publishes.
- [x] **A7** Removed user-path auto-selection suppression.
- [x] **A8** Targeted observation in AppKit hosts.
- [x] **A9** No layout-time publish from AppKit callbacks.
- [x] **A10** Warning gate + smoke checklist freeze in architecture docs.

---

## 3) Future Roadmap

### Near-term / v1.0.1 track
- [ ] **R1** Full sidebar organizer (drag-drop group creation, import/export favorite sets).
- [ ] **R22** Respect macOS advisory file locks: pre-write check via `URLResourceKey.isUserImmutableKey` before passing files to exiftool; skip and report locked files clearly. Stretch: prompt to unlock-and-apply (Finder-style). (B42)
- [x] **R2** Branding consolidation complete (rolled up via R3-R7).
- [x] **R3** Identity/build settings alignment to Ledger.
- [x] **R4** Runtime labels/string audit for Ledger naming.
- [x] **R5** UserDefaults key-domain migration and sentinel.
- [x] **R6** App Support directory migration (`Logbook` -> `Ledger`).
- [x] **R7** Release/distribution artifact naming (`Ledger.dmg`).

### Feature roadmap
- [ ] **R8** GPX import + conflict-resolution UI.
- [ ] **R9** Restore last-used folder on relaunch.
- [ ] **R10** Large-folder performance pass (1000+ RAW files).
- [ ] **R11** App Store submission track.
- [ ] **R12** Drag-and-drop metadata export / batch rename.
- [ ] **R14** Metadata-aware search UI and query model.
- [ ] **R15** Configurable list columns (show/hide/reorder + EXIF columns).
- [ ] **R19** Optional gallery UX reintroduction pack.
- [ ] **R20** Toolbar customization/editing support.
- [ ] **R21** Long-term architecture principle: AppKit shell + SwiftUI islands.

### AppKit migration track (post-v1)
- [ ] **R13** Sidebar (`NavigationSidebarView`) -> AppKit `NSTableView`.
- [ ] **R16** Inspector (`InspectorView`) -> AppKit `NSViewController`.
- [ ] **R17** Preset manager sheet -> AppKit `NSTableView` panel.
- [ ] **R18** Preset editor sheet -> AppKit (optional, lower priority).
