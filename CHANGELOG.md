# Changelog

All notable changes to Ledger are documented here.

---

## [Unreleased]

---

## [1.0.2] — 2026-03-04

### Fixed
- **List metadata columns/inspector subtitle missing values**: in the folder-load pipeline, `browserItemHydrationID` was assigned before `clearLoadedContentState()`, which immediately reset it. That caused async browser-item hydration to be dropped, leaving `Date Created`, `Size`, and `Kind` as `—` in list view and size/type missing in inspector subtitle. Fix: assign `browserItemHydrationID` after clearing state and keep the prehydrate guard tied to the active folder load lifecycle.

### Changed
- Marketing version bumped from `1.0.1` to `1.0.2`.

---

## [1.0.1] — build 156 — 2026-03-04

### Fixed
- **Inspector map sustained CPU** (~10% at idle with a GPS-tagged image selected): `InspectorLocationMapView` used a live `MKMapView` (`InspectorPassthroughMapView` subclass) which unconditionally starts a VectorKit display link on init, running full tile-geometry decode and label layout at 60 fps indefinitely, even when the map is completely static. Diagnosed via Instruments Time Profiler — VectorKit was 25% of total trace weight. Fix: replaced the `NSViewRepresentable`-wrapped `MKMapView` with a `MKMapSnapshotter`-based SwiftUI view that renders a one-shot static image, composites a pin annotation using `lockFocusFlipped(true)`, and re-renders only when coordinates or frame size change. No display link; CPU settles to <1% at idle.
- **Folder-switch flash/reorder mismatch across sort modes** (`B43`): non-name sorts could visibly churn while sort-key metadata hydrated. Fix: prehydrate non-name attributes before publish, preserve existing browser content during switch, and keep loading overlay behavior consistent so transitions are atomic.
- **Advisory locked-file handling during apply** (`B42`/`R22`): apply now preflights both `FileAttributeKey.immutable` and `.isWritableKey`, skips locked/unwritable files, and reports targeted per-file failures.
- **Stale pending-commit values after metadata reload**: `pendingCommitsByFile` is now cleared on successful metadata reads (selection, folder, and background warm paths) so inspector values reflect disk state correctly after refresh.
- **Deferred-task cancellation after `Task.sleep`**: replaced `try? await Task.sleep` patterns with cancellation-aware `do/catch` exits across deferred metadata/preview flows.
- **Per-call formatter churn** in metadata/date normalization and compact decimal serialization: promoted repeated formatter allocations to static formatter instances.

### Changed
- Sidebar context menu polish: simplified labels (`Unpin`, `Move Up`, `Move Down`) and added `Remove` for recent and pinned folders.
- Browser loading overlay condition now only shows loading when there are no browser items available to render.
- Marketing version bumped from `1.0.0` to `1.0.1`.

---

## [1.0.0] — 2026-03-03

### Fixed
- **Apply Metadata toolbar button** did not activate immediately after a metadata edit; the button only updated when selection changed. Root cause: `installUIRefreshObservers()` was missing `model.$inspectorRefreshRevision` and `model.$stagedOpsDisplayToken`. Menu items are unaffected because they pull state on demand via `menuWillOpen`; toolbar items require explicit pushing. Both publishers now added to the observer list.
- **Sidebar empty-space click** caused content to shift up slightly as SwiftUI's `List(selection:)` briefly set the selection to nil before the model sync restored it. Fix: the `onChange` handler now intercepts nil and immediately re-asserts `model.selectedSidebarID`, matching standard macOS sidebar behaviour (Finder, Music) where clicking empty space never deselects.
- **Backup directory** was stored at `~/Library/Application Support/ExifEdit/Backups` (a legacy path) rather than `~/Library/Application Support/Ledger/Backups` alongside all other app data. Both the engine's `BackupManager` and the startup prune task now receive the correct `Ledger/Backups` base directory from `AppModel`.

### Changed
- About panel credits text is now centre-aligned.
- New app icon.
- Marketing version bumped to `1.0.0`.

---

