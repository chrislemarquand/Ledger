# Import / Export Testing Matrix

Last updated: 2026-03-07  
Branch target: `codex/v1.1`  
Purpose: Full manual retest matrix including latest import bug fixes/amendments.

## Preflight

| Done | ID | Check | Steps | Expected | Result | Notes |
|------|----|----------|-------|----------|--------|-------|
| [x] | P1 | Clean test context | Open a test folder with at least `001.jpg`, `002.jpg`, `003.jpg`; clear staged edits | No orange dots before starting | Pass | 
| [x] | P2 | EOS lens map is internal | No setup required (do not place any lens CSV on Desktop) | EOS lens inference runs from bundled app mapping only | Pass | 
| [x] | P3 | Fixture availability | Confirm fixtures under `docs/fixtures/import-smoke/` are present | All matrix cases runnable | Pass | 
| [x] | P4 | Sort-order awareness | Note current Ledger main pane sort (for row-order tests) | Row-order expectations are deterministic | Pass | Sorting by size (highest to lowest) |

---

## ExifTool CSV Import

Encoding note: import decoding is deterministic (`UTF-*` first, then `CP1252`/`ISO-8859-1`). For CSVs without BOM, ambiguous byte sequences may still decode as UTF-8 by design.

| Done | ID | Scenario | Steps | Expected | Result | Notes |
|------|----|----------|-------|----------|--------|-------|
| [x] | C1 | Basic import, all rows, folder scope | Open CSV import, choose valid ExifTool CSV, scope `Folder`, click `Preview` | Rows match expected files, field count > 0 | Pass | 
| [x] | C2 | Default scope with 1 selected file | Select 1 file, open CSV import | Scope defaults to `Folder` | Pass | 
| [x] | C3 | Default scope with 2+ selected files | Select 2+ files, open CSV import | Scope defaults to `Selection` | Pass | 
| [x] | C4 | Auto-match by filename | Use CSV with complete unique `SourceFile` values | Matches by filename (no fallback warning) | Pass | CSV used produced unrelated field-validation warnings (e.g. GPSAltitude/Flash/FocalLength), but filename matching behavior passed |
| [x] | C5 | Auto fallback to row order | Use CSV with duplicate/missing `SourceFile` values | Matches by row order | Pass | 
| [x] | C6 | Fallback preview row labels (bug fix) | Case C5, open `Preview` | Source rows shown as `Row 001`, `Row 002`, ... | Pass | 
| [x] | C7 | Fallback warning visibility/copy (bug fix) | Case C5, open `Preview` | Warning block is visible and explains row-order matching reason | Pass | Warnings visible in preview (see screenshots). Concern logged: importing ExifTool-exported CSV still shows many field-validation warnings and row-order matching fallback, which should not normally be required |
| [x] | C8 | Fallback end-to-end staging (bug fix) | Case C5, click `Import` | Data stages correctly in row order | Pass | 
| [x] | C9 | `If no match: Clear` clears missing field values (bug fix) | Use CSV row that omits a field currently present on target (for a matched file), set `Clear`, import | Existing target value for omitted field is cleared | Pass | Re-validated: clear remains staged (orange dot) and prior baseline value is no longer shown as grey placeholder text. |
| [x] | C10 | `If no match: Skip` retains missing field values (bug fix) | Same as C9 but set `Skip` | Existing target value for omitted field is retained | Pass | Re-validated: no staged clear for skipped fields; retained value remains shown normally and behavior is clearly distinct from C9. |
| [x] | C11 | Field filter | Use `Fields...` and keep 1-2 tags only | Only selected fields stage | Pass | Verified fixed: import now respects current Fields selection at commit; preview count aligns with selected unique tags. |
| [x] | C12 | Fields selection reset | Close and reopen CSV import sheet after custom field selection | Starts with all found fields selected (`selectedTagIDs` empty) | Pass | 

---

## EOS 1V CSV Import

| Done | ID | Scenario | Steps | Expected | Result | Notes |
|------|----|----------|-------|----------|--------|-------|
| [x] | E1 | Basic EOS import | Open EOS 1V CSV import, choose valid EOS CSV, scope `Folder`, preview | Rows parse/match in row order | Pass | 
| [x] | E2 | Selection row cap | Select 5 files, open EOS import, scope `Selection`, preview | 5 rows parsed/matched | Pass | 
| [x] | E3 | Folder unlimited rows | Open EOS import with scope `Folder`, preview | All rows parsed (`rowParityRowCount = 0`) | Pass | 
| [x] | E4 | EOS field filter | Use `Fields...` to include subset only, import | Only selected fields stage | Pass | 
| [x] | E5 | Single-candidate lens auto-stage (bug fix) | Use focal length with exactly one bundled lens candidate, import | `Lens Model` is staged automatically | Pass | Previously observed one-off crash; not reproducible on current build after repeated retest. Monitoring only. |
| [x] | E6 | Multi-candidate lens prompt flow (bug fix) | Use focal length with 2-3 lens candidates across multiple rows, import | Prompt supports per-row choice and optional "apply to remaining rows at this focal length" | Pass | Re-validated: apply-all option works; first ambiguous prompt can fan out chosen lens to remaining rows at same focal length. |
| [x] | E7 | Multi-candidate lens choice applied (bug fix) | In E6, choose different lenses for different rows | Each row stages the chosen lens | Pass |  |
| [x] | E8 | Lens prompt cancel aborts import (bug fix) | In E6, cancel on prompt | Import is cancelled; no fields staged | Pass |  |
| [x] | E9 | Lens mapping missing/unknown focal | Use focal length not present in mapping file | No crash; lens left unstaged | Pass |  |
| [ ] | E10 | Excluding lens via Fields | Deselect `Lens Model` in `Fields...`, import ambiguous EOS file | No lens prompt shown; other selected fields still stage | Fail | `Lens Model` cannot be independently deselected; it is greyed out unless `Focal Length` is selected. No lens prompt appears when focal is deselected. Behavior seems expected but test description is not currently actionable. |

