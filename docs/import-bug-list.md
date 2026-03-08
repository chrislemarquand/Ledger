# Import Bug List (From Manual Smoke Checklist)

Generated: 2026-03-07  
Source: `docs/import-manual-smoke-checklist.md`

## Current Status
- [x] 1) CSV fallback preview labels incorrect
- [x] 2) CSV fallback warning not visible/clear
- [x] 3) CSV fallback path partially passes (staging works, UX fails)
- [x] 4) EOS lens mapping behavior unacceptable
- [x] 5) Reference Folder fallback behavior gap vs desired workflow

## 1) CSV fallback preview labels incorrect
- Status: Done
- Severity: High
- Area: ExifTool CSV import (auto row-order fallback)
- Evidence: checklist note at line 33 (`#PREVIEW NOT BEHAVING CORRECTLY ... SHOULD READ ROW 001, ROW 002, ROW 003`)
- Observed impact: preview does not show expected row identifiers during fallback, making mapping hard to trust.
- Proposed fix:
  - In CSV row-order fallback mode, standardize source identifiers to `Row 001`, `Row 002`, `Row 003`, etc. in preview.
  - Add a UI-level test (or snapshot assertion) for preview text generation in fallback mode.

## 2) CSV fallback warning not visible/clear
- Status: Done
- Severity: Medium
- Area: ExifTool CSV import warnings
- Evidence: checklist note at line 35 (`#NOT CLEAR WHAT THIS WARNING SHOULD BE OR WHERE IT IS`)
- Observed impact: users cannot confirm why matching switched from filename to row order.
- Proposed fix:
  - Surface fallback reason in a dedicated, always-visible warning block in Preview.
  - Include explicit language: `Matching mode: Row order (reason: duplicate/missing/non-unique SourceFile).`
  - Keep status-bar copy as secondary, not primary.

## 3) CSV fallback path partially passes (staging works, UX fails)
- Status: Done
- Severity: Medium
- Area: ExifTool CSV import fallback flow
- Evidence: checklist note at line 40 (`#DATA SEEMS TO STAGE CORRECTLY BUT PREVIEW AND WARNINGS DO NOT PASS`)
- Observed impact: correctness appears OK, but user confidence and explainability are weak.
- Proposed fix:
  - Treat as UX-correctness bug: fix preview labels + warning visibility together in one PR.
  - Add acceptance test that verifies both staging result and preview/warning copy.

## 4) EOS lens mapping behavior unacceptable
- Status: Done (v1.0 interim; settings-driven policy still planned for v1.1)
- Severity: High
- Area: EOS 1V import lens handling
- Evidence: checklist note at line 51 (`#THE FOCAL LENGTHS ARE NOT TRIGGERING THE CORRECT LENSES ...`)
- Observed impact: wrong lens metadata risk; import trust regression.
- Implemented now:
  - Uses an app-bundled focal-length mapping table during EOS import.
  - If one candidate lens exists for a focal length, stages lens automatically.
  - If multiple candidates exist, prompts user to choose per matched row.
  - If prompt is cancelled, import is cancelled.
- Follow-up (v1.1 settings app):
  - Move mapping/policy into user-configurable settings (instead of Desktop CSV contract).
  - Add configurable unknown/ambiguous behavior policy.

## 5) Reference Folder fallback behavior gap vs desired workflow
- Status: Done
- Severity: Medium
- Area: Reference Folder import matching strategy
- Evidence: checklist note at line 85 (desired: filename-first, then ordered fallback application)
- Observed impact: current behavior does not meet expected fallback semantics for non-matching filenames.
- Implemented:
  - Added explicit Reference Folder option: `Fallback unmatched rows by row order`.
  - Matching now runs in two stages when enabled:
    - Step 1: filename matching.
    - Step 2: unmatched reference rows are mapped in row order to remaining unmatched target files.
  - Ordering contract now applied:
    - reference source order: filename A-Z (adapter output order),
    - target order: current Ledger visible sort order (incoming target file order).
  - Fallback remains opt-in (disabled by default).

## v1.1 Must-Fix (Bugs)
1. EOS single-candidate lens auto-stage crash (`E5`)
- Status: Monitoring (not reproducible)
- Severity: High
- Goal: no crash during EOS import when a focal length maps to exactly one lens candidate.
- Plan:
  - Reproduce using E5 fixture path and capture symbolized stack.
  - Harden EOS lens assignment path in import commit flow.
  - Add regression test that covers import commit (not only preview/parse path).
- Exit criteria: E5 passes repeatedly without `EXC_BAD_ACCESS`.

2. CSV `If no match: Skip` stages unchanged fields (`C10`)
- Status: Done
- Severity: High
- Goal: unchanged values are retained and not shown as staged changes.
- Plan:
  - Enforce no-op filtering before staging when value is unchanged.
  - Ensure inspector staged styling (grey/orange state) only appears for real deltas.
- Exit criteria: C10 passes and visual behavior is distinct from `Clear`.

3. CSV field filter not respected (`C11`)
- Status: Done
- Severity: High
- Goal: only checked fields are staged/imported.
- Plan:
  - Enforce selected field set at final staging boundary.
  - Add regression tests for narrow field subsets.
- Exit criteria: C11 passes in preview + import behavior.

4. ExifTool export/import round-trip mismatch (`X4`)
- Status: Done
- Severity: High
- Goal: export then re-import same data yields zero net staged changes.
- Implemented:
  - Normalized ExifTool textual forms during import validation/staging (date with offsets, decimal-with-units, enum text variants).
  - Collapsed duplicate mapped columns by tag (e.g. `Copy1:*` + primary column) so preview/staging reflects unique tags.
  - Hardened coordinate parsing/sign handling for latitude and longitude, including `-0°` edge cases.
  - Added round-trip-focused regression coverage for ExifTool location formats (lat/lon/altitude/direction).
- Exit criteria: X4 passes; warnings reduced to true incompatibilities.

5. EOS field dependency expectation mismatch (`E10`)
- Severity: Medium
- Goal: behavior and test expectation align for `Lens Model` vs `Focal Length` selection dependency.
- Plan:
  - Keep dependency if intended, but make it explicit in test wording and UI copy.
  - Update matrix expectation to match intended behavior.
- Exit criteria: E10 becomes pass under explicit expected behavior.

## Post-Fix UX Polish
1. Clarify unchanged vs cleared vs staged states (from `C9/C10` behavior notes)
- Status: Done (v1.1)
- Implemented: when a clear is staged for a selected field, inspector placeholder no longer shows baseline/on-disk value in grey.
- Result: `Clear` and `Skip` now present as clearly different states during staging.

2. EOS ambiguous-lens prompt flow polish (from `E6` note)
- Status: Done (v1.1)
- Implemented: ambiguous EOS lens prompt now includes an "apply to remaining rows at this focal length" option.
- Result: repetitive prompt friction is reduced while keeping per-row flow available.

3. Reset GPX Advanced options on each new import session (from `G4` note)
- Status: Done (v1.1)
- Implemented: GPX import session initialization resets tolerance/offset to defaults.
- Result: prior typed GPX Advanced values no longer carry between import sessions.

4. Make export scope explicit (from `X1` note)
- Clearly state whether export target is `Folder` or `Selection (N files)` before confirmation.

5. Improve CSV warning quality for ExifTool-origin files (from `X4` note)
- Reduce noisy/repetitive warnings and prioritize actionable mismatch summaries.
