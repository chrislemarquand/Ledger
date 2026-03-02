# ROADMAP

Current version: **0.8.1 (RC1a)**. Target: **v1.0**.

This file is the working roadmap. Full historical detail is archived in `ROADMAPOLD.MD`.

---

## 1) Still To Do Before v1.0

### Outstanding bugs
- [ ] **B22** `Should` Intermittent `Publishing changes from within view updates is not allowed` warning still appears in debug output; continue tracing remaining SwiftUI update-cycle mutation path(s).
- [ ] **B23** `Nice` Monitor `CMPhotoJFIFUtilities err=-17102` and `IOSurface creation failed: e00002c2` log spam during heavy decode bursts; escalate only if user-visible failures occur.
- [ ] **B24** `Must` Gallery zoom display regression: zoom level changes correctly (toolbar/menu items enable/disable at range limits) but `NSCollectionView` layout does not refresh until the user clicks a thumbnail. Regression from previous builds.
- [ ] **B25** `Must` Sidebar/browser mismatch after unpin: unpinning a Favourites item leaves the sidebar selection label (e.g. "Desktop") pointing at the wrong folder — browser content reflects the unpinned entry, not the labelled one.
- [ ] **B26** `Must` List view selection renders grey/inactive after switching from gallery. Selection is preserved but appears as an unfocused (non-active) highlight and cannot be manipulated without clicking again.
- [ ] **B27** `Should` Stale sidebar entries not pruned on relaunch: after a pinned folder is deleted from disk (Trash emptied), the entry still appears in Favourites/Recents after relaunch. Clicking it correctly shows "Folder Unavailable". Pruning logic is not removing entries whose paths no longer exist.
- [ ] **B28** `Should` Scroll-into-view on mode switch is one-directional: works gallery→list but not list→gallery.
- [ ] **B29** `Should` QuickLook panel height is not consistently locked: panel occasionally uses a different vertical size for a new image rather than maintaining the locked height and varying only width by aspect ratio. Intermittent and hard to reproduce.
- [ ] **B30** `Should` QuickLook re-centring after drag is inconsistent: pressing an arrow key after dragging the panel to a custom position should re-centre it (Finder behaviour), but this only happens sometimes.
- [ ] **B31** `Nice` View → Sort By menu order is inconsistent with toolbar sort menu and list column order. View menu: Name, Kind, Date Created, Size. Toolbar and columns: Name, Date Created, Size, Kind. View menu should be updated to match.
- [ ] **B32** `Should` Gallery thumbnail pending-edit dot (orange circle) does not appear on a tile after editing metadata — tile only refreshes when a different image is selected. List view shows the dot immediately. Likely the same gallery display-refresh failure as B24.
- [ ] **B33** `Must` `EXIF:DateTimeDigitized` is not writable via exiftool for at least some JPEG files: `exiftool failed with exit code 1: Warning: Sorry, EXIF:DateTimeDigitized doesn't exist or isn't writable`. Both staging a new value and clearing the field via the ✕ button fail. Needs investigation into ExifTool command construction / tag mapping for this field.
- [ ] **B34** `Should` Apply success subtitle shows generic "Metadata applied" instead of the count-based "Applied N images". Partial-failure path (B35) may have the same issue.
- [ ] **B35** `Must` Partial apply failure is silent: when one file in a batch fails (e.g. DateTimeDigitized not writable), no failure count is shown in the subtitle and no alert is presented. Other files in the selection apply successfully. The error is being swallowed rather than surfaced in the partial-failure tally.
- [ ] **B36** `Should` Undo in text fields operates character-by-character (one undo entry per keystroke) rather than field-level (one undo step returning to the value at the start of the edit session). Redo has the same granularity. Expected behaviour matches standard macOS text-editing undo coalescing.
- [ ] **B37** `Must` "Restore from Backup" remains enabled in the Image menu and context menu after a restore has already been performed. Should disable once no restorable backup exists for the selection.
- [ ] **B38** `Must` Inspector section expand/collapse still animates with Reduce Motion enabled. Regression — was fixed as P13 but is broken again.
- [ ] **B39** `Must` Sidebar section collapse/expand still animates with Reduce Motion enabled. Regression — was fixed as P4 but is broken again.
- [ ] **B40** `Nice` QuickLook panel open/close transition is not simplified with Reduce Motion enabled. May be framework-constrained (QuickLookUI controls its own animation); investigate before writing off.
- [ ] **B41** `Should` Preset names are not enforced as unique: the duplicate-name alert offers a "Keep Both" option, allowing multiple presets with identical names. The alert should prevent saving and prompt the user to choose a different name instead.
- [ ] **B42** `Nice` App writes through macOS advisory file locks (set via Finder/Preview lock) without reporting failure. exiftool bypasses the advisory lock flag (`uchg`) since it is not enforced at POSIX level. Fix should be an app-level pre-write check using `URLResourceKey.isLockedKey` before passing files to exiftool, surfacing a clear error rather than claiming success. Does not require changes to exiftool command construction.

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
