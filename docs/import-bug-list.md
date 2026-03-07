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
  - Uses `~/Desktop/lensfocalength.csv` focal-length mapping during EOS import.
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

## Remaining Work
1. None from this bug list.
