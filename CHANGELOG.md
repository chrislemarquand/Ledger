# Changelog

All notable changes to Ledger are documented here.

---

## [0.6.2] — build 59 — 2026-02-26

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
