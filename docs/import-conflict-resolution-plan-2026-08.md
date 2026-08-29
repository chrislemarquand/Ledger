# Import Conflict Resolution — Revisit Plan

## Status

A first implementation of this roadmap item (`ImportConflictResolutionSheetView`) was built, shipped, then **deliberately reverted** on 2026-08-29, same day, after the user asked to strip it back out and revisit the whole area more thoroughly later. This document is that "revisit later" reference: what exists today, what was built and why it was pulled, the structural problem the build surfaced, and a recommended way to approach it properly next time.

Today's actual behavior (post-revert, matching pre-2026-08-29): any unresolved `ImportConflict` blocks the **entire** import batch — including rows that matched cleanly — behind one blocking `NSAlert`:

> "N conflicts need resolution. Conflict resolution will be available in a future update."

(`ImportSheetView.swift`, `ImportSession.performImport(model:)` — search for `"Import needs conflict resolution."`)

## What already exists and was NOT touched by the revert

The backend for real conflict resolution is fully built, tested, and correct — it was never the problem:

- `ImportConflict` / `ImportConflictResolutionChoice` (`.skip` / `.target(URL)`) — `Sources/Ledger/Import/ImportModels.swift`.
- `ImportMatcher.match(...)` — `Sources/Ledger/Import/ImportMatcher.swift` — produces `.missingTarget`, `.multipleTargets`, `.duplicateSourceIdentifier` conflicts with real `candidateTargets` where available.
- `ImportConflictResolver.resolve(matchResult:resolutions:)` — `Sources/Ledger/Import/ImportConflictResolver.swift` — takes a real `[UUID: ImportConflictResolutionChoice]` dictionary, merges resolved assignments correctly, warns on collisions. Already covered by `ImportSystemTests` (`testConflictResolverResolvedConflictOverwritesMatchedFieldWithWarning`, `testMatcherFlagsDuplicateSourceIdentifiersAsConflicts`, etc.).
- `ImportSheetView.performImport(model:)` already calls `coordinator.resolveAssignments(preparedRun:resolutions:)` — it just always passes `[:]`, so nothing is ever pre-resolved. This is a **one-line integration gap in the UI layer**, not a backend gap.

Whoever picks this up next does not need to touch the matcher or resolver — only the UI layer, and only after resolving the structural question below.

## The structural finding that should shape the redesign

While building the sheet, tracing through every import adapter's matching logic surfaced a real, load-bearing fact: **no current import path can produce a `.multipleTargets` conflict, or a `.duplicateSourceIdentifier` conflict with more than one real resolution option.** This isn't a gap in the UI — it's true at the data layer, verified across all five adapters:

- **CSV** (`CSVImportAdapter.effectiveMatchingStrategy`): the moment *any single row's* filename fails to map to exactly one target file, the adapter abandons filename matching for the **entire file** and falls back to row-order matching instead (with just an info-level warning). So a duplicate or ambiguous filename never survives to reach `ImportMatcher`'s per-row conflict logic — it's silently reinterpreted as "match everything by position" instead.
- **EOS-1V**: row-order assignment is strictly sequential (`outputRowNumber`/`parityMappedCount` increment by exactly 1 per row) — duplicate row numbers structurally cannot occur.
- **GPX** and **Reference Image**: both iterate `context.targetFiles` directly and emit `.direct(fileURL)` selectors pointing at a URL already known to exist in scope. They cannot produce `.missingTarget`, `.multipleTargets`, or `.duplicateSourceIdentifier` at all — no conflicts are structurally possible from these two sources.
- **Reference Folder**: one row per file actually found in the reference directory, each filename appearing exactly once by construction — duplicates can't arise.
- **`.multipleTargets` additionally requires two files with the identical filename in the *target* folder** — the filesystem itself won't allow that in one directory (case-insensitive, case-preserving on default macOS volumes). This kind will only become reachable once multi-folder/hierarchical scope exists (see v2.0 relevance, below).

