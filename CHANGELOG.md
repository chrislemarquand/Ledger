# Changelog

All notable changes to Ledger are documented here.

---

## [0.6.1] — build 15 — 2026-02-26

### Fixed
- Inspector toolbar toggle label and tooltip now read "Show Inspector" or "Hide Inspector" based on current state (was always static "Hide Inspector")

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
