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
- [ ] **Unpin** a favourite; it disappears from Favourites. - #NOT BHEAVING CORRECTLY - When pinning and unpinng a folder, the selection in the sidebar no longer matches up with the content of the browser. The selected folder name appears at the top (e..g Desktop) but the contents of the browser are not of that folder, they're of an now unpinned folder. This is a bug that needs fixing. '
- [x] **Reorder** a favourite (Move Up / Move Down); order persists after relaunch.
- [ ] Delete a pinned folder from disk; relaunch and verify the stale favourite is removed. - #FAILED - Name of deleted folder still appears (folder is in Bin), whether in pinned or recents. Clicking on it displays 'FOLDER UNAVAILABLE' message in main pane in orderly way.
- [x] Sidebar collapses fully via toolbar Toggle Sidebar button.
- [x] Sidebar re-expands; previously loaded folder is still shown.
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
- [ ] Zoom In (Cmd++) increases tile size. - #FAILED B24: zoom level changes (buttons/menu reflect state correctly) but gallery does not visually update until a thumbnail is clicked.
- [ ] Zoom Out (Cmd+-) decreases tile size. - #FAILED B24: same as above.
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
- [x] Cmd+Shift+click extends selection additively.
- [ ] Selection is preserved when switching list ↔ gallery view. - #YES BUT LIST VIEW SHOWS SELECTION AS GREY AND NOT ACTIVE COLOUR SO CANNOT BE MANIPULATED
- [ ] Selected file is scrolled into view after switching modes. - #ONLY WHEN SWITCHING FROM LIST TO GALLERY, NOT FROM GALLERY TO LIST
- [X] Selection count shown in subtitle: "X of N images" for partial selection, "N images" for all-or-none.
- [X] Cmd+A selects all files.
- [X] Click on empty area deselects all.

---

## 7. QuickLook

- [x] Spacebar opens QuickLook panel for the focused file.
- [x] Panel appears centred on screen.
- [x] Spacebar or Escape closes the panel.
- [x] Arrow keys navigate to adjacent files while panel is open.
- [ ] Panel size is consistent across images of different aspect ratios (height locked, width derived). - #HARD TO REPRODUCE BUT NOT ALWAYS - QUICKLOOK DOES NOT MAINTAIN A CONSTANT VERTICAL SIZE IN EVERY INSTANCE LIKE IT SHOULD
- [ ] Dragging the panel to a custom position and then pressing an arrow key: panel re-centres (matches Finder behaviour). - #FAILED - SOMETIMES WORKS BUT SOMETIMES DOESN'T, APPEARS TO BE INCONSISTENT BEHAVIOUR'
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
- [ ] Reduce Motion — inspector section expand/collapse is instant.

---

## 9. Inspector — editing

- [ ] Edit a text field; pending-edit dot appears on the file in the browser. - #FAILED, DOES NOT DISPLAY IN THE GALLERY THUMBNAIL UNTIL ANOTHER IMAGE IS SELECTED
- [ ] Edit a date/time field using the stepper picker. - #DATE DIGITZED FAILED WITH MESSAGE Could not write metadata to 1 file(s): 031.jpg exiftool failed with exit code 1: Warning: Sorry, EXIF:DateTimeDigitized doesn't exist or isn't writable
Nothing to do.
- [ ] Edit a dropdown (Picker) field; value updates in inspector.
- [ ] Clear a date field using the ✕ button; field reverts to empty. #FAILED FOR DATE DIGITZED 
- [X] Press Escape in a text field; field reverts to the pre-edit value (no pending edit created).
- [x] Tab key moves focus to the next editable text field. (Native macOS behaviour: Tab cycles text fields only; dropdowns and date steppers are reached by click + arrow keys. Full Keyboard Access extends Tab to all controls system-wide.)
- [ ] Multi-selection: edit a field; all selected files show the new value as pending.#FAILED FOR SAME REASON AS ROW 122 ABOVE BUT SHOULD BE FINE ONCE THAT IS FIXED
- [X] Multi-selection with mixed existing values: placeholder shown before edit.
- [X] Preview Rotate button stages a rotation on the file.
- [X] Preview Flip button stages a horizontal flip.
- [X] Preview Open button opens the file in the default app.

---

## 10. Apply

