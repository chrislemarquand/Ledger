# Date/Time Data Mode Incident Log (Unresolved)

Date: 2026-04-04
Scope: Ledger Date/Time sheet, especially `Data` mode behavior in `/Users/chrislemarquand/Desktop/TZtest`

## 1) What the behavior should be

### Data mode (`Adjust Date and Time` -> `Data`)

- `Original` row should only display current file data (read-only), and should not be transformed by Data mode logic.
- `Adjusted` row should reflect what will be written based on:
  - selected `Read from` source
  - selected `Apply to` destinations
- If no destination is selected, `Adjusted` should be blank (or `—`).
- `Preview` popover and `Adjusted` row should always agree.
- `Read from` options should disable when the source field is unavailable.
- `Apply to` options should disable for impossible operations, including source==destination.
- If launched from inspector `Set…`, `Read from` should default to the relevant inspector field.
- If launched from menu, no inspector field is inferred; default source should be first available source.
- Multi-file behavior should match other sheet tabs: representative file = first selected file.

### Time zone/shift/specific consistency constraints

- Original row should not be silently converted to a different baseline/timezone when opening the sheet.
- Non-timezone tabs should not apply timezone logic.

## 2) What the behavior currently is (as reported and reproduced in this workstream)

- In Data mode, `Adjusted` field has repeatedly failed to update even when `Preview` popover shows the correct target write values.
- `Preview` can show per-file deltas (`+1h`, `+2h`) while the visible time string appears unchanged in certain rows, creating contradictory output.
- `Original` field has repeatedly shown a value offset by ~1 hour from what is expected from file metadata in the inspected scenario (`5I6A6293.CR2`), even when preview content looked correct.
- Net effect: UI trust is broken because header rows and preview can disagree.

## 3) Concrete problem cases called out

- Folder: `/Users/chrislemarquand/Desktop/TZtest`
- File example: `/Users/chrislemarquand/Desktop/TZtest/5I6A6293.CR2`
- User scenario: copy from one date field to one or more other fields in Data mode.
- Observed problem: preview appears plausible; `Adjusted` header does not match expected write value; `Original` has at times been displayed with an incorrect hour offset.

## 4) Everything attempted so far and why it failed to resolve the issue

## Attempt A: remove open-blocking metadata gate

Intent:
- Allow sheet to open even if background metadata loading is still running.

Changes made:
- Removed hard block on opening date/time sheet during folder metadata loading.
- Switched to non-blocking behavior with blank/partial display when data is missing.

Result:
- Sheet opens as desired, but did not resolve Data mode header/preview consistency issue.

Status:
- Partially successful (UX open behavior), does not fix core bug.

---

## Attempt B: improve progress/load handling for RAW metadata pipeline

Intent:
- Improve status indicator increments and reduce coarse jumps.

Changes made:
- Multiple iterations touching metadata prefetch and progress accounting.

Result:
- User observed unstable/counterintuitive progress jumps; changes were reverted per request.

Status:
- Reverted.

---

## Attempt C: Data mode UI architecture additions (`Read from`, `Apply to` constraints)

Intent:
- Introduce clear source/destination semantics and prevent invalid combinations.

Changes made:
- Added `Read from` radio group (`Original`, `Digitised`, `Modified`, `File`).
- Added disabling logic for source==destination.
- Kept `Apply to` checkboxes and wired enable/disable rules.
- Added launch-context support (inspector vs menu) for source defaults.

Result:
- Interaction model improved, but core header mismatch remained.

Status:
- In place, but not sufficient.

---

## Attempt D: preview model expansion (per-destination rows)

Intent:
- Make preview explicit when multiple destinations are selected.

Changes made:
- Data mode preview now emits one row per destination (`file [Target]`).

Result:
- Preview became clearer and often correct.
- However, header fields (`Original`/`Adjusted`) still diverged from preview in reported scenarios.

Status:
- Kept; still does not fix core issue.

---

## Attempt E: remove silent source auto-mutation while sheet is open

Intent:
- Prevent sheet from changing `Read from` under the user.

Changes made:
- Removed auto-fallback mutations in `onReceive`/`onChange` paths.

Result:
- Reduced hidden state changes.
- Did not eliminate wrong `Original` / stale `Adjusted` symptoms.

Status:
- Kept; still does not fix core issue.

---

## Attempt F: canonical Data-mode helper refactor (latest)

Intent:
- Kill split logic by using one canonical state source for Data mode across preview/stage/header.

Changes made:
- Added model-level canonical helpers:
  - `dataModeReadValue(for:session:)`
  - `dataModeWritableTargets(for:)`
  - `dataModeFileState(for:session:)`
- Routed Data mode preview and apply staging through that canonical state.
- Rewired Data mode `Adjusted` header derivation to use canonical state.
- Set Data mode `Original` header back to representative captured baseline path.

Result:
- Unit tests pass.
- User reports no real-world behavior improvement for the core issue.

Status:
- Implemented, but failed to resolve user-facing bug.

## 5) Why this is still broken (current assessment)

The problem is still present because the UI and model paths are still not truly end-to-end unified in the real runtime scenario:

- Preview path appears correct for many cases.
- Header rows are still being derived through a different effective state lifecycle than preview in practice.
- That means timing/state origin differences are still leaking into displayed values.

In plain terms: the system still has state split behavior at runtime, even after refactoring attempts.

## 6) Why tests passed while UX is still wrong

The tests currently validate model logic and preview/staging behavior, but they do **not** assert the full SwiftUI sheet state lifecycle under real interaction timing (open sheet, toggle read/apply, inspector launch context, metadata arrival timing, representative-file rendering updates).

So it is possible to have:
- model tests green
- preview rows correct
- visible sheet header fields still wrong/stale

That is exactly what happened.

## 7) Relevant touched files during failed attempts

- `Sources/Ledger/AppModel+DateTimeAdjust.swift`
- `Sources/Ledger/DateTimeAdjustSheetView.swift`
- `Sources/Ledger/DateTimeAdjustModels.swift`
- `Sources/Ledger/MainContentView.swift`
- `Sources/Ledger/InspectorView.swift`
- `Tests/LedgerTests/AppModelTests.swift`

Also present as unrelated dirty files in working tree:
- `Sources/ExifEditCore/ExifToolService.swift`
- `Sources/Ledger/AppModel+MetadataPipeline.swift`

## 8) Exact unresolved bug statement

Data mode is still not trustworthy because:
- `Adjusted` header does not reliably reflect the value shown in preview.
- `Original` header can display the wrong hour compared with expected file metadata context.
- Therefore user cannot safely rely on header rows to understand what write will occur.

## 9) Blunt status

This is not fixed.
The attempted patches improved pieces of behavior but failed to restore reliable, coherent Data mode UX.