**Practical consequence**: `.missingTarget` (a CSV/reference row referencing a file that plain isn't in scope, or a row-order overflow) is the *only* conflict kind any real import can produce today, and by definition it has zero real candidates — there's nothing to "choose" for it, only skip. A conflict-resolution UI framed around "let the user pick between candidates" solves a problem that doesn't currently occur; the actual, currently-occurring problem is "let a `.missingTarget` row not block everyone else."

## What the reverted build looked like (for reference, not resurrection as-is)

`ImportConflictResolutionSheetView` (commit `781b337`, "Add import conflict-resolution sheet", reverted in the commit accompanying this document) was a second `WorkflowSheetContainer` sheet presented after Import is clicked, one row per conflict:

- 0 candidates → plain "Skip — no matching file" text, no control (a dropdown/checkbox with nothing to choose reads as broken UI — this was itself a fix mid-build, worth keeping if revisited).
- 1 candidate → a checkbox ("Use "filename"").
- 2+ candidates → a real dropdown, `InspectorPopupField`-style (see the layout note below), plus "Skip".
- A "Skip All Remaining" bulk action.
- A details popover (`WorkflowDetailsPopover`) showing the row's field values.

Given the finding above, **only the 0-candidate branch was ever exercised by a real import** — the checkbox and dropdown branches were verified exclusively via a fabricated `#Preview`, never a real end-to-end scenario. That asymmetry (most of the UI's complexity serving a case that can't happen) is itself part of why this is worth rethinking rather than just re-adding the same sheet.

**Layout lessons worth carrying forward** (relearned the hard way this session, on the sibling `EOSLensChoiceSheetView`, but equally applicable here): `WorkflowFormRow`'s default `labelAlignment` is `.trailing`, not `.leading` — check against a real design reference (this session used a Figma "Adjust Date and Time" frame) before assuming a row looks right. A row element only reliably shares a right edge with another row/footer element by pinning both to one identical, literal `.frame(width:)` constant — not by hoping SwiftUI's flexible-size negotiation lines them up, and not by trying to match one element's fixed width to another's if their natural content sizes differ. Use `InspectorPopupField` (SharedUI, native `NSPopUpButton`-backed) for a native grey dropdown — a bare SwiftUI `Picker` renders with an accent-color tint by default, which doesn't match the rest of the app's chrome.

## Recommended approach next time

1. **Start from the data, not the UI.** Before designing any sheet, decide what should actually happen to `CSVImportAdapter`'s blanket fallback. Two real options:
   - Fix it to fall back **per-row** instead of for the whole file — i.e., rows that map uniquely still match by filename even if one other row in the same CSV is ambiguous. This is arguably the real bug (a good CSV with one bad row currently gets *all* of its rows silently reinterpreted as row-order matches, which can be a worse outcome than a per-row conflict prompt) and would make `.duplicateSourceIdentifier`/`.multipleTargets` genuinely reachable via CSV without any UI work yet existing.
   - Leave the fallback as-is and accept that `.missingTarget` is the only realistic target for a v1-scoped conflict UI — in which case, keep it *simple*: no dropdown/checkbox machinery, just a list of unresolvable rows and a way to proceed without them, no more than that.
2. **Re-examine relevance to v2.0.** `docs/v1.4-architecture-plan-2026-08.md`'s durability section already flags that `.multipleTargets` only becomes real once hierarchical/multi-folder browsing exists. If v2.0 is close enough on the horizon, it may be worth deferring the multi-candidate UI entirely until that data model exists, rather than building speculative UI for a case only reachable in a future architecture.
3. **If building the sheet regardless**, reuse the exact per-row control pattern above (0/1/2+ candidates → text/checkbox/dropdown) and the `EOSLensChoiceSheetView` layout technique (literal shared `contentWidth`, `InspectorPopupField`) rather than rediscovering both from scratch — but validate every branch against a **real** import scenario, not a fabricated `#Preview`, before considering it done.
4. **Reuse, don't rebuild, the backend.** `ImportMatcher`/`ImportConflictResolver`/`ImportConflict` need no changes for either path above (path 1 needs a small `CSVImportAdapter.effectiveMatchingStrategy` change; the resolver already accepts row-level resolutions correctly either way).
