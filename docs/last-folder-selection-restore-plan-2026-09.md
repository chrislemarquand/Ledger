# Last Folder + Selection Restore — Plan — 2026-09-25

Implementation plan for reopening the last-viewed folder and file selection
on a clean app launch. Tracked in v1.4 (`docs/ROADMAP.md`, Native UI
Consistency & Polish) as UI/UX continuity, not a new feature — the app
already restores window frame, split position, and column widths via
macOS Secure State Restoration; this extends the same "resume where you
left off" stance to the folder/selection, which currently always starts
empty. Rationale and precedent (HIG's "Launching" guidance, Notes.app as
a comparator, the app's own existing restoration stance) were established
in conversation before this plan; not repeated here.

Plan only — no code changed.

## Scope

In scope:
- Persist the last-selected sidebar item (folder, favorite, mounted
  volume, Pictures/Desktop/Downloads) across launches.
- Persist the last file selection within that folder, restored once the
  folder has actually loaded.
- Graceful degradation when the persisted folder or files no longer exist.

Out of scope (explicitly not doing):
- Persisting or restoring `pendingEditsByFile`/staged changes — these are
  in-memory only today and never survive quit regardless (`hasUnsavedEdits`
  gates quit via `confirmDiscardUnsavedChanges`, `LedgerApp.swift:288-`).
  Nothing here changes that; restoring "what you were looking at" is
  independent of "what you'd changed but not applied."
- Restoring scroll position, view mode, or sort within the restored
  folder — those aren't currently session-scoped state, and adding them
  would be new scope beyond "reopen the last thing."
- EOS-1V device sessions (`.eos1vDevice` kind) — device state isn't
  filesystem-backed and doesn't fit this model; excluded explicitly below.

## Current relevant state (verified against code, not assumed)

- `AppModel.SidebarKind` (`AppModel.swift:270-278`): `.pictures`,
  `.desktop`, `.downloads`, `.eos1vDevice`, `.mountedVolume(URL)`,
  `.favorite(URL)`, `.folder(URL)`.
- `selectedSidebarID: String?` and `selectedFileURLs: Set<URL>`
  (`AppModel.swift:493`) are the live selection state; no persistence
  exists for either today (confirmed: no `didSet`/`UserDefaults` write
  site for `selectedSidebarID`, unlike e.g. `browserSort`/`galleryGridLevel`
  which do have `didSet` persistence at `AppModel.swift:483-509`).
- `selectSidebar(id:)` (`AppModel+Navigation.swift:127-153`) is the single
  correct entry point for "make this sidebar item the active one and load
  it" — sets `hasHadExplicitSidebarSelection = true`, handles the
  no-selection and `.eos1vDevice` cases via `cancelFileLoad()`, and calls
  `startLoadingFiles(for:)` (today's v1.4 fix — see
  `docs/v1.4-progress.md`'s Phase 6 review-fix section for its full
  cancellation/generation-token behaviour).
- `isPrivacySensitiveSidebarKind(_:)` (`AppModel+Sidebar.swift:390-398`)
  returns `true` for `.desktop`/`.downloads` and any file-system URL under
  `isPrivacySensitiveFileSystemURL` — these are deliberately gated behind
  `hasHadExplicitSidebarSelection` elsewhere (e.g.
  `ensureSidebarImageCount`, `AppModel+FileLoading.swift:29-33`) so the app
  never silently touches them before the user has explicitly interacted
  with the sidebar this session.
- `setSelectionFromList(_:focusedURL:)` (`AppModel+Editing.swift:803`) is
  the existing API for "set selection to this subset, with this primary
  item" — already used for exactly the "restore a selection but only the
  subset of URLs that still exist" pattern in
  `AppModel+ApplyRestore.swift:604-612` (`restoredOriginalURLs.intersection(availableURLs)`).
- `reconcileAndLoadRecentLocations()`/`reconcileAndLoadFavorites()` run at
  the end of `AppModel.init` (`AppModel.swift:858-860`), followed by
  `sidebarItems = composedSidebarItems()` — so `sidebarItems` is fully
  populated before `AppModel.init` returns.
- `RecentLocationsStore`/`SidebarFavoritesStore` (`AppModel.swift:151`,
  `:207`) are the existing file-backed persistence pattern for sidebar
  data; simple scalar preferences (e.g. `browserSort`, `galleryGridLevel`)
  instead use direct `UserDefaults.standard` reads/writes with a
  `didSet` and a static key constant (`AppModel.swift:483-509`,
  `:773-`).
- `LedgerApp.swift`'s `applicationDidFinishLaunching` (`:129-`) constructs
  `AppModel()`, then `MainWindowController`, injects menus, calls
  `windowController.showWindow(nil)`, then — only after that —
  `model.openFolder(at:)` if `-openFolderPath` was passed
  (`:167-169`). `isStateRestorationDisabled()`
  (`:234-236`, gated by `-disableStateRestoration`) already exists and
  gates AppKit's own window-state restoration
  (`applicationShouldRestoreApplicationState`, `:247`) — the same flag
  should gate this new restoration too, for the same reason (Phase 6
  re-baselining found secure state restoration racing against
  `-openFolderPath` non-deterministically triggering real work during
  benchmark runs; see `docs/v1.4-progress.md`'s Phase 6 section).
- `isFolderNotFoundError`-driven pruning (`AppModel+FileLoading.swift`,
  inside `performFileLoad`) already handles "the persisted folder no
  longer exists" gracefully — removes the stale sidebar/recents entry and
  shows a status message, not an alert. This exact path already fires for
  ordinary Recents-list clicks on a missing folder; a restored last-folder
  attempt goes through the identical `startLoadingFiles`/`performFileLoad`
  call, so no new missing-folder handling needs to be written — it already
  exists.
- Mounted-volume case: `isReachableDirectory(_:)`
  (`AppModel+FileLoading.swift:714`) is the existing check used elsewhere
  (`handleWorkspaceVolumeChange`) to detect a disconnected source before
  attempting to load it.

## Design

### What to persist

Two new `UserDefaults.standard` values, following the existing scalar-
preference pattern (`didSet` + static key, `AppModel.swift:483-509`
style) rather than the heavier `RecentLocationsStore`/file-backed pattern
— this is single-value session state, not a list:

1. `lastSessionSidebarKind` — an encoded form of `SidebarKind` sufficient
   to re-resolve a sidebar item: kind case name + URL where applicable
   (`.folder`/`.favorite`/`.mountedVolume` all carry a `URL`;
   `.pictures`/`.desktop`/`.downloads` carry nothing). A small `Codable`
   struct (e.g. `case: String, path: String?`) is simplest — avoid adding
   `Codable` conformance to `SidebarKind` itself if that has other
   implications; a narrow persistence-only struct is lower risk.
2. `lastSessionSelectedFilePaths` — `[String]` (file paths within the
   restored folder), written whenever `selectedFileURLs` changes while a
   non-privacy-sensitive, non-device folder is active (mirroring the
   existing `didSet`-persistence pattern; gate the write itself on
   privacy-sensitivity, not just the restore-read, so a Desktop/Downloads
   selection is never written to `UserDefaults` in the first place).

Write site: piggyback on the existing `selectedSidebarID`/
`selectedFileURLs` mutation points rather than adding new observers
everywhere — `didSet` on both properties is the natural, minimal-diff
choice, matching how `browserSort`/`galleryGridLevel` already do this.

### What to restore, and when

Add a new `AppModel` method, e.g. `restoreLastSessionSelectionIfAvailable()`,
called once from `LedgerApp.swift`'s `applicationDidFinishLaunching`, in
the same place `-openFolderPath` handling already lives (`:167-169`) —
mutually exclusive with it (an explicit launch-argument folder always
wins), and gated by the same `isStateRestorationDisabled()` check AppKit's
own window restoration already uses:

```swift
if let openFolderPath = Self.openFolderPathFromLaunchArguments() {
    model.openFolder(at: URL(fileURLWithPath: openFolderPath))
} else if !Self.isStateRestorationDisabled() {
    model.restoreLastSessionSelectionIfAvailable()
}
```

Inside `restoreLastSessionSelectionIfAvailable()`:

1. Decode the persisted `SidebarKind`. If none stored, return (first
   launch / never-persisted case — no-op, matches today's behaviour
   exactly).
2. **Respect the existing privacy gate**: if the decoded kind is
   privacy-sensitive (`isPrivacySensitiveSidebarKind`) and
   `hasHadExplicitSidebarSelection` is (necessarily, at launch) `false`,
   do not restore it. This is a deliberate design call — the alternative
   (auto-selecting Desktop/Downloads on every launch) would silently
   bypass a gate that exists specifically to require explicit user intent
   before touching those locations. Recommendation: skip restoring in
   this case (launch with no selection, same as today) rather than
   weakening the gate. Confirm this call with the user before
   implementing — it's the one place this feature could regress an
   existing, deliberate privacy decision.
3. Resolve the persisted kind against the current `sidebarItems`
   (already populated by this point in `AppModel.init`, which has already
   run by the time `applicationDidFinishLaunching` reaches this call). For
   `.mountedVolume`, additionally check `isReachableDirectory` — if the
   volume isn't currently mounted, skip restoring silently (not an error
   state; matches how a disconnected volume simply isn't in
   `sidebarItems` after `refreshSidebarItems`, so it likely won't match
   anyway — this check is defensive, not load-bearing).
4. If a match is found, call `selectSidebar(id:)` — reuses all existing
   load/cancellation/privacy machinery, no new folder-loading code needed.
5. **Selection restore happens after the load completes, not before.**
   `selectSidebar` doesn't currently return a signal for "the load I just
   started finished" in a form this call site can await cleanly (it calls
   `startLoadingFiles`, fire-and-forget). Two options:
   - (a) Use `startLoadingFiles`'s returned `Task<Bool, Never>` directly
     here — `restoreLastSessionSelectionIfAvailable()` becomes `async`,
     calls a variant that returns the task, awaits it, and on `true`
     restores the selection subset via `setSelectionFromList` (matching
     `AppModel+ApplyRestore.swift`'s existing pattern exactly:
     `persistedSelection.intersection(Set(browserItems.map(\.url)))`).
   - (b) Observe `$browserItems` for the first publish after calling
     `selectSidebar`, then apply selection.
   
   (a) is simpler and reuses more existing machinery (the `Bool`-returning
   `loadFiles`/`startLoadingFiles` API is exactly today's v1.4 fix, built
   for precisely this "know when a load actually completed" need) —
   recommended over (b).
