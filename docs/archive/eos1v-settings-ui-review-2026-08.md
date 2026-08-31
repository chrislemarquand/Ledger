# EOS-1V settings UI: AppKit conventions, native-API usage, and Figma fidelity (2026-08-30)

A review of the Personal Functions / Custom Functions / Properties / Shooting
Data tabs built for the EOS-1V device screen
(`Sources/Ledger/EOS1V/EOS1VPersonalFunctionsViewController.swift`,
`EOS1VCustomFunctionsViewController.swift`, `EOS1VPropertiesViewController.swift`,
`EOS1VShootingViewController.swift`, `EOS1VSettingsControlFactory.swift`),
written for a developer to critique — not a self-assessment to be taken at
face value.

Design reference: two Figma frames in the `Ledger — EOS-1V` file.

- Personal Functions: <https://www.figma.com/design/4dtLVt8iqHLr6b8R1x4LOy/Ledger---EOS-1V?node-id=50-12397>
- Shooting Data: <https://www.figma.com/design/4dtLVt8iqHLr6b8R1x4LOy/Ledger---EOS-1V?node-id=47-885>

Related docs: `EOS1V_UI_HANDOVER.md` (repo root, the earlier abandoned attempt
and its two regressions), `docs/eos1v-serial-capability-audit-2026-08.md`
(what's actually read/write-capable on the Python side).

## AppKit conventions

Everything here is plain, native AppKit — no custom-drawn controls, no
third-party UI libraries, and (deliberately) no SwiftUI, even though the rest
of Ledger uses SwiftUI in leaf-view islands. The whole EOS-1V device screen
was built pure-AppKit from the start, and this work kept that consistent
rather than introducing a second paradigm partway through one screen.

- **Tab bars are `NSSegmentedControl`**, both the outer Connect/Personal/
  Custom/Shooting/Properties bar and each tab's inner category bar
  (Exposure/AF/Film Transport/Other, etc.). This is the standard macOS
  pattern for a small, fixed set of mutually-exclusive views — matches what
  System Settings, Xcode's own preference panes, and the Figma design all
  do. No custom tab-button view was written.
- **Settings controls are stock `NSButton` checkbox/radio styles and
  `NSPopUpButton`**, built through small factory functions in
  `EOS1VSettingsControlFactory.swift` (`checkbox(title:checked:)`,
  `radio(title:selected:)`, `popUp(items:selectedIndex:)`). Every one is
  `isEnabled = false` today — read-only — but is otherwise the exact same
  control macOS would show if it were interactive. This was a deliberate
  requirement (see the earlier planning conversation): lay out the writable
  UI now, flip `isEnabled` later, rather than build a bespoke read-only
  presentation that would need re-doing.
- **Lists are `NSTableView`** (the Shooting Data roll table, the frame
  preview list) — not a hand-rolled `NSStackView` of rows. Multi-selection
  uses the table's own `allowsMultipleSelection`, not custom hit-testing.
- **Grouping uses `NSBox`** in custom-box mode for the per-function "card"
  styling the Figma design calls for, rather than drawing a border with a
  `CALayer` or a SwiftUI-style rounded rectangle. This is the native AppKit
  primitive for exactly this purpose.
- **The frame preview is a native sheet** (`presentAsSheet(_:)` on
  `EOS1VFramePreviewViewController`), not a popover or a hand-built overlay
  window. This was an explicit decision to keep the same AppKit-only
  approach as the rest of the screen while still matching the *visual*
  weight of Ledger's other sheets (e.g. `ImportSheetView.swift`, which is
  SwiftUI `.sheet` from a SwiftUI host) — `presentAsSheet` produces the same
  system sheet chrome without mixing SwiftUI into an otherwise pure-AppKit
  screen.
- **Disabled state, not hidden state.** Every not-yet-writable control is
  shown and disabled (`isEnabled = false`), never hidden or omitted. This is
  the standard AppKit/macOS convention for "this exists, you can't use it
  yet" versus SwiftUI's more common pattern of conditionally not rendering
  a view at all.

**Where this got non-trivial, and worth scrutiny:** three real AppKit-layout
bugs surfaced during review and needed fixing, all instructive about the
edges of composing `NSStackView`/`NSScrollView`/`NSBox` programmatically:

1. `NSBox.contentView` sizes its content via the legacy autoresizing-mask
   model, which fights Auto-Layout/`NSStackView`-based content — every card
   rendered as an overlapping, garbled mess until `groupBoxCard(_:)` was
   rewritten to `addSubview` + explicit constraints instead of using
   `contentView` at all.
2. A plain (non-flipped) `NSView` as an `NSScrollView`'s document view opens
   scrolled to the *bottom* of the content, not the top, because `(0,0)` is
   its bottom-left corner. Fixed with a one-line flipped `NSView` subclass.
3. `refresh()` can run — building and hiding/showing all of a tab's content
   — before that tab's view has ever been attached to the real window (if
   the camera session settles before the user has clicked into it). Laying
   out a detached, zero-sized view hierarchy is a no-op; the fix re-triggers
   the visible-category logic from `viewWillAppear()`, the one point
   guaranteed to have real window geometry to lay out against.