## [0.8.2-rc.2] — 2026-03-03

### Fixed
- **B24** Gallery zoom (Cmd+/Cmd−) changed the zoom level but the `NSCollectionView` layout did not refresh until a thumbnail was clicked. Fix: `model.$galleryGridLevel` added to `installRenderObservers()`.
- **B25** Sidebar label showed the wrong folder name after pin/unpin. Two-part fix: `pinFavorite` no longer silently jumps selection to the newly-pinned item when something else is selected; `unpinSidebarItem` now always calls `selectSidebar` with a correctly-resolved landing target (adjacent favourite → restored Recent → nil).
- **B26** List view selection rendered as grey/inactive after a gallery→list mode switch, preventing keyboard interaction. Fix: `makeFirstResponder` deferred until `update()` (after the view is visible) by detecting `justBecameActive` via `lastRenderedViewMode`.
- **B27** Stale sidebar entries (for folders deleted or emptied to Trash) persisted after relaunch. Fix: `loadFiles` now detects `NSFileNoSuchFileError`/`NSFileReadNoSuchFileError` and immediately removes the stale favourite or recent entry.
- **B28** Scroll-into-view worked on list→gallery switches but not gallery→list. Fix: `scrollView.layoutSubtreeIfNeeded()` used instead of `collectionView.layoutSubtreeIfNeeded()` to drive top-down layout before querying item frames.
- **B29** QuickLook panel height not consistently locked across images. Fix: `lockedHeight` is now always cleared in `present()`, not only when the panel was hidden.
- **B30** QuickLook panel re-centring after drag was inconsistent. The `panelDidResize` height-lock + re-centre handler confirmed correct and necessary; without it AppKit anchors the bottom-left on resize.
- **B31** View → Sort By menu order (Name, Kind, Date Created, Size) did not match toolbar/columns order (Name, Date Created, Size, Kind). Fixed by reordering to Name, Date Created, Size, Kind with renumbered key equivalents ⌘⌃⌥1–4.
- **B32** Gallery thumbnail pending-edit dot did not appear after editing metadata until another image was selected. Fix: `model.$inspectorRefreshRevision` added to `installRenderObservers()`.
- **B33** `EXIF:DateTimeDigitized` was not writable — exiftool names the tag `CreateDate`, not `DateTimeDigitized`. Fixed the `EditableTag` key; both write and clear now work correctly.
- **B34** Apply success subtitle showed "Metadata applied" instead of "Applied N images". Fixed to use `result.succeeded.count`.
- **B35** Partial apply failures were silent when exiftool exited 0 but emitted a "doesn't exist or isn't writable" warning on stderr. Fix: stderr is now scanned for this warning on write operations and the file is counted as failed even on exit 0.
- **B36** Cmd+Z undid one character at a time in text fields instead of the entire field edit. Fix: `updateValue` now coalesces within an edit session via `undoCoalescingTagID`; only the first keystroke pushes an undo entry. `endUndoCoalescing()` is called on focus and selection change.
- **B37** "Restore from Backup" remained enabled after a successful restore. Fix: successfully-restored operation IDs are now removed from `lastOperationIDs`/`lastOperationFilesByID` so `hasRestorableBackup` returns false.
- **B38/B39** Inspector and sidebar section collapse/expand reduce-motion regressions: cannot reproduce — closed as not a bug.
- **B40** QuickLook open/close transition not simplified under Reduce Motion: closed as framework-constrained (QLPreviewPanel owns its animation engine; Finder is identical).
- **B41** Preset name uniqueness not enforced — "Keep Both" allowed duplicates. Fix: "Keep Both" / `saveAsDuplicate` removed; the duplicate-name alert now offers only Replace or Cancel.
- **Inspector picker fault** `Picker: the selection "" is invalid` on multi-selection: `tag("")` is now always the first unconditional item in all pickers, preventing SwiftUI validation failure before ViewBuilder content is fully evaluated.
- **Inspector preview / gallery thumbnail disappear on rotate undo/redo**: `applyPendingEditState` was calling `invalidateInspectorPreviews`, clearing the raw disk image cache even though no file had changed. Fix: removed the `invalidateInspectorPreviews` call; `stagedOpsDisplayToken` bumped instead so gallery cells reconfigure with the updated transform.

