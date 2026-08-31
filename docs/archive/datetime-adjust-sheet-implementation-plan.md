# Date/Time Adjust Sheet - Implementation Plan

## Goal
Implement a single workflow sheet for date/time corrections with 4 modes (`Time Zone`, `Shift`, `Specific`, `File`), matching the Figma panes and existing Ledger sheet patterns.

This plan is SharedUI-first so Librarian can inherit the same controls and behavior.

## Design Sources
- Figma `Time Zone` pane: node `84:794`
- Figma `Shift` pane: node `84:1110`
- Figma `Specific` pane: node `84:1395`
- Figma `File` pane: node `84:1575`

## Non-negotiable Behavior
- `Original` and `Adjusted` are real date/time controls (AppKit-backed), not plain text fields.
- `Apply to` checkboxes decide which metadata tags are written.
- Secondary checked fields (`CreateDate`, `ModifyDate`) are synchronized to the final `DateTimeOriginal` result, not independently offset.
- `Preview…` opens a monospaced popover (same model as Batch Rename preview).
- Batch-safe apply path with backup/restore semantics.

## Scope
### In
- New Date/Time Adjust sheet with segmented mode switch.
- Scope selector: `This Photo`, `Selection`, `Folder`.
- ExifTool-backed preview and apply.
- SharedUI wrappers/components needed by the sheet.
- Inspector launch integration from date/time rows.

### Out
- Milliseconds editing UI.
- Any Tailwind/React implementation.
- Automatic inference of source timezone when metadata is missing (user must choose source basis).

## Architecture
### SharedUI (reusable)
- Reuse existing wrappers:
  - `InspectorDatePickerField`
  - `InspectorPopupField`
- Add new wrapper:
  - `WorkflowCityComboField` (`NSComboBox`, typeable filter, value binding).
- Add sheet-friendly row helpers if needed:
  - `WorkflowLabeledFieldRow` for consistent label/control alignment.

### Ledger (feature logic)
- Add sheet state + models in `AppModel`.
- Add preview/apply service layer for date/time operations.
- Add sheet view under `Sources/Ledger`.
- Wire from Inspector date/time rows `Set` buttons.

## Data Model
Add new domain types (Ledger-side):
- `DateTimeAdjustMode`: `.timeZone`, `.shift`, `.specific`, `.file`
- `DateTimeAdjustScope`: `.single`, `.selection`, `.folder`
- `DateTimeTargetTag`: `.dateTimeOriginal`, `.dateTimeDigitized`, `.dateTimeModified`
- `SourceTimeBasis`:
  - `.fixedUTC`
  - `.ianaTimeZone(String)`
  - `.useEmbeddedOffsetWhenAvailable(fallback: String)`
- `DateTimeAdjustSession`:
  - mode, scope, source basis, closest city, target timezone, shift components, adjusted date, applyTo set.
- `DateTimeAdjustPreviewRow`:
  - file URL, original display, adjusted display, delta text, status, warnings.
- `DateTimeAdjustAssessment`:
  - rows, blocking issues, non-blocking warnings.

## UI Plan
## 1. New sheet view
Create `DateTimeAdjustSheetView.swift` using `WorkflowSheetContainer`.

Top area:
- Title: `Adjust Date and Time`
- Subtitle changes by mode/scope:
  - Time zone: `Changing N selected files to a new time zone`
  - Shift: `Changing N selected files by set amount`
  - Specific: `Changing N selected files to a specific date and time`
  - File: `Changing N selected files to the file creation date and time`

Controls:
- Segmented mode control (`Time Zone`, `Shift`, `Specific`, `File`).
- `Original` row: disabled `InspectorDatePickerField`.
- `Adjusted` row: editable `InspectorDatePickerField`.
- `Closest City` row: `WorkflowCityComboField` (Time Zone mode only).
- `Time Zone` row: read-only secondary text (Time Zone mode only).
- `Offset` row: stepper fields for days/hours/mins/secs (Shift mode only).
- `Apply to` row: checkboxes `Original`, `Digitised`, `Modified`.

Footer:
- `Preview…` (popover).
- `Cancel`.
- `Adjust` (disabled on blocking issues/no-op state as appropriate).

## 2. Mode-specific visibility
- `Time Zone`: show `Closest City`, `Time Zone`.
- `Shift`: show `Offset`.
- `Specific`: no city/timezone/offset rows.
- `File`: no city/timezone/offset rows.

