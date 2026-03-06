# Import Matrix Test Results

Generated: 2026-03-06
Test file: `Tests/LedgerTests/ImportMatrixTests.swift`
Run: `swift test --filter ImportMatrixTests`

---

## Summary

**26 tests · 0 failures · all passing**

---

## Results by Matrix ID

| ID  | Test Name | Result | Notes |
|-----|-----------|--------|-------|
| E1  | `testE1_EOSBasicImportAllRowsFolderScope` | ✅ Pass | 36 rows parsed, fields present |
| E2  | `testE2_EOSRowCountRespectsSelectionScope` | ✅ Pass | `rowParityRowCount=5` limits parse to 5 rows |
| E3  | `testE3_EOSUnlimitedRowsWhenFolderScope` | ✅ Pass | `rowParityRowCount=0` → all 8 rows parsed |
| E4  | — | ⬜ Not unit-testable | Field filtering happens in `ImportSession.filterAssignments` (private); covered implicitly by C6 / R2 / I2 |
| E5  | — | ⬜ Covered in `ImportSystemTests` | `testStageImportAssignmentsRespectsEmptyPolicy` |
| E6  | — | ⬜ Covered in `ImportSystemTests` | Same test as E5 |
| E7  | `testE7_ReimportIdenticalDataStagesZeroFields` | ✅ Pass | Re-import of existing on-disk value stages 0 fields |
| E8  | `testE8_SessionResetsRowParityRowCountToUnlimitedWithFewFilesSelected` | ✅ Pass | `rowParityRowCount=0` with 0 files selected |
| E9  | `testE9_DefaultScopeIsFolderWithZeroOrOneFile` | ✅ Pass | Scope = `.folder` with 0 and 1 files |
| C1  | `testC1_CSVBasicImportAllRowsFolderScope` | ✅ Pass | 3 rows parsed, no warnings |
| C2  | `testC2_SingleFileSelectedDefaultsToFolderScope` | ✅ Pass | 1 file → scope = `.folder` |
| C3  | `testC3_MultipleFilesSelectedDefaultsToSelectionScope` | ✅ Pass | 5 files → scope = `.selection`, `rowParityRowCount=5` |
| C4  | — | ⬜ Covered in `ImportSystemTests` | `testCSVImportAdapterParsesFilenameAliasAndMappedFields` |
| C5  | — | ⬜ Covered in `ImportSystemTests` | `testCSVImportAdapterSupportsRowParityWithoutFilenameColumn` |
| C6  | `testC6_CSVFieldFilterApplied` | ✅ Pass | Filter by `selectedTagIDs` reduces field set |
| C7  | — | ⬜ Covered in `ImportSystemTests` | `testStageImportAssignmentsRespectsEmptyPolicy` |
| C8  | — | ⬜ Covered in `ImportSystemTests` | Same test |
| C9  | `testC9_SelectedTagIDsResetOnSessionOpen` | ✅ Pass | `selectedTagIDs=[]` even after persisted dirty options |
| G1  | — | ⬜ Covered in `ImportSystemTests` | `testGPXImportAdapterParsesTimestampsWithoutFractionalSeconds` |
| G2  | `testG2_FileWithinToleranceIsMatched` | ✅ Pass | Large tolerance ensures match regardless of timezone |
| G3  | `testG3_FileOutsideToleranceIsNotMatched` | ✅ Pass | Year-2000 date vs 2026 GPX → outside tolerance, warning emitted |
| G4  | `testG4_CameraOffsetShiftsTimestampBeforeMatching` | ✅ Pass | `gpxCameraOffsetSeconds = TimeZone.current.secondsFromGMT()` → match |
| G5  | `testG5_NoFilesWithCaptureDateProducesZeroMatchesNoCrash` | ✅ Pass | No date field → 0 rows, warning, no crash |
| R1  | `testR1_ReferenceFolderBasicImport` | ✅ Pass | One ref image → one row, filename selector |
| R2  | `testR2_ReferenceFolderFieldFilterApplied` | ✅ Pass | `selectedTagIDs=["xmp-title"]` → only Title field in row |
| R3  | `testR3_ReferenceFolderFilenameMismatchProducesZeroMatched` | ✅ Pass | Filename mismatch → 0 matched, conflict reported |
| R4  | `testR4_ReferenceFolderMixedMatchAndNoMatch` | ✅ Pass | 1 match + 1 unmatched → 1 matched row + 1 conflict |
| I1  | — | ⬜ Covered in `ImportSystemTests` | `testReferenceImageImportUsesReferenceFilenameAsSourceIdentifier` |
| I2  | `testI2_ReferenceImageFieldFilterApplied` | ✅ Pass | `selectedTagIDs=["xmp-title"]` → only Title in row |
| I3  | `testI3_NoFilesSelectedDefaultsToFolderScope` | ✅ Pass | 0 files → scope = `.folder` |
| X1–X5 | — | ⬜ Not unit-testable | Require real exiftool binary + real image files; covered by manual QA |
| GR1 | `testGR1_PendingEditsSetAfterStaging` | ✅ Pass | `hasPendingEdits` = true after `stageImportAssignments` |
| GR2 | `testGR2_PendingEditsClearedAfterClear` | ✅ Pass | `hasPendingEdits` = false after `clearPendingEdits` |
| GR3 | `testGR3_StageCountReflectsOnlyNewChanges` | ✅ Pass | Identical on-disk value not counted; new value counted |
| GR4 | `testGR4_CancelDoesNotCreatePendingEdits` | ✅ Pass | No staging call → no pending edits |
| GR5 | `testGR5_DefaultEmptyValuePolicyIsClear` | ✅ Pass | All `ImportSourceKind` defaults have `.clear` policy |

---

## Issues Found During Implementation

### R1 / R2: URL key mismatch for `metadataByFile` (fixed)

**Root cause:** On macOS, `NSTemporaryDirectory()` returns a path under `/var/folders/…`, which is a symlink to `/private/var/folders/…`. `FileManager.contentsOfDirectory(at:)` returns URLs consistent with whatever prefix you pass in. If the prefix supplied to the context matches the one used to write files but differs from what the OS resolves, the dictionary lookup fails silently (returns `nil`), causing the adapter to emit a "Couldn't read metadata" warning instead of producing a row.

**Fix:** Added `makeRefFolder(in:name:files:)` test helper that enumerates the folder with `contentsOfDirectory` after creation and returns the exact canonical URL objects that the adapter will use as lookup keys. All R1–R4 tests now use these canonical URLs.

**Proposed production fix:** None required. This is a test infrastructure issue only. The production code path receives URLs from `ImportCoordinator.metadataFilesNeeded` → `ExifToolService.readMetadata`, which returns URLs from the same source, so keys are always consistent.

---

## Scenarios Not Covered (and Why)

| Scope | Reason |
|-------|--------|
| E4 (EOS field filter) | `filterAssignments` is `private` on `ImportSession`; filtering is implicitly verified by C6, R2, I2 at the adapter level |
| E5, E6, C4, C5, C7, C8, G1, I1 | Already covered by existing tests in `ImportSystemTests.swift` |
| X1–X5 (CSV Export) | Require a real `exiftool` binary and actual image files with metadata; not suitable for unit tests |
| GR1/GR2 "orange dot" visual indicator | UI-level behaviour; not exposed through `AppModel` API under test |
