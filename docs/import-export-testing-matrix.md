# Import / Export Testing Matrix

Last updated: 2026-03-06

---

## EOS 1V CSV Import

| ID | Scenario | Steps | Expected |
|----|----------|-------|----------|
| E1 | Basic import, all rows, folder scope | Open EOS 1V CSV dialog, pick valid camera CSV, scope = Folder, click Preview | All 36 rows matched; field count > 0 |
| E2 | Row count respects file count when selection scope | Select exactly 5 files, open EOS 1V CSV dialog, scope = Selection, click Preview | Only 5 rows parsed and matched |
| E3 | Unlimited rows when folder scope | Open EOS 1V CSV dialog, scope = Folder (no selection), click Preview | rowParityRowCount = 0; all CSV rows parsed |
| E4 | Field filter applied | Open EOS 1V CSV dialog, click Fields..., uncheck all but one field, click Preview | Preview shows only 1 field per match; Apply stages only that field |
| E5 | Clear empty values | Set Empty Values = Clear, CSV has blank cells, click Apply | Blank-value fields cleared in staged edits |
| E6 | Skip empty values | Set Empty Values = Skip, CSV has blank cells, click Apply | Blank-value fields not staged |
| E7 | Re-import identical data | Import CSV, Apply, then re-open and import same CSV again | Status bar reports 0 fields staged (data already on disk) |
| E8 | Persisted options reset on open | Change rowParityRowCount via UserDefaults, re-open sheet | rowParityRowCount reset to 0 (unlimited) |
| E9 | Default scope with 0–1 files selected | Deselect all files, open EOS 1V CSV dialog | Scope defaults to Folder |

---

## ExifTool CSV Import

| ID | Scenario | Steps | Expected |
|----|----------|-------|----------|
| C1 | Basic import, all rows, folder scope | Open CSV dialog, pick ExifTool-exported CSV, scope = Folder, click Preview | All file rows matched by filename; field count > 0 |
| C2 | Single file selected, folder scope | Select 1 file, open CSV dialog | Scope defaults to Folder; rowParityRowCount = 0 |
| C3 | Multiple files selected, selection scope | Select 5 files, open CSV dialog | Scope defaults to Selection |
| C4 | Match by filename | Import CSV with SourceFile column matching filenames in folder | Rows matched by filename |
| C5 | Match by row order | Set strategy = Row Order, folder scope | Rows matched positionally |
| C6 | Field filter applied | Click Fields..., select subset, Apply | Only selected fields staged |
| C7 | Clear empty values | CSV has empty cells, Empty Values = Clear | Empty cells clear existing metadata |
| C8 | Skip empty values | CSV has empty cells, Empty Values = Skip | Empty cells do not overwrite existing metadata |
| C9 | selectedTagIDs reset on sheet open | Previously had Fields... selection saved, reopen sheet | All fields selected (selectedTagIDs = []) |

---

## GPX Import

| ID | Scenario | Steps | Expected |
|----|----------|-------|----------|
| G1 | Basic GPS tagging | Open GPX dialog, pick valid GPX file, folder scope, click Preview | Files within time tolerance matched; GPS fields populated |
| G2 | Time tolerance boundary | Use file whose capture time is just within tolerance (default 600 s) | File matched |
| G3 | Time tolerance exceeded | Use file whose capture time is outside tolerance | File not matched; warning shown |
| G4 | Camera offset applied | Set camera offset (e.g. +3600 s), import | Timestamps shifted by offset before matching |
| G5 | No GPS-capable files in folder | Folder contains non-image files or files without timestamps | 0 matches; no crash |

---

## Reference Folder Import

| ID | Scenario | Steps | Expected |
|----|----------|-------|----------|
| R1 | Basic reference folder import | Open Reference Folder dialog, pick folder of reference images, scope = Folder | Target files matched by filename to reference images; metadata copied |
| R2 | Field filter applied | Click Fields..., select subset, Apply | Only selected fields staged |
| R3 | Filename mismatch | Reference folder contains files with different names | 0 matches; conflict or warning shown |
| R4 | Mixed match / no-match | Some files match, some don't | Matched files staged; unmatched reported as warnings |

---

## Reference Image Import

| ID | Scenario | Steps | Expected |
|----|----------|-------|----------|
| I1 | Single reference image to selection | Select target files, open Reference Image dialog, pick one image | Selected files receive metadata from reference image |
| I2 | Field filter applied | Click Fields..., select subset, Apply | Only selected fields staged |
| I3 | No files selected | 0 or 1 files selected, open Reference Image dialog | Scope = Folder used; all folder files receive reference metadata |

---

## ExifTool CSV Export

| ID | Scenario | Steps | Expected |
|----|----------|-------|----------|
| X1 | Export all fields for folder | Select folder, File > Export > ExifTool CSV, no field filter | CSV produced with one row per file, all metadata columns |
| X2 | Export selection only | Select 5 files, export | CSV contains exactly 5 data rows |
| X3 | SourceFile column present | Export any set of files | SourceFile column contains correct absolute paths |
| X4 | Re-import round-trip | Export CSV, then import same CSV back | 0 fields staged (values already on disk) |
| X5 | Empty fields in export | Some files have empty metadata fields | Empty cells written to CSV (not omitted) |

---

## General / Regression

| ID | Scenario | Steps | Expected |
|----|----------|-------|----------|
| GR1 | Orange dot appears after staging | Apply any import | Affected files show orange dot in gallery |
| GR2 | Orange dot clears after write | Apply staged edits (Cmd+S / write to disk) | Orange dots removed |
| GR3 | Status bar accurate | Import where some values already on disk | Staged count reflects only new changes, not all matched fields |
| GR4 | Cancel does not stage | Open import sheet, click Preview, then Cancel | No pending edits created |
| GR5 | Default Empty Values = Clear | Open any import dialog fresh | Clear selected by default |
