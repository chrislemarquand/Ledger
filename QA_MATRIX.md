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
- [ ] Open a non-existent path; browser shows "Folder Unavailable" error state. #UNABLE TO TEST

---

## 3. Sidebar

- [x] Recents section lists recently opened folders.
- [x] Favourites section present (empty if no pins yet).
- [x] Locations section present.
- [x] Image count badge appears next to each item.
- [x] Click a sidebar item loads that folder in the browser.
- [x] Section collapse/expand works for all sections.
- [x] **Pin** a folder from the sidebar context menu; it appears in Favourites.
- [ ] **Unpin** a favourite; it disappears from Favourites. - #When pinning and unpinng a folder, the selection in the sidebar no longer matches up with the content of the browser. The selected folder name appears at the top (e..g Desktop) but the contents of the browser are not of that folder, they're of an now unpinned folder. This is a bug that needs fixing. '
- [ ] **Reorder** a favourite (Move Up / Move Down); order persists after relaunch.
- [ ] Delete a pinned folder from disk; relaunch and verify the stale favourite is removed.
- [ ] Sidebar collapses fully via toolbar Toggle Sidebar button.
- [ ] Sidebar re-expands; previously loaded folder is still shown.
- [ ] Reduce Motion — section collapse/expand is instant (no animation).

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
- [ ] Zoom In (Cmd++) increases tile size. - #FAILED, MARK AS BUG, REGRESSION FROM PREVIOUS BUILDS
- [ ] Zoom Out (Cmd+-) decreases tile size. - #FAILED, MARK AS BUG, REGRESSION FROM PREVIOUS BUILDS
- [ ] Zoom In disabled at maximum zoom level.
- [ ] Zoom Out disabled at minimum zoom level.
- [X] Zoom In and Zoom Out menu items both disabled when in list view.
- [x] Toolbar Zoom In / Zoom Out items match menu item enabled states.
- [ ] Pinch gesture on trackpad zooms tiles.
- [x] Pending-edit dot visible on tiles with unsaved edits.

---

## 6. Selection

- [x] Plain click selects a single file; inspector updates.
- [x] Plain click on a different file replaces selection.
- [x] Cmd+click on a second file adds it to selection.
- [x] Cmd+click on an already-selected file deselects it.
- [x] Shift+click selects a contiguous range.
- [ ] Cmd+Shift+click extends selection additively. - #NO NEEDS FURTHER TESTING BUT DOESN'T SEEM TO WORK'
- [ ] Selection is preserved when switching list ↔ gallery view. - #YES BUT LIST VIEW SHOWS SELECTION AS GREY AND NOT ACTIVE COLOUR SO CANNOT BE MANIPULATED
- [ ] Selected file is scrolled into view after switching modes. - #ONLY WHEN SWITCHING FROM LIST TO GALLERY, NOT FROM GALLERY TO LIST
- [X] Selection count shown in subtitle: "X of N images" for partial selection, "N images" for all-or-none.
- [X] Cmd+A selects all files.
- [X] Click on empty area deselects all.

---

## 7. QuickLook

- [ ] Spacebar opens QuickLook panel for the focused file.
- [ ] Panel appears centred on screen.
- [ ] Spacebar or Escape closes the panel.
- [ ] Arrow keys navigate to adjacent files while panel is open.
- [ ] Panel size is consistent across images of different aspect ratios (height locked, width derived).
- [ ] Dragging the panel to a custom position and then pressing an arrow key: panel re-centres (matches Finder behaviour).
- [ ] QuickLook works for JPEG, HEIC, and RAW files.

---

## 8. Inspector — display

- [ ] Inspector shows correct metadata fields for a single selected file.
- [ ] Inspector shows a multi-selection summary (field count, mixed-value placeholders) for multiple files.
- [ ] Inspector shows "No selection" state when nothing is selected.
- [ ] Preview image shown for single selection.
- [ ] Preview not shown for multi-selection.
- [ ] Map shown in inspector when GPS data is present.
- [ ] Inspector sections (e.g., EXIF, IPTC, XMP) are collapsible; state persists across selections.
- [ ] Inspector collapses fully via toolbar Toggle Inspector button; label reads "Show Inspector".
- [ ] Inspector re-expands; label reads "Hide Inspector".
- [ ] Reduce Motion — inspector section expand/collapse is instant.

---

## 9. Inspector — editing

- [ ] Edit a text field; pending-edit dot appears on the file in the browser.
- [ ] Edit a date/time field using the stepper picker.
- [ ] Edit a dropdown (Picker) field; value updates in inspector.
- [ ] Clear a date field using the ✕ button; field reverts to empty.
- [ ] Press Escape in a text field; field reverts to the pre-edit value (no pending edit created).
- [ ] Tab key moves focus to the next editable field.
- [ ] Multi-selection: edit a field; all selected files show the new value as pending.
- [ ] Multi-selection with mixed existing values: placeholder shown before edit.
- [ ] Preview Rotate button stages a rotation on the file.
- [ ] Preview Flip button stages a horizontal flip.
- [ ] Preview Open button opens the file in the default app.

---

## 10. Apply