---

## [0.8.1-rc.1a] — build 145 — 2026-03-02

### Fixed
- **B22** `NSHostingView is being laid out reentrantly while rendering its SwiftUI content` fault eliminated on the inspector smoke path. Three sources of synchronous `@Published`/AppKit mutations during SwiftUI update phases: (1) `TextField` binding `set` called `model.updateValue` synchronously — deferred via `DispatchQueue.main.async`, making it consistent with `DatePicker` and `Picker` fields which already deferred; (2) `.onChange(of: model.selectedFileURLs)` set `@FocusState focusedTagID = nil` synchronously — setting `@FocusState` during the SwiftUI update phase triggers an AppKit first-responder change that calls `layout()` on the hosting view mid-render, now deferred; (3) `InspectorLocationMapView.updateNSView` called `addAnnotation`/`setRegion` synchronously — these propagate `setNeedsLayout` up to the `NSHostingView` during SwiftUI's `updateNSView` pass, now deferred via `DispatchQueue.main.async { [weak view] in … }`.

### Changed
- Apply/save SF Symbol convention formalised: `square.and.arrow.down` for selection-scoped apply (toolbar Apply Changes button, Image menu "Apply to Selection", context menus); `square.and.arrow.down.on.square` for folder-wide apply (Image menu "Apply to Folder"); `square.and.arrow.down.badge.checkmark` for Save as Preset (Image menu and presets toolbar dropdown, where it was previously unsymboled).
- Roadmap/backlog triage updated with two new tracked items from Xcode debug logs: **B22** (intermittent SwiftUI publish-during-view-update warning, actionable) and **B23** (CMPhoto/IOSurface log spam, non-blocking monitoring item).
- Marketing version bumped from `0.8` to `0.8.1`.

---

## [0.8.0-rc.1] — build 144 — 2026-03-02

### Fixed
- Edit menu **Undo/Redo** now route to the app's metadata/image staging undo stacks, restoring working undo/redo behavior from both keyboard shortcuts (`⌘Z`, `⇧⌘Z`) and the Edit menu for metadata edits and staged rotate/flip operations.
- Thumbnail request dedupe now separates foreground and background request lanes and applies explicit task priorities, reducing Thread Performance Checker priority-inversion warnings caused by user-initiated thumbnail requests awaiting lower-QoS inflight tasks.

### Changed
- Marketing version bumped from `0.7.3` to `0.8`.
- Declared this build as the first release candidate for the `0.8` line.

---

## [0.7.3] — build 141 — 2026-03-01

### Fixed
- Completed pre-v1.0 hybrid stabilization track **A4–A10**: explicit AppKit/SwiftUI ownership contract, one-way boundary flow, deferred boundary writes, user-selection path cleanup, targeted AppKit observation, deferred/coalesced pane-state publication, and warning-gate smoke-checklist freeze.
- Edit menu now applies SF Symbols to **Undo** (`arrow.uturn.backward`) and **Redo** (`arrow.uturn.forward`) for visual consistency with other menu commands.
- Edit-menu rebuild no longer accumulates trailing separator lines when the menu is opened repeatedly; separator normalization is now idempotent.

### Changed
- Image menu **Presets** item now uses the same symbol as the presets toolbar control (`slider.horizontal.3`) for consistent command identity across surfaces.
- File > Open With submenu now shows each app's native icon next to its menu item.
- Marketing version bumped from `0.7.2` to `0.7.3`.

---

## [0.7.2] — build 131 — 2026-03-01