## 3. Apply-to defaults
On sheet open:
- Always pre-check launch tag.
- If `DateTimeOriginal` and `CreateDate` are effectively in sync across scope, pre-check both.
- If materially diverged, only pre-check launch tag.
- `ModifyDate` checked by default only if launched from `Date Time` field.

## Preview Plan (Batch Rename Parity)
Mirror pattern in `BatchRenameSheetView.swift`:
- state:
  - `showPreview`
  - `previewRows`
  - `previewIssues`
  - `isLoadingPreview`
- lazy load when preview opens first time.
- refresh on relevant parameter changes.

Popover content order:
1. Loading `ProgressView`
2. Blocking issues (red text)
3. Empty/no changes message
4. Monospaced scroll rows:
  - `filename  original -> adjusted  delta  tags`
  - `.font(.system(.caption, design: .monospaced))`

Apply button rule:
- Disabled if blocking issues exist.

## Apply Logic
## Canonical result rule
For each file:
1. Compute target timestamp for `DateTimeOriginal` according to mode.
2. For each checked target tag, write that same final timestamp string.

This enforces synchronization across selected tags.

## Mode semantics
- `Time Zone`: DST-aware conversion using source basis and target IANA timezone.
- `Shift`: simple signed delta by days/hours/mins/secs.
- `Specific`: set to explicit chosen local date/time.
- `File`: derive from file creation date/time.

## ExifTool operations
Metadata write path stays through existing `EditOperation` pipeline.

For roadmap sync tools in same workflow family:
- Set file dates from metadata:
  - `-FileModifyDate<DateTimeOriginal`
  - `-FileCreateDate<DateTimeOriginal` (where supported)
- Set metadata from file dates:
  - `-DateTimeOriginal<FileCreateDate`
- Missing-only `CreateDate` backfill:
  - `-if "not $CreateDate" -CreateDate<FileCreateDate`

## Timezone/City Resolution
- `Closest City` stores/displays city choice, resolves to IANA timezone ID.
- Use local dataset/service for city lookup, with resolver output as timezone ID.
- Conversion engine uses timezone IDs (`Europe/Amsterdam`) and `Calendar/TimeZone` DST rules.

## Inspector Integration
Update `InspectorView.swift` date rows:
- Replace current inline editing pattern for datetime fields with value display + `Set` button launch.
- `Set` opens Date/Time sheet and passes launch context tag (`ModifyDate`/`CreateDate`/`DateTimeOriginal`).

## File-by-file Worklist
SharedUI:
- `Sources/SharedUI/Workflow/WorkflowSheetComponents.swift`
  - optional row helpers.
- `Sources/SharedUI/Workflow/WorkflowCityComboField.swift` (new)

Ledger:
- `Sources/Ledger/DateTimeAdjustSheetView.swift` (new)
- `Sources/Ledger/AppModel.swift`
  - published sheet/session state.
- `Sources/Ledger/AppModel+Actions.swift`
  - open/close sheet actions.
- `Sources/Ledger/AppModel+Editing.swift` or new `AppModel+DateTimeAdjust.swift`
  - preview/apply compute logic.
- `Sources/Ledger/InspectorView.swift`
  - launch hooks from `Set` buttons.

Docs:
- Update `docs/Roadmap.md` checkboxes when shipped.

## Validation Matrix
Functional:
- Single, selection, folder scopes.
- Each of 4 modes.
- All apply-to checkbox combinations.
- Secondary tag sync correctness.
- File mode copy correctness.

Timezone/DST:
- Pre/post DST boundary samples.
- Fixed UTC source vs IANA source behavior differences.
- Missing-offset metadata with explicit source basis.

Safety:
- Preview rows match apply outputs.
- Backup/restore works.
- No-op operations are surfaced cleanly.

UX:
- Monospaced popover formatting.
- Disabled states on invalid inputs.
- Keyboard navigation and VoiceOver labels.

Performance:
- Preview on large folder scope remains responsive (batched reads).

## Delivery Sequence
1. SharedUI city combo wrapper.
2. Ledger data model + preview engine.
3. Sheet view with mode visibility.
4. Preview popover integration.
5. Apply pipeline wiring.
6. Inspector launch integration.
7. Roadmap sync actions in same workflow family.
8. QA matrix run + documentation update.