6. If the persisted selection doesn't intersect the loaded
   `browserItems` at all (every previously-selected file is gone), leave
   selection empty — no error, no status message. This is a quiet,
   expected outcome, not a failure to surface.

### Edge cases (the two the user raised, plus what's already covered)

- **Persisted folder deleted/unreachable**: already handled by
  `performFileLoad`'s existing `isFolderNotFoundError` pruning — no new
  code. The restored `selectSidebar(id:)` call goes through the identical
  path as a normal Recents click.
- **Persisted files within an existing folder deleted/moved**: handled by
  intersecting the persisted selection against `browserItems` post-load
  (step 6 above) — same idiom already proven in
  `AppModel+ApplyRestore.swift`.
- **Staged/unsaved changes**: not a real edge case — `pendingEditsByFile`
  is in-memory only and never reaches `UserDefaults`; quit already
  requires it to be empty or explicitly discarded. Nothing to restore or
  guard against.
- **Mounted volume unmounted since last launch**: covered by step 3's
  `isReachableDirectory` check plus the natural absence from
  `sidebarItems` after `refreshSidebarItems` — degrades to "no selection,"
  not an error.
- **Privacy-sensitive last folder (Desktop/Downloads)**: covered by step
  2 — deliberately not restored automatically; flagged above as the one
  design call worth explicit confirmation before implementing.