- [x] Apply toolbar button is enabled only when at least one file has pending edits. - #YES BUT SLIGHT DELAY BETWEEN EDIT BEING MADE AND TOOLBAR BUTTON BEING ACTIVATED, COULD BE RELATED TO LINE 122 ABOVE
- [X] Apply menu item (Image → Apply Metadata Changes) is enabled only when selection has pending edits.
- [X] Apply writes changes to files; pending-edit dots disappear.
- [ ] Subtitle shows "Applied N images" on full success. #MESSAGE JUST SAYS METADATA APPLIED, NOT CLEAR IF THIS IS EXPECTED BEHAVIOUR
- [ ] Partial failure: subtitle shows "Applied X of N — Y failed". #FAILED - TRIED APPLYING KNOWN BAD FIELD DATE DIGITIZED AND DID NOT GET FAILED MESSAGE FOR THE ONE OF NINE IMAGES I'D CHANGED THAT FIELD IN, OTHER CHANGES APPLIED FINE'
- [ ] Inspector refreshes immediately with the newly written values (no stale display).#DUE TO BUG IN LINE 122 I HAVE TO CLICK OFF INSPECTOR TO ACTIVATE THE APPLY BUTTON SO NOT ABLE TO TEST THIS
- [X] Thumbnails refresh to reflect any rotate/flip operations.
- [X] Apply with no pending edits does nothing (button disabled, no action).

---

## 11. Undo / redo

- [ ] Cmd+Z undoes the last inspector field edit; field reverts. #PARTIAL PASS - UNDOES ONE TYPED CHARACTER AT A TIME WHICH IS NOT EXPECTED BEHAVIOUR
- [ ] Cmd+Shift+Z redoes the undone edit.#PARTIAL PASS AS LINE 152
- [X] Edit → Undo and Edit → Redo menu items are enabled/disabled correctly.
- [X] Undo after Apply does not revert the written file (undo is field-level only, not file-level; use Restore for file-level revert). #PASSES AND LOOKS LIKE IT WORKS AS EXPECTED WHICH IS UNDO/REDO PIPELINE IS CLEARED AFTER APPLY

---

## 12. Restore from backup

- [X] Image → Restore from Backup is enabled after at least one Apply has been performed on the selection.
- [X] Restore reverts files to the state before the last Apply.
- [X] Subtitle shows "Restored N images" on full success.
- [ ] Partial failure: subtitle shows "Restored X of N — Y failed".
- [X] Inspector refreshes with the restored values.
- [X] Restore is disabled when no backup exists for the selection.

---

## 13. Presets

- [x] Open preset manager; list is empty on first launch.
- [x] Create a new preset; it appears in the list.
- [x] Edit a preset; changes are saved.
- [x] Duplicate a preset; copy appears with a distinct name.
- [x] Delete a preset; confirmation alert shown; preset removed on confirm.
- [ ] Save a preset with a name that already exists; duplicate-name alert shown. #PASSES BUT BEHAVIOUR SHOULD BE NOT TO ALLOW MULTIPLE PRESETS WITH THE SAME NAME
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
- [ ] "Restore from Backup" in context menu behaves the same as the menu bar item. #OPTION PERSISTS IN MENU AND CONTEXT MENU AFTER BACKUP HAS BEEN RESTORED

---

## 15. Toolbar

- [x] Open Folder button opens a folder picker.
- [x] Toggle Sidebar button collapses/expands the sidebar.
- [x] Toggle Inspector button collapses/expands the inspector.
- [x] View Mode control switches list ↔ gallery.
- [x] Sort control opens sort options; selecting one updates the browser.
- [ ] Zoom In / Zoom Out buttons work in gallery mode.
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

- [ ] Each row in the table above verified.

---

## 19. Accessibility — Reduce Motion

Enable macOS Reduce Motion (System Settings → Accessibility → Display) for these checks:

- [ ] Inspector section expand/collapse is instant (no slide animation). #FAILED STILL ANIMATES
- [ ] Sidebar section collapse/expand is instant. #FAILED STILL ANIMATES
- [ ] Gallery tile transitions are simplified or absent. #CAN'T CURRENTLY TEST DUE TO OTHER BUG'
- [x] Thumbnail swap in list/gallery does not crossfade — thumbnails snap in instantly with Reduce Motion enabled. ✓
- [ ] QuickLook open/close transition is simplified. #FAILED 

---

## 20. Error states

- [X] Open a folder the app cannot read; "Folder Unavailable" shown with appropriate icon and message.
- [ ] Apply to a read-only file; failure reflected in partial-failure count; other files in selection succeed. #B42: tested with a Preview-locked file (macOS advisory lock, not POSIX read-only). exiftool bypasses advisory locks — metadata was confirmed written to disk. App-level pre-write lock check needed. To properly test partial-failure count, re-test with a truly permission-locked file (chmod a-w).
- [ ] Restore when the backup directory has been manually deleted; graceful error message, no crash.
