# Changelog

All notable changes to Ledger are documented here.

---

## [Unreleased]

### Changed
- Reverted the experimental thumbnail pipeline refactor series (`3ca1e25` through `888698b`) after runtime regressions (folder-open beachball and repeated gallery thumbnail redraw/glitching).
- No thumbnail-fix release is currently claimed; the bug is tracked as open in roadmap item **B20**.

---

## [0.6.6] — build 85 — 2026-03-01

### Added
- Roadmap polish item **P26** added to formalize command-scope rules: selection-only image actions, clear separation of folder-wide actions using macOS menu conventions, and context-menu actions constrained to the selected/right-click target files.
- Exported editable menu/action map to `output/menu_hierarchy_export.yaml` for planning command-scope and menu-layout refinements.
- Exported user-friendly spreadsheet version to `output/menu_hierarchy_editable.xlsx` with menu/context command structure, plain-English action descriptions, and editable request columns.

### Fixed
- **B19** Desktop/Downloads TCC prompt regression on app startup: replaced scattered guards with a centralized startup privacy-access policy. Launch/background paths now avoid filesystem validation for privacy-sensitive favorites/recents, and privacy-sensitive sidebar counts load only after explicit user selection of that exact item. Counts remain blank on app open.
## [0.6.5] — build 84 — 2026-03-01

### Changed
- **P17** Image menu metadata apply flow split into two actions: selection-scoped apply now shows a dynamic title (`"Apply Metadata Changes to N Image(s)"`) and folder-wide apply is exposed as `"Apply Metadata Changes to Folder"` (mirrors toolbar Apply behavior).
- **N11** Browser list context-menu construction now uses a local `makeItem` helper instead of repeated 4-line `NSMenuItem` setup blocks.
- Context-menu Apply label in both list and gallery now exactly matches the Image-menu selection action title format (`"Apply Metadata Changes to N Image(s)"`) and uses the same shared selection-count logic.

### Fixed
- Folder menu injection now anchors to both `"Refresh"` and legacy `"Refresh Files and Metadata"` labels, preventing missed insertion when the refresh copy differs.
- **P6** Favourites relaunch flows verified in test coverage: pin/unpin/reorder persistence across relaunch and stale-missing favourite pruning on load.
- **N9/N10** Preset editor cleanup: removed dead `editorPrimaryButtonTitle` property and simplified duplicate alert-message branches to a single message path.

---

## [0.6.4] — build 71 — 2026-02-26

### Changed
- **P18/P19** Window subtitle now shows contextual state at all times: `"Applying X of Y…"` during apply, `"Loading X of Y…"` during metadata load, transient status messages on action, `"X of N images"` when a subset is selected, `"N images"` at idle; preview-preload progress removed (silent background work). Partial-failure messages for apply and restore now use the concise format `"Applied X of N — Y failed"` / `"Restored X of N — Y failed"` instead of appending the raw error string.

### Fixed
- **B19** 🟡 Desktop and Downloads no longer trigger a TCC permission prompt on app startup (cannot reproduce — fix applied defensively; reopen if it resurfaces). Root cause: SwiftUI's `List(selection:)` auto-selects the first sidebar item during its initial render; when the app was launched via a Dock or Finder click, `NSApp.currentEvent` at that moment is the pre-launch mouse event, so `isLikelyUserInitiatedSidebarChange` returned true, the suppress-and-revert check was bypassed, and `selectSidebar` called `loadFiles(for: .desktop)`. Fix: `AppModel` records `ProcessInfo.processInfo.systemUptime` at init (`initializationUptime`); `shouldSuppressPrivacySensitiveAutoSelection` now rejects any event whose `timestamp` predates `initializationUptime` (a pre-launch event by definition), always suppressing TCC-gated auto-selections at startup while still allowing genuine user clicks after launch. The earlier `hasHadExplicitSidebarSelection` guard on `reloadFilesIfBrowserEmpty` is retained as a secondary defence.
- **B18** Zoom In (`⌘+`) and Zoom Out (`⌘−`) keyboard shortcuts had no effect until the user had opened the View menu at least once. Root cause: the menu items carrying the key equivalents were only injected in `menuWillOpen`; AppKit cannot match a shortcut to an item that doesn't yet exist in the menu bar. Fix: `injectSortMenuIfNeeded` now calls `rebuildViewMenu` immediately after finding the View menu, so the items — and their shortcuts — are registered from launch.

