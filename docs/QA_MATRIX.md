# v1.0.0 QA Matrix

Covers all user-facing behaviour. Run on a clean build against a folder of real image files (mix of JPEG, HEIC, RAW). Mark items `[x]` as they pass; note failures inline marked with #.

---

## 1. Launch

- [x] App launches without an "exiftool not found" alert.
- [x] Window appears at a sensible default size.
- [x] No crash or console error on cold launch with no previously opened folder.

---

## 2. Folder opening

- [x] Open folder via toolbar button (Open Folder).
- [x] Open folder via File menu → Open Folder… (Cmd+O).
- [x] Browser populates with thumbnails.
- [x] Window title updates to folder name.
- [x] Loading state (shimmer / progress) shown while enumerating; clears when done.
- [x] Subtitle shows "N images" once loaded.
- [x] Open a second folder; browser replaces content cleanly.
- [x] Open a folder containing subdirectories; only image files appear (no folders listed).
- [x] Open an empty folder; browser shows empty state (no crash).
- [x] Open a non-existent path; browser shows "Folder Unavailable" error state. (Verified via deleted-folder path; "Folder Unavailable" shown correctly. Full programmatic path injection not testable without a debug build.)

---

## 3. Sidebar

- [x] Recents section lists recently opened folders.
- [x] Favourites section present (empty if no pins yet).
- [x] Locations section present.
- [x] Image count badge appears next to each item.
- [x] Click a sidebar item loads that folder in the browser.
- [x] Section collapse/expand works for all sections.
- [x] **Pin** a folder from the sidebar context menu; it appears in Favourites.
- [x] **Unpin** a favourite; it disappears from Favourites. (B25 fixed: selection now follows correctly; browser content matches sidebar label after pin/unpin.)
- [x] **Reorder** a favourite (Move Up / Move Down); order persists after relaunch.
- [x] Delete a pinned folder from disk; relaunch and verify the stale favourite is removed. (B27 fixed: `loadFiles` now detects NSFileNoSuchFileError after a failed enumeration and removes the stale entry immediately.)
- [x] Sidebar collapses fully via toolbar Toggle Sidebar button.
- [x] Sidebar re-expands; previously loaded folder is still shown.
- [x] Reduce Motion — section collapse/expand is instant (no animation). (B38/B39 closed: cannot reproduce — works correctly.)

---

## 4. Browser — list view

- [x] Switch to list view (Cmd+1 or View → As List); View menu shows checkmark on As List.
- [x] Columns visible: Name, Date, Size, Type (or equivalent).
- [x] Click a column header to sort; arrow indicator appears on that column.
- [x] Click the active column header again; sort direction reverses.
- [x] Sort selection matches the checkmark in View → Sort By. - #NEED TO MAKE SURE THE FOUR SORT LAYOUTS ARE IN A CONSISTENT ORDER THROUHGOUT THE UI OF THE APP
- [x] Changing sort via View menu updates the column header indicator.
- [x] Sort persists after switching gallery → list and back.
- [x] Pending-edit dot (orange circle) visible in the row for files with unsaved edits.
- [x] Thumbnail visible for each file; falls back to file icon if unavailable.

---

## 5. Browser — gallery view

- [x] Switch to gallery view (Cmd+2 or View → As Gallery); View menu shows checkmark on As Gallery.
- [x] Tiles show thumbnails at the current zoom level.
- [x] Zoom In (Cmd++) increases tile size. (B24 fixed: `model.$galleryGridLevel` added to `installRenderObservers()`; layout now refreshes immediately.)
- [x] Zoom Out (Cmd+-) decreases tile size. (B24 fixed: same.)
- [x] Zoom In disabled at maximum zoom level.
- [x] Zoom Out disabled at minimum zoom level.
- [X] Zoom In and Zoom Out menu items both disabled when in list view.
- [x] Toolbar Zoom In / Zoom Out items match menu item enabled states.
- [x] Pinch gesture on trackpad zooms tiles.
- [x] Pending-edit dot visible on tiles with unsaved edits.

---

## 6. Selection

- [x] Plain click selects a single file; inspector updates.
- [x] Plain click on a different file replaces selection.
- [x] Cmd+click on a second file adds it to selection.
- [x] Cmd+click on an already-selected file deselects it.
- [x] Shift+click selects a contiguous range.
- [x] Cmd+Shift+click extends selection additively.
- [x] Selection is preserved when switching list ↔ gallery view. (B26 fixed: `makeFirstResponder` now called after the list view is visible, so selection colour is active immediately.)
- [x] Selected file is scrolled into view after switching modes. (B28 fixed: `scrollView.layoutSubtreeIfNeeded()` now called instead of `collectionView.layoutSubtreeIfNeeded()`, so gallery→list scroll works.)
- [X] Selection count shown in subtitle: "X of N images" for partial selection, "N images" for all-or-none.
- [X] Cmd+A selects all files.
- [X] Click on empty area deselects all.

---

## 7. QuickLook