None of these are exotic — they're well-known AppKit gotchas — but they took
three iterations to actually land, which a reviewer should read as a signal
that this screen's layout code is more fragile than idiomatic
Auto-Layout-via-Interface-Builder/SwiftUI would be, purely because it's all
hand-written programmatic constraints.

## Simple, native API usage

- No dependencies were added. Everything is `AppKit`/`Foundation` (plus
  `UniformTypeIdentifiers` for the CSV export panel's content type).
- `EOS1VPersonalFunctionParsing.swift` — the logic that turns a Personal
  Function's `value`/`choiceHints` strings into "is this a toggle, a
  disable-list, a single-choice, or a range" — is pure functions with no
  AppKit dependency at all, independently testable, and the single place
  that decision is made (the view controller just switches on the result).
- The CSV export (`EOS1VRollCSVExporter.swift`) is a pure function over
  plain structs, writing `Data` — no `Codable`/`NSCoding` machinery, no
  third-party CSV library, just string formatting matching a real Canon
  export byte-for-byte.
- The deleted-roll tombstone (`EOS1VDeletedRollsStore.swift`) is a single
  small `Codable` `Set<String>` written to one JSON file — no Core Data, no
  SQLite, no new persistence framework for what's a short list of IDs.

**Worth scrutiny:** `EOS1VPersonalFunctionsViewController` and
`EOS1VCustomFunctionsViewController` are near-duplicates of each other —
same category-tab-bar-plus-scrollable-cards `loadView()`, same
`showCategory(_:)`/`viewWillAppear()` pair, differing mainly in which
settings dictionary and category-number tables they use. That duplication
was accepted rather than factored into a shared base class or generic
component, on the theory that Custom is C.Fn-only and Personal is P.Fn-only
and they're unlikely to diverge much further before writing is added — but
a reviewer may reasonably disagree and ask for a shared
`EOS1VCategoryTabViewController` base.

The Shooting tab's `deleteButton.title == "Restore"` check (used to decide
whether a click means delete or restore) is a state-in-a-string-comparison
hack rather than a proper enum/bool — small, but the kind of thing worth
flagging rather than leaving quiet.

## Figma fidelity

Matches:

- Outer segmented tab bar, and each settings tab's inner category segmented
  bar, now **centered** under the outer bar (this took a follow-up fix —
  the first pass left it leading-aligned).
- Per-function **group-box cards** for Personal and Custom Functions,
  matching the Figma card treatment (after the `NSBox.contentView` fix
  above — the first attempt at this looked nothing like the design due to
  that bug).
- **Combination tab dropped** from both Personal and Custom Functions,
  matching the Personal Functions frame (which has no fifth "Combination"
  segment) — confirmed with you as an intentional simplification rather
  than an oversight, since it's a save/load/apply-settings-file view and
  none of that is reachable from Ledger yet per the capability audit.
- **Shooting Data as a flat, multi-select roll table** with Preview/Delete/
  Export actions below it, matching the Shooting Data frame's layout —
  replacing the original two-pane roll-list-plus-always-visible-frame-list
  design that predated the Figma review.

Deliberate deviations from the Figma frames, each discussed and confirmed
rather than assumed:

- **Shooting table columns** are Film ID / Loaded Date / Loaded Time /
  Frames / ISO (DX), not the four unlabeled placeholder "Label" columns in
  the frame — those four data points are what `eos1v-serial`'s own CSV
  actually carries; the manual's Title/Remarks columns have no data source
  in Ledger at all.
- **Delete… is local-only.** The frame shows a destructive red button with
  no stated scope; per the capability audit `eos1v-serial` has no selective
  per-roll delete and the machine interface rejects `erase-all` outright.
  Delete now hides a roll from Ledger's own list (a tombstone file), mirrors
  how the original Canon software worked, and never touches the camera or
  the downloaded files — with a "Show Deleted" toggle to reverse it. This
  is a materially different feature from what the button alone implies, and
  is the single largest scope addition beyond "match the picture."
- **Preview…** has no equivalent in the manual and wasn't specified beyond
  "show the frame list, sheet-style" — implemented as a native AppKit sheet
  over the existing frame-list table, per the discussion above.
- The **P.Fn-2 card content in the Figma mockup itself** doesn't match the
  manual (it lists shooting-mode options, not metering-mode options, and
  appears to be a copy-paste artifact from the P.Fn-1 card next to it).
  Ledger was built against the manual's actual P.Fn-2 definition
  (evaluative/partial/spot/centerweighted metering), not the mockup's
  content, on the assumption the mockup has a bug — worth the designer
  double-checking against the frame directly.

## Suggested focus for review

1. Whether the `NSBox`/flipped-view/`viewWillAppear` fixes above are the
   right long-term fix or papering over a structural issue in how tab
   content is built lazily-but-not-quite (`refresh()` rebuilds from scratch
   on every session change, including tabs not currently visible).
2. Whether the Personal/Custom controller duplication should be unified now
   or left until a third consumer of the same pattern appears.
3. Whether Delete's local-only, tombstone-based semantics are communicated
   clearly enough in the UI itself (currently just a button labeled
   "Delete…"/"Restore" and a "Show Deleted" checkbox) versus needing an
   explicit "this only affects this app" affordance, given how easily it
   could be misread as an on-camera action.
