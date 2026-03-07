# Import Manual Smoke Checklist (Check-Off)

Date: __________
Tester: __________
Build/Branch: __________
Target Folder: __________

Fixtures used: `docs/fixtures/import-smoke/`

- Target set expected: `001.jpg`, `002.jpg`, `003.jpg`
- For GPX matching: if timestamps differ, set a larger tolerance in GPX advanced options.

## 1) ExifTool CSV Import (Auto Filename Match)

- [x] Open `File > Import > CSV…`
- [x] Choose `docs/fixtures/import-smoke/exiftool-safe.csv`
- [x] Scope = `Folder`
- [x] Click `Preview…`
- [x] Verify all rows match by filename (`001/002/003`)
- [x] Click `Import`
- [x] Verify status message stages fields across expected files

Result:
- [x] Pass
- [ ] Fail
Notes: __________

## 2) ExifTool CSV Import (Auto Row-Order Fallback)

- [x] Open `File > Import > CSV…`
- [x] Choose `docs/fixtures/import-smoke/exiftool-fallback-row-order.csv`
- [x] Scope = `Folder`
- [ ] Click `Preview…` - #PREVIEW NOT BEHAVING CORRECTLY - SOURCE ROWS FAILED - SHOULD READ ROW 001, ROW 002, ROW 003 - SEE '/Users/chrislemarquand/Documents/Photography/Apps/Ledger/docs/fixtures/import-smoke/Screenshot 2026-03-07 at 12.10.04.png'
- [X] Verify row-order behavior is used (not filename-only)
- [ ] Verify fallback warning/info appears - #NOT CLEAR WHAT THIS WARNING SHOULD BE OR WHERE IT IS - HAVE NOT SEEN IT
- [X] Click `Import`

Result:
- [ ] Pass
- [X] Fail - #DATA SEEMS TO STAGE CORRECTLY BUT PREVIEW AND WARNINGS DO NOT PASS
Notes: __________

## 3) EOS 1V CSV Import

- [x] Open `File > Import > EOS 1V CSV…`
- [x] Choose `docs/fixtures/import-smoke/eos1v-smoke.csv`
- [x] Scope = `Folder`
- [x] Click `Preview…`
- [x] Verify 3 rows parse and map in row order
- [x] Click `Import`
- [ ] Verify no synthetic lens value is auto-authored - #THE FOCAL LENGTHS ARE NOT TRIGGERING THE CORRECT LENSES, THE LOGIC IS WAY OUT OF WHACK. THIS NEEDS COMPLETELY REWRITING AND YOU NEED TO ASK ME WHICH FOCAL LENGTH SHOULD TRIGGER WHICH LENS. 

Result:
- [ ] Pass
- [X] Fail
Notes: __________

## 4) GPX Import

- [X] Open `File > Import > GPX…`
- [x] Choose `docs/fixtures/import-smoke/gpx-smoke.gpx`
- [x] Set tolerance high enough for current test data
- [x] Click `Preview…`
- [x] Verify matched files receive GPS fields (or clear out-of-tolerance warnings)
- [x] Click `Import`

Result:
- [x] Pass
- [ ] Fail
Notes: __________

## 5) Reference Folder Import

- [x] Ensure `docs/fixtures/import-smoke/reference-folder/` contains real images with metadata
- [X] Ensure at least one filename matches a target file in current folder
- [x] Open `File > Import > Reference Folder…`
- [x] Choose `docs/fixtures/import-smoke/reference-folder/`
- [x] Click `Preview…`
- [x] Verify matched filenames import metadata; unmatched rows show conflicts/warnings
- [x] Click `Import`

Result:
- [x] Pass
- [ ] Fail
Notes: #NEEDS TO WORK LIKE CSV IMPORT - IF FILENAME MATCH, MATCH BY FILENAME. IF NOT A FILENAME MATCH, THEN APPLY THE METADATA FROM THE REFERENCE FOLDER SELECTED (IN NAME ORDER A-Z) TO THE FOLDER IN LEDGER'S MAIN PANE (IN WHICHEVER SORT ORDER THE USER'S GOT ACTIVATED)

## 6) Reference Image Import

- [X] Open `File > Import > Reference Image…`
- [x] Choose one real reference image with metadata
- [x] Use selection or folder scope as intended
- [x] Click `Preview…`
- [x] Verify metadata from reference image is applied to targets
- [x] Click `Import`

Result:
- [x] Pass
- [ ] Fail
Notes: __________

## Global Checks (run during all paths)

- [ ] `Fields…` filter limits staged fields correctly
- [ ] `If no match` policy behaves as expected (`Clear` vs `Skip`)
- [ ] No UI freezes
- [ ] No crashes
- [ ] Status message counts look correct

## Sign-Off

- [ ] Manual smoke complete
- [ ] Ready for release candidate

Signed: __________