### Fixed
- **Folder-switch UX regression** — brief "No Supported Images" empty-state flash on folder open resolved. Root cause was two compounding issues: (1) `BrowserView.body` used a `switch` that placed `browserContent` at different structural positions for `.none` vs `.loading`, causing SwiftUI to destroy and rebuild the AppKit gallery/list VCs on every overlay transition — this made previous fix attempts cause a different flash; (2) the loading skeleton was never shown during folder switches because `isFolderMetadataLoading` is only set after a 280 ms deferred prefetch, by which point `browserItems` is already populated (so the `isFolderMetadataLoading && browserItems.isEmpty` guard was never true). Fix: restructured `BrowserView` so `browserContent` is always the root with overlays applied via `.overlay()` (stable structural identity, no VC teardown); `selectSidebar` now sets `isFolderContentLoading = true` and defers `loadFiles` into a child Task so SwiftUI gets a render pass to show the skeleton before the gallery's `reloadData()` flash is visible; skeleton clears when the Task completes with the new items loaded.
- Gallery zoom shortcuts (`⌘+`, `⌘−`) now work while inspector controls have focus; key handling is now captured at the key-window level and gated to gallery mode with zoom-availability checks.
- Inspector preview loading spinner is centered in the preview frame while loading.
- Thumbnail presentation remains visually stable when the pending-edit status dot appears; no thumbnail-size jump and no corner-style transition between unedited/edited states.
- About panel menu action now correctly opens the native About panel from `Ledger > About`.
- Gallery/list mode-switch crash fixed by guarding gallery layout item size to a minimum positive value before assignment (`itemSize.width/height > 0`).

### Changed
- Marketing version bumped from `0.7.1` to `0.7.2`.
- Custom menu-bar command ownership consolidated under AppKit (`NSMenu`/`NSMenuItem`) for native validation and dynamic submenu behavior.
- Browser center pane now uses an AppKit container controller that owns list/gallery hosts and overlays directly.
- Reverted two folder-switch empty-state flicker attempts (`1094a1f`, `1b77bfd`) after no user-visible improvement; root cause of those failures now understood and addressed above.
- Reverted the experimental thumbnail pipeline refactor series (`3ca1e25` through `888698b`) after runtime regressions (folder-open beachball and repeated gallery thumbnail redraw/glitching).
- Gallery rewrite-track bug **B20** is now resolved in the current 0.7.x baseline.
- Thumbnail rewrite step **B20b** completed as architecture groundwork: thumbnail cache, inflight dedupe/concurrency control, and generation/fallback ordering were extracted into a single shared `ThumbnailService`; existing list/gallery call sites now delegate through that service without introducing new UX behavior claims.
- Thumbnail rewrite step **B20c** completed: thumbnail request/cancel ownership now lives in reusable AppKit views for both browser modes (`AppKitGalleryItem` in gallery and `BrowserListNameCellView`/`BrowserListIconView` in list), with `prepareForReuse` cancellation and per-cell request token checks to prevent stale async image writes after reuse.
- Thumbnail rewrite step **B20d** completed: gallery selection now uses a native tile-level highlight baseline (Finder-style) and no longer uses the custom image-hugging selection ring.
- Gallery selection highlight now uses a consistent inset rounded background (fixed padding/shape) for cleaner focus rendering without additional custom drawing.
- Gallery selection highlight now fills the square thumbnail grid area, so selection geometry is square and consistently contains the thumbnail.
- Square thumbnails now render with equal inner padding on all four sides within that square selection zone.
- Thumbnail rewrite step **B20e** completed: inspector preview loads (foreground, preload, and background warm) now use the same shared thumbnail request broker/service as list and gallery, unifying cache/dedupe behavior and priority handling.
- Post-B20 cleanup: removed dead gallery selection-ring metric constants and removed unused inspector preview preload progress counters (`previewPreloadCompleted` / `previewPreloadTotal`).
- Folder-switch thumbnail responsiveness improved: when content is cleared for a new folder, stale shared thumbnail requests are now canceled so the newly selected folder's thumbnails/previews take queue priority.
- Startup responsiveness pass for folder navigation: on folder open, first-screen thumbnails are warm-loaded immediately at modest size; metadata prefetch starts after a short delay; gallery initial request size reduced (from 2x tile side to 1.5x) to improve first-paint speed and reduce burst memory/CPU.

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