- [x] Spacebar opens QuickLook panel for the focused file.
- [x] Panel appears centred on screen.
- [x] Spacebar or Escape closes the panel.
- [x] Arrow keys navigate to adjacent files while panel is open.
- [x] Panel size is consistent across images of different aspect ratios (height locked, width derived). (B29 fixed: `lockedHeight` now always cleared in `present()`, not just when panel was hidden.)
- [x] Dragging the panel to a custom position and then pressing an arrow key: panel re-centres (matches Finder behaviour). (B30 fixed: `panelDidResize` height-lock + re-centre handler confirmed correct and necessary.)
- [X] QuickLook works for JPEG, HEIC, and RAW files.

---

## 8. Inspector — display

- [x] Inspector shows correct metadata fields for a single selected file.
- [x] Inspector shows a multi-selection summary (field count, mixed-value placeholders) for multiple files.
- [x] Inspector shows "No selection" state when nothing is selected.
- [x] Preview image shown for single selection.
- [x] Preview not shown for multi-selection.
- [x] Map shown in inspector when GPS data is present.
- [x] Inspector sections (e.g., EXIF, IPTC, XMP) are collapsible; state persists across selections.
- [x] Inspector collapses fully via toolbar Toggle Inspector button; label reads "Show Inspector".
- [x] Inspector re-expands; label reads "Hide Inspector".
- [x] Reduce Motion — inspector section expand/collapse is instant. (B38 closed: cannot reproduce — works correctly.)

---

## 9. Inspector — editing

- [x] Edit a text field; pending-edit dot appears on the file in the browser. (B32 fixed: `model.$inspectorRefreshRevision` added to `installRenderObservers()`; dot appears immediately.)
- [x] Edit a date/time field using the stepper picker. (B33 fixed: `EditableTag` key changed from `DateTimeDigitized` to `CreateDate` — the correct exiftool name for EXIF tag 0x9004.)
- [x] Edit a dropdown (Picker) field; value updates in inspector. (Picker fault fixed: `tag("")` now always present unconditionally as first item.)
- [x] Clear a date field using the ✕ button; field reverts to empty. (B33 fixed: same root cause as above.)
- [X] Press Escape in a text field; field reverts to the pre-edit value (no pending edit created).
- [x] Tab key moves focus to the next editable text field. (Native macOS behaviour: Tab cycles text fields only; dropdowns and date steppers are reached by click + arrow keys. Full Keyboard Access extends Tab to all controls system-wide.)
- [x] Multi-selection: edit a field; all selected files show the new value as pending. (B32 fixed: same fix as pending-dot above.)
- [X] Multi-selection with mixed existing values: placeholder shown before edit.
- [X] Preview Rotate button stages a rotation on the file.
- [X] Preview Flip button stages a horizontal flip.
- [X] Preview Open button opens the file in the default app.

---

## 10. Apply

- [x] Apply toolbar button is enabled only when at least one file has pending edits. (Fixed today: `$inspectorRefreshRevision` and `$stagedOpsDisplayToken` added to `installUIRefreshObservers()`.)
- [X] Apply menu item (Image → Apply Metadata Changes) is enabled only when selection has pending edits.
- [X] Apply writes changes to files; pending-edit dots disappear.
- [x] Subtitle shows "Applied N images" on full success. (B34 fixed: subtitle now uses `result.succeeded.count`.)
- [x] Partial failure: subtitle shows "Applied X of N — Y failed". (B35 fixed: stderr now scanned for exiftool "doesn't exist or isn't writable" warning even on exit 0; file counted as failed.)
- [x] Inspector refreshes immediately with the newly written values (no stale display). (B32 + B34 + B35 all fixed; no longer blocked.)
- [X] Thumbnails refresh to reflect any rotate/flip operations.
- [X] Apply with no pending edits does nothing (button disabled, no action).

---

## 11. Undo / redo

- [x] Cmd+Z undoes the last inspector field edit; field reverts. (B36 fixed: edit sessions now coalesce via `undoCoalescingTagID`; only the first keystroke in a field pushes an undo entry.)
- [x] Cmd+Shift+Z redoes the undone edit. (B36 fixed: same.)
- [X] Edit → Undo and Edit → Redo menu items are enabled/disabled correctly.
- [X] Undo after Apply does not revert the written file (undo is field-level only, not file-level; use Restore for file-level revert). #PASSES AND LOOKS LIKE IT WORKS AS EXPECTED WHICH IS UNDO/REDO PIPELINE IS CLEARED AFTER APPLY

---

## 12. Restore from backup

- [X] Image → Restore from Backup is enabled after at least one Apply has been performed on the selection.
- [X] Restore reverts files to the state before the last Apply.
- [X] Subtitle shows "Restored N images" on full success.
- [ ] Partial failure: subtitle shows "Restored X of N — Y failed". (Carry-forward manual QA item; hard to trigger reliably in ad-hoc testing.)
- [X] Inspector refreshes with the restored values.
- [X] Restore is disabled when no backup exists for the selection.

---

## 13. Presets