---

## GPX Import

| Done | ID | Scenario | Steps | Expected | Result | Notes |
|------|----|----------|-------|----------|--------|-------|
| [x] | G1 | Basic GPS tagging | Open GPX import, pick valid GPX, preview/import | Files within tolerance matched with GPS fields | Pass |  |
| [ ] | G2 | Tolerance boundary | Use image time just inside tolerance | File is matched | Skip |  |
| [x] | G3 | Outside tolerance | Use image time outside tolerance | File not matched; warning shown | Pass |  |
| [x] | G4 | Camera offset | Set non-zero camera offset, preview | Matching shifts with offset | Pass | Re-validated: GPX Advanced values now reset to defaults on each new GPX import session (`Tolerance=600`, `Offset=0`). |
| [x] | G5 | No timestamp-capable targets | Run on files lacking capture timestamps | 0 matches; no crash | Pass |  |

---

## Reference Folder Import

| Done | ID | Scenario | Steps | Expected | Result | Notes |
|------|----|----------|-------|----------|--------|-------|
| [x] | R1 | Basic reference folder import | Open Reference Folder import, choose metadata-bearing reference folder, preview | Filename matches stage as expected | Pass |  |
| [x] | R2 | Field filter | Use `Fields...` to select subset, import | Only selected fields stage | Pass |  |
| [x] | R3 | Filename mismatch with fallback OFF | Disable `Fallback unmatched rows by row order`, import with no filename matches | Unmatched rows show conflicts/warnings; no row-order fallback applied | Pass |  |
| [ ] | R4 | Mixed match/no-match with fallback OFF | Some filename matches, some misses; fallback OFF | Matched rows stage; unmatched rows remain conflicts | Skip |  |
| [x] | R5 | Optional row-order fallback ON (bug fix) | Enable `Fallback unmatched rows by row order`, import where some rows have no filename match | Unmatched rows are mapped by row order to remaining unmatched targets | Pass |  |
| [x] | R6 | Ordering contract (bug fix) | R5 with known sort order and known reference filenames | Source order is reference filename A-Z; target order follows current Ledger visible sort | Pass |  |
| [x] | R7 | Fallback is explicit opt-in (bug fix) | Reopen sheet after prior runs | Fallback behavior only applies when toggle is ON | Pass |  |

---

## Reference Image Import

| Done | ID | Scenario | Steps | Expected | Result | Notes |
|------|----|----------|-------|----------|--------|-------|
| [x] | I1 | Reference image to selection | Select targets, import one reference image, preview/import | Selected files receive reference metadata | Pass |  |
| [x] | I2 | Field filter | Use `Fields...` subset, import | Only selected fields stage | Pass |  |
| [x] | I3 | Scope with 0-1 selected files | Open with none or one selected | Scope defaults to `Folder` | Pass |  |

---

## ExifTool CSV Export

| Done | ID | Scenario | Steps | Expected | Result | Notes |
|------|----|----------|-------|----------|--------|-------|
| [x] | X1 | Export folder | Export ExifTool CSV for folder | CSV produced with one row per file | Pass | Behavior is correct, but UX should make export scope explicit (folder vs selection). |
| [x] | X2 | Export selection | Select 5 files, export | CSV contains exactly 5 data rows | Pass |  |
| [x] | X3 | `SourceFile` path correctness | Inspect export | `SourceFile` column paths are correct absolute paths | Pass |  |
| [x] | X4 | Export/import round-trip | Export CSV and re-import same file | 0 new fields staged when values already match on disk | Pass | Fixed: ExifTool textual forms now normalize on import (units/enum/date forms), duplicate `Copy1:*` mappings no longer inflate staged fields, and GPS parsing/sign handling is stable for latitude/longitude plus location numeric fields. |
| [x] | X5 | Empty field handling | Export files with missing metadata | Empty cells are present (not silently dropped) | Pass |  |
| [x] | X6 | Leading-dash filename safety | Include file named like `-leading-dash.jpg`, export | Export succeeds and includes file row | Pass |  |

---

## General / Regression

| Done | ID | Scenario | Steps | Expected | Result | Notes |
|------|----|----------|-------|----------|--------|-------|
| [x] | GR1 | Staging indicator | Perform any import | Affected files show orange staging indicator | Pass |  |
| [x] | GR2 | Write clears staged state | Write staged edits to disk | Orange indicators clear | Pass |  |
| [ ] | GR3 | Status message counts | Run mixed import (some unchanged, some changed) | Status counts reflect real staged field/file counts | Skip |  |
| [x] | GR4 | Cancel path | Open import flow, then cancel before import | No staged edits created | Pass |  |
| [x] | GR5 | Default empty policy | Open each import dialog fresh | `If no match` defaults to `Clear` | Pass |  |
| [x] | GR6 | Preview stability | Run previews across all import modes | No crashes or UI hangs | Pass |  |

---

## Retest Sign-Off

- Date: __________
- Tester: __________
- Build/Commit: __________
- Folder used: __________
- Overall result: `Pass / Fail`
- Notes: ________________________________________________