- **`-openFolderPath`/UI-test and benchmark launches**: already excluded
  via the `else if` structure above and `isStateRestorationDisabled()`,
  matching the existing pattern for AppKit's own window-state restoration
  and avoiding the exact class of benchmark-isolation contamination
  Phase 2.1/2.3 already hit once this project (see
  `feedback_ledger_benchmark_pref_contamination` — check all of a demand
  gate's real-preference inputs, not just the ones a past incident
  named).

## Testing

Unit-testable without real launch-argument plumbing, following this
session's established pattern of injecting seams for hermetic tests
(e.g. `CloudDownloadTracker`'s injected closures,
`beginDateTimeAdjust`'s injected `readCreationDates`):

- Persisted-folder-missing → graceful degradation (reuses existing
  `isFolderNotFoundError` test coverage if any exists; add one exercising
  the restore path specifically if not).
- Persisted-selection-partially-gone → only surviving URLs restored,
  matching `AppModel+ApplyRestore.swift`'s existing test style for the
  intersection pattern.
- Privacy-sensitive persisted kind → not restored without explicit
  selection.
- Mounted-volume-not-reachable → not restored, no crash.
- `-openFolderPath` present → restoration skipped entirely (existing
  launch-arg wins).
- `-disableStateRestoration` present → restoration skipped (matches
  AppKit's own window-restoration gating).

Manual verification (add to `docs/v1.4-manual-smoke-checklist-2026-09.md`
once implemented, likely as a new §11 or folded into §2's existing
quit/relaunch item): open a folder, select a few files, quit, relaunch —
folder and selection reopen. Delete a selected file, relaunch — it's
silently dropped from the restored selection. Rename/move the folder
itself, relaunch — matches existing Recents-missing-folder behaviour
(status message, entry pruned). Select Desktop, quit, relaunch — does
*not* auto-restore (per the step-2 design call).

## Open question for the user before implementation

Step 2's privacy-gate call (skip restoring Desktop/Downloads
automatically) is a real product decision, not just an implementation
detail — confirm before writing code, since it's the one place this
feature intersects a deliberate existing privacy stance rather than pure
mechanical plumbing.
