# Native UI Consistency & Polish — 2026-09-03

Companion detail doc for the "Native UI Consistency & Polish" section of
`docs/ROADMAP.md`'s v1.4 entry. The roadmap keeps one-paragraph summaries;
this doc has the full root-cause detail, the exact code patterns used, and
what went wrong on the first attempt at each fix — written so the same
audit can be run against **Librarian**, which shares `SharedUI` with Ledger
and is built from the same AppKit/SwiftUI conventions.

Not new features. This is a consistency/polish pass over existing UI,
prompted by the user spotting visual inconsistencies while using the app,
in the same "strip out hacks, prefer native" spirit as the SharedUI
chrome-workaround audit (Phase 4.3).

**Working method that mattered**: every fix in this doc was verified with
a real screenshot (and in the accent-colour cases, precise pixel sampling
via a small Python/PIL script) after implementation — not just by reading
the code. Two of these fixes were initially marked "done" after a
code-level review alone and were **wrong** in ways that were only visible
at runtime (see "Button colour consistency" below). Don't skip the
live-verification step when repeating this on Librarian.

---

## 1. HIG rules established this session

These are the actual rules applied below, distilled from Apple's Human
Interface Guidelines and (for #2) a direct quote the user supplied:

1. **Empty-state title/subtitle punctuation**: a title is a short phrase
   with no terminal punctuation ("No Selection"); a subtitle underneath it
   is a complete sentence and always ends with a period, whether it's a
   statement or an instruction ("Select one or more images to view and
   edit their metadata."). Confirmed against Safari's own empty-state
   pattern ("Website Not Allowed" / "“x” is a restricted website.").

2. **Button prominence** (user-supplied, verbatim from HIG): "a primary
   button uses an app's accent color, whereas a destructive button uses
   the system red color." Concretely:
   - A sheet's single default/primary action (the one bound to Return)
     gets `.buttonStyle(.borderedProminent)`. Nothing else in that sheet
     should be prominent.
   - A destructive action (Delete, etc.) gets prominent styling too, but
     **red**, not accent — see the gotcha in section 4 below, because
     `role: .destructive` alone does not produce this automatically.
   - A sheet with no single "primary decision" (a browse/manage sheet
     with peer actions like New/Edit/Duplicate/Delete/Done) correctly has
     **no** prominent button at all.

3. **Ellipsis usage**: `…` means "this needs new information from you
   before the action completes" (a dialog asking you to type/choose
   something) — not "this leads to more UI." A button that only opens a
   plain confirmation alert (yes/no on the *same* action, nothing new
   gathered) does not get one, even though it does trigger more UI.
   "Delete" → "Delete “X”? This action can't be undone." correctly has no
   ellipsis; "New…" → opens an editor sheet needing a name correctly does.
   A purely informational window (no input, e.g. "What's New") is treated
   like "About" — no ellipsis.

4. **Consistency over local correctness for verbs**: don't use different
   verbs for the same weight of action ("Clear Changes" vs "Discard
   Changes" vs "Quit and Discard" all meaning "abandon prepared edits");
   don't reuse a low-stakes verb ("Clear") for a higher-stakes one
   (permanently deleting files from disk).

---

## 2. Empty-state subtitle punctuation

**Finding**: `PlaceholderView`/`BrowserPlaceholderView` (SharedUI +
`BrowserContainerViewController.swift`) title+subtitle pairs were mostly
already correct, but three were missing their terminal period:

- `InspectorView.swift` — "Downloading…" / "Fetching this file from
  iCloud" → `.` added.
- `InspectorView.swift` — "Not Downloaded" / "This file hasn't been
  downloaded from iCloud yet" → `.` added.
- `InspectorView.swift` — "No Selection" / "Select one or more images to
  view and edit their metadata" → `.` added.

**To repeat on Librarian**: grep for `PlaceholderView(` call sites and
check every `description:`/subtitle string ends in `.` if it's a full
sentence. Titles should have none.

---

## 3. App-wide HIG text/alert assessment

A full inventory of menu items, alerts, buttons, sheet titles, status
text, tooltips, and settings labels was done by a research subagent, then
assessed against HIG. Concrete fixes made:

### 3a. Alerts converted to inline/status text (no real decision existed)

HIG: alerts are for situations requiring a *choice*. A single-OK alert
that only reports something the app already did, or a no-op validation
result, should be a status message or inline text instead.

- **`AppModel+FileLoading.swift`** — "“X” No Longer Available" alert
  (shown after the app had *already* removed the stale sidebar entry)
  replaced with a `statusMessage` assignment. No decision was ever being
  asked for.
- **`BatchRenameSheetView.swift`** — "No Names Would Change" alert
  (shown when a rename pattern is a no-op) replaced with:
  - a computed `hasNoChanges` property (`!preview.isEmpty &&
    previewIssues.isEmpty && preview.allSatisfy { source == target }`)
  - inline caption text ("The new filenames match the current
    filenames.") shown above the footer buttons when true
  - the Rename button's `.disabled(...)` extended to include
    `hasNoChanges`
  - the `isShowingNoChangesAlert` state and `.alert(...)` modifier deleted
    entirely.
- **`MainContentView.swift`, `pickExportScope(actionTitle:completion:)`**
  — the 3-button "Selection (n files)/Folder/Cancel" alert was a routine
  scope *picker*, not a warning, and HIG discourages using alert buttons
  as a stand-in for an options list. Replaced with an `NSAlert` whose
  `accessoryView` is an `NSSegmentedControl(labels: ["Selection (n)",
  "Folder"], trackingMode: .selectOne, ...)`, with just two real buttons
  (the action verb + Cancel). When there's also a pending-edits warning to
  show, it's folded into the same alert's `informativeText` rather than a
  separate alert. This also fixed a second problem in the same function
  (3b below).

### 3b. Alert title reused the raw command name instead of describing the situation

`MainContentView.swift`'s no-selection branch of `pickExportScope` used
`alert.messageText = actionTitle` (e.g. "Export ExifTool CSV") — reads
like a menu command, not a description of what's happening. Fixed as part
of the 3a rewrite: `messageText` is now always a real situational
statement ("You have unapplied changes." / "Choose which files to
include.").

### 3c. Alert title wording/capitalization normalized

Apple's own alerts use **sentence case + terminal punctuation** for the
title (a statement ending in `.`, or a question ending in `?`). Several
of Ledger's didn't:

- `AppModel+ApplyRestore.swift`, `confirmDiscardUnsavedChanges` — was
  `"You have unsaved changes."` (title) / `"Discard your prepared changes
  before X?"` (informative). Now: title = `"Discard your prepared
  changes?"`, informative = `"You have unsaved changes. They'll be lost
  if you continue X."` — title asks the actual question, informative
  states the consequence.
- `LedgerApp.swift`, quit-confirmation alert — same restructuring:
  title = `"Quit and discard your prepared changes?"`, informative =
  `"You have unsaved changes. They'll be lost if you quit now."`.
- `AppModel+ApplyRestore.swift` — `"Couldn't Apply Name Changes"` (Title
  Case) → `"Couldn't apply name changes."` (sentence case).
- `AppModel+ApplyRestore.swift` — `"Restore failed"` → `"Couldn't restore
  metadata."`.
- `MainContentView.swift` — `"Export Failed"` → `"Couldn't export."`.
- `ImportUI/ImportSheetView.swift` — two one-line alert titles
  (`"Couldn't prepare import."`, `"Import needs conflict resolution."`)
  had trailing periods inconsistent with the rest; dropped to match the
  sentence-fragment convention used elsewhere for one-liners.

### 3d. Partial failure of a confirmed destructive action escalated to an alert

`AppModel+ApplyRestore.swift`, backup-clearing — a **partial** failure of
the "Move all backups to Trash?" action the user just explicitly
confirmed now also raises a follow-up `NSAlert` ("N backups couldn't be
moved to Trash.") in addition to the existing status-bar message. Per
HIG, an unexpected/important result of a confirmed destructive action
merits an alert, not just a transient label easy to miss right after
dismissing the confirmation dialog.

### 3e. Small text/wording fixes

- `AppModel.swift` — `"Ledger requires exiftool"` → `"Ledger requires
  ExifTool."` (product name capitalization; the actual binary/executable
  reference in the informativeText below it stays lowercase since that's
  a literal filename, not the product name).
- `MainContentView+Menus.swift` — `"What's New in Ledger…"` — straight
  apostrophe `'` fixed to curly `'` (typographic apostrophes required in
  all user-facing text; this was the one inconsistent spot, everywhere
  else already used curly).
- `AppModel+Actions.swift` + `MainContentView+Menus.swift` (×2 sites) —
  `"Clear Changes"` / `"Clear Changes from Folder"` → `"Discard Changes"`
  / `"Discard Changes from Folder"`, to match the "Discard" verb used in
  the confirmation alerts (3c) rather than a third variant.
- `SettingsWindowController.swift` — `"Clear Backups…"` → `"Delete
  Backups"` (verb consistency with the destructive-action convention;
  ellipsis also removed, see section 5).

**To repeat on Librarian**: re-run the same inventory-then-assess process
— grep for `NSAlert()`, `.alert(...)`, and `NSMenuItem(title:`/`Button(`
call sites; check every alert's title against the sentence-case/question
convention above, and every verb for consistency with its siblings.

---

## 4. Button colour consistency (grey vs. accent vs. red)

This item was **marked done twice**. The first pass was code-review-only
and wrong in three ways the user caught live. Read this section in full
before repeating the pattern — the three gotchas below are not obvious
from reading SwiftUI documentation.

### 4a. What actually needed doing

Audited every `.keyboardShortcut(.defaultAction)` button in the app (the
sheet's Return-bound primary action) and added `.buttonStyle(.borderedProminent)`
to the ones that are a genuine sheet-level primary decision — excluding
local popover-only confirms (e.g. a field-selection popover's own
"Apply"/"Done", which isn't the *sheet's* primary decision):

| File | Button |
|---|---|
| `BatchRenameSheetView.swift` | "Rename" |
| `LensProfileSheets.swift` | "Save" (lens editor) |
| `DateTimeAdjustSheetView.swift` | "Adjust" (×2 — date/time sheet, location sheet) |
| `PresetSheets.swift` | "Save" (preset editor) |
| `EOS1V/EOS1VSetClockSheetView.swift` | "Adjust" |
| `ImportUI/EOSLensChoiceSheetView.swift` | "Continue" |
| `ImportUI/ImportSheetView.swift` | "Import"/"Close" (toggles) |

Manager/browse sheets (Presets, Lenses) correctly get **no** prominent
button — New/Edit/Duplicate/Delete/Done are peers, and Done is bound to
`.cancelAction`, not `.defaultAction`. Nothing to add there.

### 4b. Gotcha #1 — `role: .destructive` alone does not turn a button red

Adding `.buttonStyle(.borderedProminent)` to a `Button(..., role:
.destructive)` produces a **prominent button in the app's accent
colour**, not red, in this SwiftUI/macOS version. You must add an
explicit `.tint(.red)` alongside the style:

```swift
Button("Delete", role: .destructive) {
    pendingDeleteLensID = selectedLensID
}
.buttonStyle(.borderedProminent)
.tint(.red)                      // <- required; role alone isn't enough
.disabled(selectedProfile == nil)
```

Applied to both in-sheet Delete buttons: `LensProfileSheets.swift`,
`PresetSheets.swift`. (The `role: .destructive` buttons living inside
SwiftUI `.alert(...)` blocks did **not** need this — those are rendered
by the native alert machinery, which does correctly redden them
automatically. It's specifically `Button` styled with `.borderedProminent`
inside normal view content that needs the explicit tint.)

**Verify by screenshot, not assumption** — this exact wrong assumption
("role: .destructive must already do this") is what caused the first,
incorrect "done" marking.

### 4c. Gotcha #2 — an ambient `.tint()` bleeds into *plain* buttons too, not just prominent ones

The real bug behind "some buttons are grey, some are teal" turned out to
be nothing to do with the primary buttons at all. `InspectorView.swift`
and `MainContentView.swift` both applied:

```swift
.tint(AppTheme.accentColor)
```

to the whole Inspector view tree (once inside `InspectorView.swift`
chained onto a `.sheet(...)` call, once again wrapping the entire
`InspectorView` where it's hosted in `MainContentView.swift`). In
SwiftUI, `.tint()` is a broad environment value that affects **every**
control's default rendering underneath it — including a plain
`.bordered`/`.automatic` `Button`'s label colour — not just
`.borderedProminent` buttons as you'd expect from the name. The result:
every sheet presented from within that tree (Set Location, Date/Time
Adjust, Manage Presets, Preset Editor) had its **Cancel**, **Fields…**,
**Preview…** — every plain button — rendered with a faint teal tint
instead of true neutral grey.

**Fix**: delete both `.tint(AppTheme.accentColor)` call sites entirely.
This is safe, not just a hack-removal: Ledger's own `Assets.xcassets`
`AccentColor` is teal, and recent macOS versions make an app's own
`AccentColor` asset flow into `NSColor.controlAccentColor` /
`Color.accentColor` automatically **within that app's own process** (see
section 6 below for how this was confirmed) — so `.borderedProminent`
buttons still render correctly accent-teal with no explicit `.tint()`
needed anywhere. The ambient `.tint()` was pure redundant legacy code
that had gone actively harmful.

**To repeat on Librarian**: grep for `.tint(` across the app. Any
ambient/wide-scope use (applied to a whole view tree or window, not to
one specific control) is suspect — check every plain button inside that
tree for a colour tint it shouldn't have.

### 4d. Gotcha #3 — screenshot verification method

Live verification used real screenshots plus, for the ambiguous cases,
pixel sampling with a small inline Python/PIL script (crop the footer
button row, upscale 2×, read it back) rather than eyeballing a full
1:1-scale screenshot — the tint difference is subtle enough (RGB
(106,192,180) sidebar vs (78,153,142) list, in one investigation this
session) that eyeballing alone risks missing or misjudging it.

---

## 5. Ellipsis audit

Applying rule #3 from section 1, two violations were found and fixed:

- `SettingsWindowController.swift` — `"Delete Backups…"` opened only a
  plain confirmation alert (no new information gathered) — ellipsis
  removed, matching "Delete" in the Presets/Lenses manager sheets which
  were already correct.
- `MainContentView+Menus.swift` — `"What's New in Ledger…"` opens a
  purely informational window (nothing to provide) — same category as
  "About Ledger" (no ellipsis) — ellipsis removed.

Also confirmed: **no fake ellipses exist anywhere** — every `…` in the
codebase (whether written as a literal `…` character or a `\u{2026}`
escape) is the real Unicode ellipsis (U+2026), not three periods. Checked
via a Python script reading each matched string's actual codepoints, not
just a visual grep.

**To repeat on Librarian**: for every button/menu item ending in `…`, ask
"does this open something where I must type/choose/provide new
information, or does it just confirm/proceed?" — apply rule #3. Also spot
check for literal `...` (three periods) vs `…` (U+2026).

---

## 6. Accent colour investigation (no fix needed — recorded because the reasoning is reusable)

Original suspicion: two different accent-colour code paths (`AppTheme
.accentColor` reading `NSColor.controlAccentColor` vs. bare `Color
.accentColor`/`.accentColor` used directly in `TokenChip.swift`,
`NoticeBarView.swift`, `AppWelcomeViewController.swift`). Investigation
found these **do not actually diverge**:

- Ledger has a fixed teal in `Sources/Ledger/Assets.xcassets/AccentColor.colorset`
  (not "any"/system-passthrough).
- A **standalone** process reading `NSColor.controlAccentColor` gets
  plain system blue (confirmed directly: `swiftc` a one-line script,
  `print(NSColor.controlAccentColor...)` → `(0, 0.478, 1.0)`).
- Inside **Ledger's own running process**, the same API resolves to the
  asset-catalog teal — recent macOS versions let an app's own
  `AccentColor` asset flow into `NSColor.controlAccentColor`/`Color
  .accentColor` app-wide, for that app's process specifically.

So `AppTheme.accentColor` and the bare `Color.accentColor` uses agree by
construction; there is only one accent colour specified anywhere.

The user's *actual* observation (sidebar selection pill looking a
different shade of teal from a list row's selection pill) was real but
had nothing to do with colour specification — it's AppKit's own two
built-in selection-highlight styles rendering the *same* colour
differently:

- Sidebar: `AppKitSidebarController.swift` sets `outlineView.style =
  .sourceList`.
- Browser list: `SharedBrowserListViewController.swift` (SharedUI) sets
  `tableView.selectionHighlightStyle = .regular`.

Sampled precisely: sidebar highlight RGB (106,192,180) vs. list-row
highlight RGB (78,153,142) — different, but both derived from the same
one accent colour via two different native AppKit rendering styles.
Finder/Mail/Notes all have the same sidebar-vs-list distinction. Nothing
to change.

**To repeat on Librarian**: if the same complaint comes up, check
Librarian's asset catalog `AccentColor` and confirm the same "app process
resolves it automatically" behavior before assuming a code-level split.
Check what `selectionHighlightStyle`/`.style` each of Librarian's
`NSOutlineView`/`NSTableView` instances use — if the sidebar isn't
`.sourceList`, that's a separate, real thing to consider (out of scope
here, Librarian's sidebar behavior wasn't audited this session).

---

## 7. Sheet layout/consistency audit

**Finding**: 8 of 10 sheets in Ledger already share one component,
`WorkflowSheetContainer` (SharedUI, `Workflow/WorkflowSheetComponents.swift`)
— it standardizes title font (`.title3.weight(.semibold)`), an optional
subtitle (`.caption2`/`.tertiary`), 20pt outer padding, and
header-to-content spacing. Two sheets didn't use it:

- **`PresetSheets.swift`** (`PresetEditorSheet`, `PresetManagerSheet`) —
  hand-rolled their own `VStack`+`.padding(20)`+`.frame(...)` instead.
  Values happened to coincidentally match the shared container today, but
  any future container improvement would silently skip these two.
  Migrated both to `WorkflowSheetContainer`. This also fixed a real
  sizing divergence: `PresetManagerSheet` used `.frame(minWidth: 480,
  minHeight: 420)` (resizable) vs. the Lens equivalent's fixed `width:
  480` via the container — now both are fixed-width via the container.
  Also renamed `"New Preset…"` to `"New…"` to match its own sibling
  buttons ("Edit…"/"Duplicate"/"Delete", none of which repeat "Preset")
  and the Lens sheet's identical row.
- **`EOS1V/EOS1VRollDetailSheetView.swift`** — used `.title2.bold()`
  instead of the standard `.title3.weight(.semibold)`. This one's layout
  otherwise legitimately differs (a 960pt-wide read-only data table with
  a single "Close" button, not a form) so it wasn't migrated to the
  shared container — just the title font was normalized.

**Migration pattern** (see `PresetSheets.swift` git history for the full
diff): wrap the existing body content in
`WorkflowSheetContainer(title:, width:) { ... }`, delete the manual
`Text(title).font(.title3.weight(.semibold))` line, delete the outer
`.padding(20)` and `.frame(width:/minWidth:...)` (the container applies
its own).

**Separately found and fixed while touching `PresetEditorSheet` (not
originally part of this audit item — see section 8)**: its field-list
`ScrollView` only had `.frame(minHeight: 240)`, no `maxHeight`. Combined
with `WorkflowSheetContainer`'s `.fixedSize(horizontal: false, vertical:
true)`, the ScrollView reported its *full content height* as ideal size
instead of clipping/scrolling — the sheet ballooned past the screen
instead of scrolling. Fixed by adding a cap: `.frame(minHeight: 240,
maxHeight: 420)`. Confirmed via grep that this was the *only* ScrollView
in the app missing a bound — every other one is either inside a
`.popover` (sizes independently) or already had an explicit `maxHeight`
or fixed `.frame(width:height:)`.

**To repeat on Librarian**: grep for `WorkflowSheetContainer(` and
`ScrollView {` across Librarian's sheets. For every sheet *not* using the
container, decide whether it should be migrated (matching-conventional
form sheet) or is a legitimate exception (e.g. a wide data-table view).
For every bare `ScrollView` inside a sheet body (not a popover), check it
has a `maxHeight` — if it only has `minHeight` or no frame constraint at
all, it likely has the same overflow bug.

---

## 8. Rating / Flag / Colour Label controls in the Preset editor

**Finding** (user-reported, not part of the original audit): the Preset
editor asked for raw numeric/text values for Star Rating, Flag, and
Colour Label — the same three fields the Inspector renders as proper
star icons, a flag glyph, and a colour-swatch menu via
`InspectorRatingFlagView` (SharedUI, `Inspector/InspectorRatingFlagView.swift`).

**Data format** (confirmed from `InspectorView.swift`'s own usage, so the
preset editor writes *exactly* the same values the Inspector does):

- Rating: `Int` 0–5. Stored as `""` when 0, else `String(rating)`.
- Pick/Flag: `Int` -1/0/1 (rejected/none/picked). Stored as `""` when 0,
  else `String(pick)`.
- Colour Label: raw `String` — `""`, `"Red"`, `"Yellow"`, `"Green"`,
  `"Blue"`, or `"Purple"`.

**Fix**: in `PresetSheets.swift`'s `presetControl(for tag:)`, special-case
the three tag IDs (`AppModel.EditableTag.rating/.pick/.label`) *before*
the generic date/picker/text-field fallbacks, each rendering
`InspectorRatingFlagView` with only that one sub-control enabled (the
other two `...Enabled` flags `false`, with inert dummy values/callbacks
for them) — reusing the exact same component, symbols, and click targets
as the Inspector, while keeping the preset sheet's existing
one-row-per-tag layout (checkbox + label + control) untouched:

```swift
if tag.id == AppModel.EditableTag.rating.id {
    InspectorRatingFlagView(
        rating: Int(editor.valuesByTagID[tag.id] ?? "") ?? 0,
        ratingPending: false, ratingEnabled: true,
        onRatingChange: { updatePresetValue($0 == 0 ? "" : String($0), for: tag) },
        pick: 0, pickPending: false, pickEnabled: false, onPickChange: { _ in },
        label: "", labelPending: false, labelEnabled: false, onLabelChange: { _ in }
    )
    .padding(.horizontal, -InspectorMetrics.horizontalPadding)
} else if tag.id == AppModel.EditableTag.pick.id {
    // same shape, only pickEnabled: true
} else if tag.id == AppModel.EditableTag.label.id {
    // same shape, only labelEnabled: true
} else if model.isDateTimeTag(tag) {
    // ...existing branches unchanged
```

The `.padding(.horizontal, -InspectorMetrics.horizontalPadding)` cancels
out `InspectorRatingFlagView`'s own baked-in 16pt horizontal padding
(designed for the Inspector's own layout) so it sits flush in the preset
row like every other control does.

Writes through the existing `updatePresetValue(_:for:)` — same function,
same "auto-include if non-empty" behavior every other field already has.
Verified live: clicking a star fills it and auto-checks the row's
"include" checkbox, identically to typing into the old text field.

**To repeat on Librarian**: if Librarian has an equivalent preset/batch
metadata editor with raw rating/flag/label fields, check whether
`InspectorRatingFlagView` (already shared via SharedUI) can be reused the
same way — same three tag-ID special cases, same data format.

---

## 9. Not done this session (deliberately deferred)

- **Polish animations (SF Symbols effects)** — open-ended, needs specific
  flat-feeling moments identified before scoping.
- **Inspector field copy/clear icon visual-height mismatch** — attempted
  and reverted; the diagnosis below is unconfirmed, treat it as a
  starting hypothesis for whoever picks this up next, not an established
  cause. `InspectorTextField.ContainerView` (SharedUI) gives both the
  copy (`doc.on.doc`) and clear (`xmark.circle`) buttons an identical
  16×16 frame with `.scaleProportionallyDown` and no per-symbol
  configuration; the working theory was that `xmark.circle` (a disc that
  nearly fills its bounding box) and `doc.on.doc` (more inherent internal
  padding) render at different optical heights at the same nominal size.
  Two fixes were tried — an image-baked `NSImage.SymbolConfiguration`
  (had no effect: `NSButton.symbolConfiguration`, when set, overrides any
  configuration baked into the assigned `NSImage` — that part of the
  finding is a real, confirmed AppKit behavior worth keeping), then a
  button-level `copy.symbolConfiguration` at a few different point sizes
  — but no attempt produced a change the user could actually see in the
  running app. Live verification broke down over the same attempts:
  repeated `kill`+`open -a` relaunch cycles likely raced (killing the old
  process and reopening within half a second), so `open -a` may have
  reactivated the still-dying old build rather than launching the new
  one, meaning some of the in-session pixel measurements this doc
  originally cited may not have reflected the code actually being tested.
  **Fully reverted** — `InspectorTextField.swift` confirmed back to its
  original state via `git diff` (clean, no changes). Whoever picks this
  up again should start with a reliable build→relaunch→screenshot loop
  (e.g. waiting for full process exit, or launching the binary directly
  instead of `open -a`) before touching the symbol configuration again.
- **Librarian was not audited this session** — everything in this doc was
  found and fixed against Ledger only. Since `WorkflowSheetContainer`,
  `InspectorRatingFlagView`, `AppKitSidebarController`, and
  `SharedBrowserListViewController` all live in `SharedUI` and are
  presumably used by Librarian too, several of these findings (sections
  4c's ambient-`.tint()` bleed, section 7's ScrollView-height bug,
  section 5's ellipsis rule) are exactly the kind of thing worth grepping
  for in Librarian's own app-specific code, even though the shared
  components themselves weren't touched and shouldn't need fixing again.