- [ ] Apply toolbar button is enabled only when at least one file has pending edits.
- [ ] Apply menu item (Image → Apply Metadata Changes) is enabled only when selection has pending edits.
- [ ] Apply writes changes to files; pending-edit dots disappear.
- [ ] Subtitle shows "Applied N images" on full success.
- [ ] Partial failure: subtitle shows "Applied X of N — Y failed".
- [ ] Inspector refreshes immediately with the newly written values (no stale display).
- [ ] Thumbnails refresh to reflect any rotate/flip operations.
- [ ] Apply with no pending edits does nothing (button disabled, no action).

---

## 11. Undo / redo

- [ ] Cmd+Z undoes the last inspector field edit; field reverts.
- [ ] Cmd+Shift+Z redoes the undone edit.
- [ ] Edit → Undo and Edit → Redo menu items are enabled/disabled correctly.
- [ ] Undo after Apply does not revert the written file (undo is field-level only, not file-level; use Restore for file-level revert).

---

## 12. Restore from backup

- [ ] Image → Restore from Backup is enabled after at least one Apply has been performed on the selection.
- [ ] Restore reverts files to the state before the last Apply.
- [ ] Subtitle shows "Restored N images" on full success.
- [ ] Partial failure: subtitle shows "Restored X of N — Y failed".
- [ ] Inspector refreshes with the restored values.
- [ ] Restore is disabled when no backup exists for the selection.

---

## 13. Presets

- [ ] Open preset manager; list is empty on first launch.
- [ ] Create a new preset; it appears in the list.
- [ ] Edit a preset; changes are saved.
- [ ] Duplicate a preset; copy appears with a distinct name.
- [ ] Delete a preset; confirmation alert shown; preset removed on confirm.
- [ ] Save a preset with a name that already exists; duplicate-name alert shown.
- [ ] Apply a preset to a selection; inspector shows the preset values as pending edits.
- [ ] Presets persist across relaunch.

---

## 14. Context menus

- [ ] Right-click a file in list view; context menu appears.
- [ ] Right-click a file in gallery view; context menu appears.
- [ ] Both context menus have the same items with the same labels.
- [ ] Enabled states in context menus match the corresponding menu bar items for the same selection.
- [ ] "Open in Default App" opens the file.
- [ ] "Reveal in Finder" reveals the file.
- [ ] "Apply Metadata Changes" in context menu behaves the same as the toolbar button.
- [ ] "Restore from Backup" in context menu behaves the same as the menu bar item.

---

## 15. Toolbar

- [ ] Open Folder button opens a folder picker.
- [ ] Toggle Sidebar button collapses/expands the sidebar.
- [ ] Toggle Inspector button collapses/expands the inspector.
- [ ] View Mode control switches list ↔ gallery.
- [ ] Sort control opens sort options; selecting one updates the browser.
- [ ] Zoom In / Zoom Out buttons work in gallery mode.
- [ ] Zoom In / Zoom Out buttons are disabled in list mode.
- [ ] Zoom In disabled at maximum zoom; Zoom Out disabled at minimum zoom.
- [ ] Apply Changes button is enabled only when pending edits exist.
- [ ] Preset Tools button opens the preset picker / manager.
- [ ] Tracking separators: sidebar-zone buttons track with the sidebar edge on resize; inspector toggle tracks with the inspector edge.

---

## 16. Menus

- [ ] View → As List (Cmd+1) — checkmark on As List; switches to list view.
- [ ] View → As Gallery (Cmd+2) — checkmark on As Gallery; switches to gallery view.
- [ ] View → Sort By — checkmark on the active sort field.
- [ ] View → Zoom In — disabled in list mode and at max zoom.
- [ ] View → Zoom Out — disabled in list mode and at min zoom.
- [ ] Image → Apply Metadata Changes — enabled only with pending edits in selection.
- [ ] Image → Restore from Backup — enabled only when selection has a restorable backup.
- [ ] Image → Open in Default App — enabled only when files are selected.
- [ ] Image → Reveal in Finder — enabled only when files are selected.
- [ ] Help → About shows correct app name, version, and build number.

---

## 17. Window layout

- [ ] Panes resize via drag; proportions feel correct.
- [ ] Sidebar collapses fully; toolbar sidebar-zone items collapse with it.
- [ ] Inspector collapses fully; inspector-zone toolbar item collapses with it.
- [ ] Collapsing the sidebar does not affect inspector state, and vice versa.
- [ ] Window can be resized to a small size without layout breakage.

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

- [ ] Each row in the table above verified.

---

## 19. Accessibility — Reduce Motion

Enable macOS Reduce Motion (System Settings → Accessibility → Display) for these checks:

- [ ] Inspector section expand/collapse is instant (no slide animation).
- [ ] Sidebar section collapse/expand is instant.
- [ ] Gallery tile transitions are simplified or absent.
- [ ] Thumbnail swap in list/gallery does not crossfade.
- [ ] QuickLook open/close transition is simplified.

---

## 20. Error states

- [ ] Open a folder the app cannot read; "Folder Unavailable" shown with appropriate icon and message.
- [ ] Apply to a read-only file; failure reflected in partial-failure count; other files in selection succeed.
- [ ] Restore when the backup directory has been manually deleted; graceful error message, no crash.