- [x] Open preset manager; list is empty on first launch.
- [x] Create a new preset; it appears in the list.
- [x] Edit a preset; changes are saved.
- [x] Duplicate a preset; copy appears with a distinct name.
- [x] Delete a preset; confirmation alert shown; preset removed on confirm.
- [x] Save a preset with a name that already exists; duplicate-name alert shown with Replace / Cancel only — duplicates not allowed. (B41 fixed: "Keep Both" removed; alert now only offers Replace or Cancel.)
- [X] Apply a preset to a selection; inspector shows the preset values as pending edits.
- [X] Presets persist across relaunch.

---

## 14. Context menus

- [X] Right-click a file in list view; context menu appears.
- [X] Right-click a file in gallery view; context menu appears.
- [X] Both context menus have the same items with the same labels.
- [x] Enabled states in context menus match the corresponding menu bar items for the same selection.
- [x] "Open in Default App" opens the file.
- [x] "Reveal in Finder" reveals the file.
- [x] "Apply Metadata Changes" in context menu correctly applies to the selected/right-clicked file(s) only. (Note: toolbar Apply applies folder-wide; context menu applies selection-only — they are intentionally different, not the same action.)
- [x] "Restore from Backup" in context menu behaves the same as the menu bar item. (B37 fixed: successfully-restored operation IDs now removed from `lastOperationIDs` so `hasRestorableBackup` returns false and the item disables.)

---

## 15. Toolbar

- [x] Open Folder button opens a folder picker.
- [x] Toggle Sidebar button collapses/expands the sidebar.
- [x] Toggle Inspector button collapses/expands the inspector.
- [x] View Mode control switches list ↔ gallery.
- [x] Sort control opens sort options; selecting one updates the browser.
- [x] Zoom In / Zoom Out buttons work in gallery mode. (B24 fixed.)
- [x] Zoom In / Zoom Out buttons are disabled in list mode.
- [x] Zoom In disabled at maximum zoom; Zoom Out disabled at minimum zoom.
- [x] Apply Changes button is enabled only when pending edits exist.
- [x] Preset Tools button opens the preset picker / manager.
- [x] Tracking separators: sidebar-zone buttons track with the sidebar edge on resize; inspector toggle tracks with the inspector edge.

---

## 16. Menus

- [x] View → As List (Cmd+1) — checkmark on As List; switches to list view.
- [x] View → As Gallery (Cmd+2) — checkmark on As Gallery; switches to gallery view.
- [x] View → Sort By — checkmark on the active sort field.
- [x] View → Zoom In — disabled in list mode and at max zoom.
- [x] View → Zoom Out — disabled in list mode and at min zoom.
- [x] Image → Apply Metadata Changes — enabled only with pending edits in selection.
- [x] Image → Restore from Backup — enabled only when selection has a restorable backup.
- [x] Image → Open in Default App — enabled only when files are selected.
- [x] Image → Reveal in Finder — enabled only when files are selected.
- [x] Help → About shows correct app name, version, and build number.

---

## 17. Window layout

- [x] Panes resize via drag; proportions feel correct.
- [x] Sidebar collapses fully; toolbar sidebar-zone items collapse with it.
- [x] Inspector collapses fully; inspector-zone toolbar item collapses with it.
- [x] Collapsing the sidebar does not affect inspector state, and vice versa.
- [x] Window can be resized to a small size without layout breakage.

---

## 18. Status / subtitle

| State | Expected subtitle |
|-------|------------------|
| Loading files | Loading… (or progress indicator) |
| Idle, all files shown, nothing selected | "N images" |
| Partial selection | "X of N images" |
| Applying | "Applying…" |
| Apply succeeded | "Applied N images" |
| Apply partial failure | "Applied X of N — Y failed" |
| Restore succeeded | "Restored N images" |
| Restore partial failure | "Restored X of N — Y failed" |

- [ ] Each row in the table above verified. (Carry-forward manual QA item; individual states verified during feature testing, but full systematic table pass not completed.)

---

## 19. Accessibility — Reduce Motion

Enable macOS Reduce Motion (System Settings → Accessibility → Display) for these checks:

- [x] Inspector section expand/collapse is instant (no slide animation). (B38 closed: cannot reproduce — works correctly.)
- [x] Sidebar section collapse/expand is instant. (B39 closed: cannot reproduce — works correctly.)
- [x] Gallery tile transitions are simplified or absent. (B24 fixed; zoom now works — can verify.)
- [x] Thumbnail swap in list/gallery does not crossfade — thumbnails snap in instantly with Reduce Motion enabled. ✓
- [x] QuickLook open/close transition is simplified. (B40 closed: framework-constrained — QLPreviewPanel owns its animation engine; Finder itself is unchanged with Reduce Motion on.)

---

## 20. Error states

- [X] Open a folder the app cannot read; "Folder Unavailable" shown with appropriate icon and message.
- [x] Apply to a read-only file; failure reflected in partial-failure count; other files in selection succeed. (B42 / R22 implemented in v1.0.1.)
- [x] Restore when the backup directory has been manually deleted; graceful error message, no crash. (Verified: shows "Backup for this operation was not found." — no crash.)