### Changed
- **N6** Open Folder toolbar button repositioned to match SF Symbols: moved before the sidebar toggle (index 0 in the sidebar zone, left of `NSTrackingSeparatorToolbarItem`), right-aligned within the sidebar column via a leading `flexibleSpace`; icon changed from `folder` to `folder.badge.plus`.
- **A1** Split `MainContentView.swift` (4,604 lines) into five focused files: `NavigationSidebarView.swift`, `BrowserListView.swift`, `BrowserGalleryView.swift`, `InspectorView.swift`, `PresetSheets.swift`. Residual `MainContentView.swift` is 1,494 lines. Pure reorganisation — no behaviour changes.

---

## [0.6.2] — build 71 — 2026-02-26

### Changed
- Copy-editing pass across all user-facing text in line with Apple HIG and Apple Style Guide; 101 strings updated across ExifEditMacApp.swift, AppModel.swift, and MainContentView.swift. Key changes:
  - Contractions throughout: "Could not" / "Failed to" → "Couldn't" (HIG friendly tone)
  - "file(s)" / "files" / "photos" → "images" (consistent with app's domain)
  - Status messages: "Pinned {x} to Pinned" → "{x} added to Pinned"; partial results now show "N of M images" fraction
  - Menu items: "Flip" → "Flip Horizontal"; "Refresh Files and Metadata" → "Refresh"; "Save Current as Preset…" → "Save as Preset…"; Pinned sidebar menu items simplified ("Pin to Sidebar", "Unpin from Sidebar", "Move Up in Sidebar", "Move Down in Sidebar"); "Restore from Last Backup" → "Restore from Backup"
  - Toolbar: Apply label shortened to "Apply Changes"; zoom tooltips drop "thumbnails"; inspector tooltip → "Show or hide the inspector"
  - Inspector: ALL CAPS section headers ("PREVIEW", "LAST OPERATION") → title case; "Shutter (Exposure Time)" → "Shutter Speed"; "Modified" / "Created" → "Date Modified" / "Date Created"; "Digitised" → "Digitized"; "GPS Latitude" / "GPS Longitude" → "Latitude" / "Longitude"; "Serial" → "Serial Number"
  - Picker values: Exposure Program options de-jargonised ("Aperture Priority", "Shutter Priority" etc.); Flash picker capitalised ("Red-Eye") and shortened; Metering Mode capitalised ("Center-Weighted", "Multi-Spot", "Multi-Segment")
  - Alerts: quit alert button → "Quit and Discard"; apply-folder alert reworded to state consequence; preset name-conflict "Duplicate" button → "Keep Both"; delete preset alert now shows preset name; "This cannot be undone" → "This action can't be undone"
  - Preset editor: "Add Preset" → "New Preset"; "Add…" → "New Preset…"; "Save Preset" / "Update Preset" → "Save"; "Close" → "Done"; placeholder text rewritten as prompts
  - About panel description rewritten verb-first; ExifTool capitalised correctly in error message
  - Empty states: "No Images" → "No Supported Images"; inspector empty state more descriptive

---

## [0.6.2] — build 70 — 2026-02-26

### Fixed
- Selecting a TCC-gated folder (Downloads, Desktop) no longer leaves the browser permanently empty after the user approves the permission prompt; `applicationDidBecomeActive` now calls `reloadFilesIfBrowserEmpty()` so the file enumeration is retried the moment the app regains focus (B17)
- "Folder Unavailable" error state is now actually shown when folder enumeration fails; previously `clearLoadedContentState` reset `browserEnumerationError` to nil immediately after the catch block set it, silently degrading all enumeration errors to the "No Images" empty state (B17)

---

## [0.6.2] — build 69 — 2026-02-26

### Changed
- Sidebar folder/location rows now use SwiftUI `.badge(Text?)` for image counts; custom `Spacer` + fixed-width `Text` label + `Color.clear` placeholder removed; nil count → no badge, consistent with Mail and Reminders (N3)

---

## [0.6.2] — build 68 — 2026-02-26

### Changed
- Pending-edit indicator dots replaced with SF Symbol `circle.fill` at all four sites: inspector field labels and inspector preview (SwiftUI `Image(systemName:).foregroundStyle(.orange)`), list cell and gallery cell (AppKit `NSImageView` with `NSImage(systemSymbolName:)` and `contentTintColor`); manual `wantsLayer`/`cornerRadius`/`backgroundColor` layer setup removed (N5)

---

## [0.6.2] — build 67 — 2026-02-26

### Changed
- Toolbar now has three pane-tracking zones: sidebar toggle above the sidebar, browser controls (Open Folder, View Mode, Sort, Zoom, Presets, Apply) above the browser, inspector toggle above the inspector; each zone tracks its pane divider on resize via a second `NSTrackingSeparatorToolbarItem` bound to the inner browser/inspector split (P25)

---

## [0.6.2] — build 66 — 2026-02-26

### Fixed
- Inspector no longer flashes stale (pre-apply) values after applying metadata; root cause was `pendingEditsByFile` being cleared before the exiftool re-read completed, leaving the inspector with only the old on-disk snapshot; fix adds `pendingCommitsByFile` to capture the written values, which the inspector uses as a fallback until the fresh disk snapshot arrives (B9)

---

## [0.6.2] — build 65 — 2026-02-26

### Fixed
- Inspector date/time field: when a date is set, the stepper picker now sits at its natural size left-aligned with the clear button pinned to the right edge; previously the picker's allocated frame ran to full width but the control only rendered at half of it, leaving a visible gap (P15)

---

## [0.6.2] — build 64 — 2026-02-26

### Fixed
- Switching from list → gallery (or vice versa) now scrolls to the selected item; list view uses `browserDidSwitchViewMode` notification → `scrollRowToVisible`; gallery view detects mode switch in `renderState()` via `lastRenderedViewMode`, then defers `layoutSubtreeIfNeeded()` + `scrollToVisible(attrs.frame)` one run loop after the opacity transition; synchronous scroll in `syncSelection` is suppressed during mode switches to avoid conflicting with the deferred path (P8)

---

## [0.6.2] — build 63 — 2026-02-26

### Fixed
- Sidebar section collapse/expand is now instant under Reduce Motion; `NavigationSidebarView` reads `@Environment(\.accessibilityReduceMotion)` and `toggleSection` uses `Transaction` with `disablesAnimations = true` when set, matching the pattern already used by inspector sections (P4, P13)

---

## [0.6.2] — build 62 — 2026-02-26

### Fixed
- Clicking the active list-view column header now reverses sort direction (ascending ↔ descending), matching Finder behaviour; nil values always sort last regardless of direction; `browserSortAscending` persists across launches (P7)

---

## [0.6.2] — build 61 — 2026-02-26

### Fixed
- Clicking a list-view column header now sorts by that column; `NSSortDescriptor` prototypes added to all four columns (Name, Date Created, Size, Kind); `tableView(_:sortDescriptorsDidChange:)` translates the header click to `model.browserSort`; column arrow indicator stays in sync when sort is changed via View → Sort By menu (P7)

### Removed
- Search bar removed from toolbar and ⌘F "Find…" removed from the Edit menu; name-only search is too limited for a metadata editor and the toolbar aesthetic was wrong; `searchQuery`/`filteredBrowserItems` backend infrastructure preserved for post-v1.0 metadata-aware search (R14)

### Fixed
- "Publishing changes from within view updates is not allowed" eliminated on every sidebar folder selection; root cause was `BrowserListViewController.update()` (called from SwiftUI's `updateNSViewController`) calling `model.setSelectionFromList()` synchronously when `shouldAdoptTableSelectionIntoModel()` returned true — this happened because NSTableView preserves selection by row index across `reloadData()`, so a prior row-0 selection survived into the new folder's data while `selectedFileURLs` had already been cleared; fixed by clearing the table selection before `reloadData()` when items change, and additionally deferring `setSelectionFromList` via `Task { @MainActor in }` in the adoption path for robustness (B14)

---

## [0.6.2] — build 58 — 2026-02-26

### Changed
- Gallery selection ring outset tuned to 5 pt (P9); overlay now anchored directly to the image view rather than the container so it is definitionally concentric; `selectionCornerRadius` constant removed — overlay corner radius derived as `thumbnailCornerRadius + selectionOutset` (single source of truth)

### Fixed
- Desktop and Downloads sidebar items no longer flicker and revert on click; the B14 `Task` deferral caused `NSApp.currentEvent` to be nil by the time `handleSidebarSelectionChange` ran, making user clicks appear as auto-selections and triggering the privacy-sensitive suppression logic; fixed by capturing the event synchronously in `.onChange` and passing it through the deferred call
- "Publishing changes from within view updates is not allowed" eliminated at startup; root cause was `.onChange(of: selectedSidebarID)` synchronously calling `handleSidebarSelectionChange` → `loadFiles` → `clearLoadedContentState`, which mutated `browserItems` and `filteredBrowserItems` inside the SwiftUI update cycle; deferred with `Task { @MainActor in … }` (B14)
- NSHostingView reentrant layout warnings eliminated; were a direct downstream consequence of B14 (B15)
- Inspector Picker invalid-tag `""` warnings eliminated; were a race symptom of B14 where `draftValues` could be mutated mid-render, making Picker selection inconsistent with its options (P24)
- QuickLook panel now opens centred on screen regardless of which thumbnail triggered it; navigating between images with arrow keys maintains a stable locked height (matching Finder's behaviour), with panel width varying per image aspect ratio; if the panel is already open and the user has dragged it, position is preserved (P10)
- About panel now shows correct version and build number; `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` removed from target-level build settings in project.pbxproj where they were silently overriding Base.xcconfig (B13)
- About panel credits now use `smallSystemFontSize` to match the panel's native credits area; was using `systemFontSize` which rendered too large (P20)
- Inspector toggle moved to immediately before the search field in the toolbar, so it sits adjacent to what it controls; Apply button now precedes it (P12)
- Sidebar context menu SF Symbol glyphs now render in label colour instead of accent colour; `.tint(Color.primary)` applied to context menu content, overriding the inherited accent tint (P1)
- "Folder" menu bar menu renamed to "Image" (P16)
- Sidebar folder-organisation items (Pin, Unpin, Move Up, Move Down) moved from Image menu into a new dedicated "Folder" menu to its right
- Sidebar panel shadow now renders correctly from the first frame; removed custom `applySidebarLayerRounding()` / `masksToBounds` layer code (was defeating the compositor's shadow path), and moved window configuration from `viewDidAppear` to `viewWillAppear` so the toolbar style is set before the window becomes visible (B12)
- View → As Gallery / As List now show a checkmark on the active mode and are always enabled; broken SwiftUI `.disabled()` replaced with AppKit `NSMenuDelegate` injection (B5)
- View → Sort By checkmark now survives SwiftUI menu rebuilds; injection moved to `menuWillOpen` via `NSMenuDelegate`
- Folder menu Apply Metadata Changes (⌘S), Clear Metadata Changes (⌘⇧K), and Restore from Last Backup (⌘⇧B) now enable/disable correctly based on whether the selection has pending edits or a restorable backup (B1, B2, B3)
- Context menu Apply, Clear, and Restore items now respect enabled state; `autoenablesItems = false` prevents AppKit from overriding manually set `isEnabled` values
- Tab Bar menu items (Show/Hide Tab Bar, New Tab) removed from View menu
- View → Zoom In / Zoom Out now disabled in list mode and at min/max zoom; broken SwiftUI `.disabled()` replaced with AppKit injection and `validateMenuItem` (B7)

---

## [0.6.1] — build 15 — 2026-02-26

### Fixed
- Inspector toolbar toggle label and tooltip now read "Show Inspector" or "Hide Inspector" based on current state (was always static "Hide Inspector")
- Sidebar and Inspector menu bar items now labelled "Toggle Sidebar" / "Toggle Inspector" (static labels are always correct regardless of panel state)
- View → Sort By checkmark now reflects the active sort on every menu open; SwiftUI Picker replaced with AppKit NSMenu validated via `NSMenuItemValidation`

---

## [0.6] — build 12 — 2026-02-26

### Added
- OSLog structured logging throughout AppModel
- `browserEnumerationError` — browser shows "Folder Unavailable" error state with lock icon when folder is inaccessible
- `stagedOpsDisplayToken` for gallery display-transform refresh without clearing the thumbnail cache
- `filteredBrowserItems` as cached `@Published private(set)` property, rebuilt on items/sort/search changes
- Inspector recalculation debounced 100 ms to reduce redundant work
- `BackupManager.pruneOperations(keepLast:)` — old backups pruned on app launch
- `ExifEditError.presetSchemaVersionTooNew` with user-visible NSAlert on schema mismatch
- Symlink loop protection in recursive directory enumeration
- Named `KeyCode` constants replacing raw key-code literals throughout
- NSAlert on launch when exiftool executable is missing from the app bundle

### Changed
- App brand name updated to Ledger throughout
- `enumerateImages` now `throws`; callers show error states rather than silently failing
- Complete apply/restore failures show NSAlert; partial failures shown in status bar
- Reduced-motion guards on all CATransition sites and list thumbnail swap
- All animation sites use `Motion.duration` (0.16 s) + `easeInEaseOut`; respects `accessibilityDisplayShouldReduceMotion`
- Inspector section headers converted to native `DisclosureGroup`
- Sort menu checkmarks use `Picker` inside `CommandMenu`
- `FullWidthPopupPicker` replaced with native `Picker(.menu)`
- `FullWidthDateTimePicker` replaced with native `DatePicker(.stepperField)`
- `InspectorPreviewActionButtonStyle` replaced with `.buttonStyle(.borderless)`

### Fixed
- BackupManager restore no longer falls back to root `/` on nil operationID lookup
- QuickLook crash in `moveLinearly(in:delta:)` when source items list is empty
- Preset schema mismatch now surfaces an alert rather than silently failing

---

## [0.5] — build 9 — 2026-02-24

- Unified thumbnail generation/request path across Gallery and List via shared broker and global cache.
- Simplified Quick Look transitions to native frame-driven behavior.
- Improved inspector metadata continuity during rotate/apply flows.
- Fixed gallery selection ring orientation/size mismatches and stabilized ring during rapid rotate/selection changes.
- Tuned gallery selector visuals: border thickness 3.5, configurable outward gap.
- Improved keyboard responder handoff when switching Gallery/List view modes.
- Added regression tests for rotate/apply metadata continuity and staged image-op normalisation.
- Consolidated UI metrics into shared tokens.

---

## [0.4] — build 7 — 2026-02-22

- Added Reveal in Finder to image/file context menus in Gallery and List views.
- Added Open in Finder to sidebar item context menus.
- Updated sidebar context menu entries with SF Symbols.
- Simplified sidebar context menu naming (Pin / Unpin).
- Matched sidebar context menu icon color to standard menu text color.

---

## [0.3] — build 5 — 2025-12

- Native gallery zoom animation.
- Rapid zoom stabilisation.

---

## [0.2] — build 3 — 2025-11

- UI and menu polish pass.
- Thumbnail and preview stabilisation.
- System accent colour restoration.

---

## [0.1] — build 2 — 2025-10

- Initial release: EXIF/IPTC/XMP metadata editor.
- 3-pane browser (sidebar, list/gallery, inspector).
- exiftool integration, preset system, backup and restore.
