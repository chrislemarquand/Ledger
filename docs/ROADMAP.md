# ROADMAP

Current baseline: **v1.3**. Now: **v1.4**.

This file is the active forward roadmap.
Full detail for shipped work (every pre-v1.0 backlog item, and every item in
v1.0.1 through v1.2.3) has moved to `docs/ROADMAPOLD.MD` — also captured,
release by release, in `CHANGELOG.md`. v1.3's full item-by-item detail is still
inline below (not yet migrated to `docs/ROADMAPOLD.MD`) — see `CHANGELOG.md` for the
user-facing summary.

---

## Shipped: v1.0.1 – v1.3

Summary only — full item-by-item detail in `docs/ROADMAPOLD.MD` and `CHANGELOG.md`
(v1.3 detail is still inline below, not yet migrated).

- **v1.0.1** (Patch, 2026-03-04) — Stability + Trust: inspector map CPU fix, folder-switch render parity, locked-file preflight/reporting, misc cleanup.
- **v1.1** (2026-03-10) — Import System Completion + Settings: unified import framework (CSV/GPX/Reference Folder/EOS-1V), reference-based metadata apply, inspector/settings groundwork, ExifTool CSV export, Photos/Lightroom Classic handoff.
- **v1.2** — Batch Rename first release, expanded inspector metadata coverage, Finder-style breadcrumb bar, AppKit sidebar rewrite, full native QuickLook rewrite, thumbnail pipeline rewrite, Date/Time + Location adjust workflows, performance streamlining Phases 1-3.
- **v1.2.3** (Patch) — macOS Golden Gate Readiness: macOS 27/Xcode 27 compatibility pass (geocoder migration, SharedUI concurrency fix, apply/restore capture-semantics fix).
- **v1.3** (2026-08-31) — Import Maturity + Polish: EOS-1V lens-tag policy system (named lens profiles, ambiguous-lens picker, unknown-focal-length prompt), direct EOS-1V camera connection over the ES-E1 cable, iCloud Drive file-state UI, Finder-style Gallery view, gallery subtitle customisation, metadata copy/paste, ExifTool console, bundled ExifTool bumped to 13.55.

---

## v1.3 — Import Maturity + Polish

### Import

- [x] **EOS-1V lens-tag policy system**: originally scoped as policy modes + unknown-focal-length handling + named lens profiles + override selector. Decision 2026-08-29: the `Do not write lens`/`Single lens for import` policy modes are **not being pursued** — the EOS-1V CSV is a source of truth and this feature is just interpreting it into accurate EXIF values; if a resolved lens is wrong for a given frame, editing it after import is trivial, so a dedicated policy switch isn't worth the complexity. Scope narrowed to just the registry (done) and the picker UI (done):
  - [x] **Named lens profiles**: `LensProfile` registry (`LensProfiles.swift`) replacing the hardcoded embedded CSV (`EOSLensMappingEmbedded.swift`, now unused at runtime — reference copy at `~/Desktop/eos-lens-mapping-reference.csv`, safe to delete once manually re-entered lenses are confirmed complete). Editable via Settings → General → "Manage Lenses…" (bridging to SwiftUI via `NSHostingController` + `presentAsSheet`), Prime/Zoom radio toggle, per-lens focal range + aperture(s). `applyEOSLensPolicy`'s matching now sources from `AppModel.lensProfiles` instead of the embedded table.
  - [x] **Ambiguous-lens picker → one sheet**: `EOSLensChoiceSheetView` replaces the old loop of blocking `NSAlert`s (`ImportSession.chooseLens`, removed). One sheet lists every ambiguous frame at once (filename, focal length, frame aperture, a native grey `InspectorPopupField` dropdown per row), grouped by focal length with a live-linked "Apply to all at this focal length" checkbox per group. A frame left on "Leave Blank" now just skips that one field — the rest of the batch still stages, unlike the old alert's full-abort cancel.
  - [x] **Unknown focal length behaviour** (no registered lens covers a row's focal length): one aggregated "No Registered Lens Matches" alert per import (not a popup per file), listing every affected focal length and total frame count. "Manage Lenses…" (default) opens the lens registry sheet and automatically retries matching on close; "Continue Without Lens Tags" skips the `exif-lens` field for just those focal lengths, remembered only in-memory for the current import (`ImportSession.unknownFocalLengthsAcknowledged`, never persisted); "Cancel Import" aborts. Distinct from the ambiguous-lens picker above (multiple candidates) — this is zero candidates.

### EOS-1V Direct Connection

- [x] **Direct EOS-1V connection over the ES-E1 cable** (unplanned addition, built 2026-08-29–31 — previously scoped and cancelled, see the removed Cancelled-section entries this superseded): a new sidebar device entry with Connect / Shooting Data / Date and Time tabs, backed by `eos1v-serial`'s versioned `machine` JSON subprocess interface (`EOS1VSessionController`, `EOS1VToolClient`).
  - [x] Connect: wake/search/download flow with live status.
  - [x] Shooting Data: flat multi-select roll table, roll detail sheet (SwiftUI `Table`, one column per frame field), local-only delete/restore (tombstone — never touches the camera or downloaded files, see `EOS1VDeletedRollsStore`).
  - [x] Canon-format CSV export verified byte-for-byte against real Windows XP ES-E1 exports (`EOS1VRollCSVExporter`) — Tv-field escaping and recorded-items-mask column inclusion both fixed to match.
  - [x] Date and Time tab: frozen camera-clock-vs-macOS-clock comparison snapshot (not live-ticking).
  - Personal/Custom Functions screens were built (real controls, matching the ES-E1 Remote manual) but are hidden for now — not part of this release's scope; code and data plumbing stay intact for future reactivation.
  - Camera clock **write** capability exists end-to-end (`eos1v-serial`'s reviewed `set-clock` operation, `EOS1VSessionController.writeClock`, `EOS1VSetClockSheetView`) but is disabled pending a real-hardware wake-failure diagnosis — see `docs/eos1v-set-clock-review-2026-08.md`.
  - Future editable roll-metadata layer (Title/Remarks, per-field overrides, a second enriched CSV export) parked — see the v2.0+ entry and `docs/eos1v-roll-metadata-plan-2026-08.md`.

### Browse

- [x] **iCloud Drive file-state UI**: make it obvious in list/gallery/inspector when a file is a cloud placeholder rather than downloaded locally (evicted/dataless items currently look like a thumbnail/metadata loading failure — exiftool reads time out silently and previews stall while fileproviderd materialises multi-hundred-MB scans). Detect via `URLResourceValues` (`isUbiquitousItem` / `ubiquitousItemDownloadingStatus`) and badge undownloaded items with an iCloud symbol using SharedUI's `makeGalleryOverlaySymbol` (`Gallery/GalleryOverlay.swift`), in the style of Librarian's shared-library `person.2.fill` grid badge. Consider a download affordance/progress and skipping exiftool reads until files are materialised.
- [x] **Finder-style gallery view**: filmstrip along bottom, large preview at top — third browser mode alongside list and grid.
- [x] Gallery metadata lines/subtitle customisation.

### Metadata

- [x] Metadata copy/paste:
  - [x] Field-level copy/paste.
  - [x] Metadata-set copy/paste.
- [x] ExifTool console: live readout of ExifTool commands and output as operations run, mirroring what would appear if running ExifTool directly in the terminal.

### Maintenance

- [x] Bump bundled ExifTool from 13.50 to 13.55 (2026-08-31). Homebrew's formula tops out at 13.55 as of this date — exiftool.org's own latest is 13.59, but that would mean vendoring a binary downloaded directly from exiftool.org instead of through Homebrew, so scope narrowed to what's available via the package manager. Includes the 13.53/13.54 security updates. Revisit once Homebrew's formula catches up to 13.59 for the Exif 3.1 spec tags (13.56) and Canon/Nikon/Sony lens improvements.
- [x] No-op batch rename: suppress the staged/applied state when a rename pattern produces no changes (filenames unchanged); keep the rename sheet open and explain that no names would change.

---

## v1.4 — Performance + Native Foundations (Pre-2.0)

No new user-facing features. v1.4 is a measured performance, efficiency, and
native-macOS-quality pass before the v2.0 browser rewrite. The full sequence,
benchmark method, safety rules, and acceptance gates are in
`docs/v1.4-performance-audit-plan.md`; supporting diagnoses remain in the
documents referenced there.

### Responsiveness

- [ ] **Establish the performance baseline**: add a proportionate Release-build benchmark harness, stable signposts, focused UI automation, and repeatable cold/warm browser journeys. The 1,000+ file corpus remains a bounded regression gate, not a revived open-ended optimisation project.
- [ ] **Keep interaction paths non-blocking**: remove synchronous thumbnail disk access and image decode from browser/preview UI paths; investigate hangs and hitches across launch, scrolling, selection, view switching, menus, and live resize.
- [ ] **Narrow browser rendering**: update only the active browser surface, stop hidden controllers and hosted SwiftUI roots rebuilding, and reduce broad publication where traces show meaningful fan-out.

### Data + Resource Efficiency

- [ ] **Make metadata and preview loading demand-driven**: prioritise selected and visible content, cancel obsolete work on folder/window lifecycle changes, avoid speculative iCloud materialisation, and ensure Ledger becomes quiet after foreground work settles.
- [ ] **Bound retained state and caches**: add measured lifetime/eviction policies for session metadata and the thumbnail disk cache; verify stable memory across extended folder navigation and under memory pressure.
- [ ] **Reduce ExifTool process cost**: batch reads and writes where justified while preserving per-file results, backups, restore, timeout, and cancellation behaviour.
- [ ] **Reduce shipping payload**: audit the bundled ExifTool distribution, re-export the oversized EOS-1V body asset, and record before/after app-bundle composition.

### Native macOS Foundations

- [ ] **Own the menu bar from launch**: build the static AppKit menu hierarchy before hosted UI or the first window, retain responder-chain validation for dynamic state, and remove timing/reinjection workarounds. Detailed diagnosis: `docs/menu-bar-architecture-audit-2026-08.md`.
- [ ] **Unify window and list persistence**: prefer AppKit's native window, split-view, and table-column autosave mechanisms; remove competing persistence and layout feedback loops. Detailed diagnosis: `docs/window-list-resize-diagnosis-2026-07.md`. Includes the long-standing List view bug (spotted again in v1.3 smoke testing, 2026-08-31) where column widths never reliably persist/restore.
- [x] **[Done, v1.4 Phase 4.3, 2026-09-02 — resolved opposite to this item's original framing]** Selection-highlight consistency across Icon/List/Gallery (spotted in v1.3 smoke testing, 2026-08-31). The original framing above (List should be brought in line with Icon/Gallery's forced-accent behaviour) turned out to be backwards once actually investigated: List's plain `NSTableView.selectionHighlightStyle = .regular` dimming to grey off first-responder is genuine, correct, native AppKit behaviour (matches Photos.app, confirmed via live AX-focus instrumentation) — it isn't a bug. The real fix was the opposite: found and removed the focus-stealing mechanism that caused List's accent-flash-on-click glitch (unrelated to the dim/accent question itself), then brought Icon/Gallery's `GallerySelectionAppearanceObserver`-driven selection into line with List by making it first-responder-aware too (previously it only checked window-key/app-active state, never first responder, so it never dimmed on focus loss the way List correctly does). See `docs/v1.4-progress.md`'s Phase 4.3 detail sections for the full investigation (sidebar scroll-snap, accent-flash root cause, and the selection-consistency fix) and `SharedUI/docs/Roadmap.md`'s matching entry.
- [ ] **Complete the coordinated SharedUI audit**: review macOS 26 chrome workarounds on macOS 26 and 27, retaining only those with current evidence; keep SharedUI-owned implementation work tracked in SharedUI `docs/Roadmap.md`.

### Native UI Consistency & Polish

(Added 2026-09-03. Not new features — a consistency/polish pass across
existing UI, in the same "strip out hacks, prefer native" spirit as the
SharedUI chrome-workaround audit above. Work through one item at a time,
verified live before moving to the next. Full root-cause detail, exact
code patterns, and a "how to repeat this on Librarian" section for every
item below live in `docs/ui-consistency-polish-2026-09.md` — this list
stays to one-paragraph summaries only.)

- [x] **[Done/native, 2026-09-03]** Accent colour consistency ("accent" vs "accent vibrant"): confirmed only one accent colour is specified anywhere (`NSColor.controlAccentColor`, which resolves to Ledger's own `Assets.xcassets/AccentColor` teal within the app's process via the app-level accent-colour mechanism recent macOS added — verified directly: a standalone process reading `controlAccentColor` gets plain system blue, but Ledger's own process gets the asset-catalog teal). The perceived difference (sampled precisely from two screenshots: sidebar highlight RGB (106,192,180) vs list-row highlight RGB (78,153,142)) is entirely explained by AppKit's own two built-in selection-highlight styles: the sidebar's `NSOutlineView` uses `.style = .sourceList` (`AppKitSidebarController.swift`), the browser list's `NSTableView` uses `.selectionHighlightStyle = .regular` (`SharedBrowserListViewController.swift`) — the same native distinction Finder/Mail/Notes have between sidebar and content-list selection. Nothing to change; already the simplest native implementation.
- [x] **[Done, 2026-09-03]** User-facing text pass against HIG + `docs/USER_FACING_COPY_GUIDELINES.md`. Two sub-passes:
  - **Empty-state subtitle punctuation**: established the macOS convention (title = short phrase, no punctuation; subtitle = complete sentence, always ends with a period — confirmed against Safari's own "Website Not Allowed" pattern). Inventoried all `PlaceholderView`/`BrowserPlaceholderView` title+subtitle pairs; fixed the 3 missing periods (`InspectorView.swift`: "Downloading…", "Not Downloaded", "No Selection" subtitles). The rest were already correct.
  - **App-wide HIG assessment** (menus, alerts, buttons, sheet titles, status text, tooltips, settings labels — full inventory + analysis in this conversation, not duplicated here): found and fixed 9 concrete issues — 3 alerts converted to inline/status text where there was no real decision to make (`AppModel+FileLoading.swift` folder-not-found, `BatchRenameSheetView.swift` no-op rename now disables the button + shows inline text instead of an alert, `MainContentView.swift` export-scope alert now uses an `NSSegmentedControl` accessory instead of 3 overloaded alert buttons); alert title wording/capitalization normalized to sentence-case statements or questions across `AppModel+ApplyRestore.swift`/`LedgerApp.swift`/`ImportUI/ImportSheetView.swift`; "exiftool" → "ExifTool" capitalization fixed; a partial-failure Trash result now also raises a follow-up alert, not just a status message; straight apostrophe in "What's New" fixed to curly; "Clear Changes"/"Clear Backups…" renamed to "Discard Changes"/"Delete Backups…" for verb consistency with the destructive-action convention used elsewhere. Verified: full build + 226-test suite pass, batch-rename fix confirmed live.
- [x] **[Done, 2026-09-03]** Sheet layout/consistency audit: 8 of 10 sheets already shared one component (`WorkflowSheetContainer` in SharedUI — consistent title font, 20pt padding, header spacing). Found and fixed 2 outliers: `PresetEditorSheet`/`PresetManagerSheet` (`PresetSheets.swift`) hand-rolled their own layout instead of reusing the container — migrated both to `WorkflowSheetContainer`, which also fixed a real sizing divergence (`PresetManagerSheet` was `minWidth: 480` vs. Lens's fixed `width: 480`, now both fixed-width) and renamed "New Preset…" to "New…" to match its own sibling buttons ("Edit…"/"Duplicate"/"Delete") and Lens's naming. Also fixed `EOS1VRollDetailSheetView`'s title font (`.title2.bold()` → the standard `.title3.weight(.semibold)` used everywhere else) — that one's layout otherwise legitimately differs (960pt read-only data table, single Close button) so wasn't migrated to the container. Cancel/default-action button ordering and outer padding were already consistent across all ten sheets. Verified live (Manage Presets sheet) and via full build + 226-test suite.
- [x] **[Done, 2026-09-03 — second pass, live-verified]** Button colour consistency (grey vs accent). A first pass was incorrectly marked done without live verification; the user caught three real problems, all now fixed and confirmed with real screenshots (pixel-cropped) rather than code-reading alone. HIG rule (user-provided, verbatim): "a primary button uses an app's accent color, whereas a destructive button uses the system red color" — a sheet's default/primary button gets prominent accent, a destructive button gets prominent *red*, everything else stays plain bordered grey.
  1. **Destructive buttons weren't red** — `role: .destructive` alone does not get the red-filled prominent treatment in this SwiftUI/macOS version; it needs an explicit `.tint(.red)` alongside `.buttonStyle(.borderedProminent)`. Fixed on both in-sheet Delete buttons (`LensProfileSheets.swift`, `PresetSheets.swift`) — confirmed red live in both the Lenses and Presets manager sheets.
  2. **Root cause found for the faint-teal plain buttons**: `InspectorView.swift` and `MainContentView.swift` both applied an ambient `.tint(AppTheme.accentColor)` — `.tint()` in SwiftUI bleeds into plain `.bordered` buttons' text/fill, not just `.borderedProminent` ones, so every sheet chained after that modifier (Set Location, Date/Time Adjust, Manage Presets, Preset Editor) had its Cancel/Fields…/Preview… buttons tinted teal instead of neutral grey. Removed both `.tint()` call sites entirely — the app's own per-process accent-colour mechanism (confirmed earlier: `NSColor.controlAccentColor`/`Color.accentColor` already resolve to Ledger's asset-catalog teal within its own process, no explicit override needed) makes this redundant, not just wrong. Confirmed live: Set Location's Cancel/Fields…/Preview… are now true neutral grey, and Adjust still renders correctly accent-teal once enabled.
  3. **Live-verified (not just code-reviewed) 4 of the 8 primary buttons** via real screenshots across three different hosting contexts: Set Location's "Adjust" (descendant of the now-fixed tint chain), the Lens editor's "Save" (a completely separate standalone `NSHostingController`, unaffected by the tint bug), Batch Rename's "Rename", and Import-from-CSV's disabled "Import" state — all render correctly (accent-teal when enabled, grey when disabled). The remaining 4 (EOS-1V clock "Adjust", Lens-choice "Continue", Date/Time Adjust's "Adjust", Preset Editor's "Save") use the identical code pattern in contexts already covered by the fix and were not separately screenshotted, given the consistent result across the 4 that were checked.
  Full build + 226-test suite pass; Librarian (unaffected, doesn't share these files) also builds clean.
- [x] **[Done, 2026-09-03]** Ellipsis usage audit: HIG rule confirmed — a trailing "…" means the action needs *new information* from you before it completes (opens a dialog to fill in/choose something), not merely "this leads to more UI." A button that only opens a plain confirmation alert (yes/no on the same action, nothing new to provide) does not get one — e.g. "Delete" in the Presets/Lenses manager sheets was already correct with no ellipsis. Audited every ellipsis (and near-miss) in the app; found and fixed 2: **"Delete Backups…"** (Settings) opened only a confirmation alert exactly like "Delete" elsewhere — ellipsis removed. **"What's New in Ledger…"** opens a purely informational window with nothing to provide, the same category as "About Ledger" (no ellipsis) — ellipsis removed. Everything else checked out (every "New…"/"Edit…"/"Choose…"/"Manage Lenses…"/etc. genuinely gathers input; every other confirmation-only alert trigger already omits it). Verified via full build + 226-test suite.
- [x] **[Done, 2026-09-04]** Polish animations (SF Symbols effects): user identified the specific candidates — Inspector star rating, flag, Rotate, Flip, and Open buttons (colour-label menu deliberately excluded as unsuitable). Added `.symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value:)` to all five: `InspectorRatingFlagSymbolLabel` (SharedUI, shared by both the star row and the flag button) keys the effect on its own `symbolName` — which already changes exactly when a star/flag's fill state flips, so only the cells whose state actually changed bounce, not the whole row. `InspectorPreviewActionLabel` (Ledger, shared by Rotate/Flip/Open) has no naturally-changing bound value since these are momentary actions, so it uses a local `@State` counter incremented via `.onChange(of: isPressed)` when a press completes (transitions to `false`), and keys the effect on that. Verified via full build + 226-test suite; colour-label dropdown untouched.
- [ ] **Inspector field copy/clear icon visual-height mismatch**: root cause diagnosis unconfirmed — attempted 2026-09-03/04 (`InspectorTextField.ContainerView`, SharedUI: tried an image-baked `NSImage.SymbolConfiguration`, then a button-level `NSButton.symbolConfiguration`, at several point sizes) but no attempt produced a user-confirmed visible change, and live verification was unreliable (see `docs/ui-consistency-polish-2026-09.md` "Not done" section for the full account, including a broken relaunch loop that likely invalidated some of the in-session pixel measurements). Fully reverted — `InspectorTextField.swift` is back to its original state, confirmed via `git diff`. Needs a fresh diagnosis before trying again, ideally starting from a reliable way to relaunch/screenshot the app rather than repeating the same approach.

### Evidence-Gated Maintenance

- [ ] **Decompose only where the work requires it**: split `MainContentView.swift` and `AppModel` at existing ownership boundaries as measured changes land; remove confirmed dead/duplicated EOS-1V, lens-mapping, and CSV code without turning v1.4 into a general rewrite.
- [ ] **Optimise browser reloads only when measured**: preserve existing targeted updates, and adopt narrower or diffable collection updates only for proven costly paths.
- [ ] **Treat Observation as optional**: pilot `@Observable` only if invalidation evidence remains after render/publication fixes, and retain Combine wherever it is still the simpler AppKit bridge.
- [ ] **Close with like-for-like verification**: repeat the baseline across supported macOS versions and representative storage states, record rejected as well as accepted hypotheses, and require the main-thread, idle, cancellation, memory, and native-behaviour gates to pass.

---

## v2.0+ — A better Bridge

Directional, not committed — less specified than v1.3/v1.4 on purpose; expect this section to be re-scoped as it gets closer.

### Browse

- [ ] **Finder-style hierarchical browsing**: the core file-browser model, replacing today's flat folder-at-a-time navigation.
- [ ] **In-app image viewing**: a core workflow for Ledger-supported image formats, no external viewer needed.
- [ ] **HDR-aware rendering** (moved from v1.2.3, 2026-08-15): decode HDR/gain-map images via ImageIO `kCGImageSourceDecodeToHDR` (+ `kCGComputeHDRStats`); render inspector/grid previews with `NSImage.DynamicRange.constrainedHigh` (`NSImageView.preferredImageDynamicRange` / SwiftUI `allowedDynamicRange`) and the in-app viewer with `.high` on EDR displays. SDR files are unaffected (decode option is a no-op). Keep the JPEG thumbnail disk cache SDR; HDR applies to live decodes only.
- [ ] **Smart folders**: saved metadata-facet queries surfaced like regular folders.
- [ ] **Bridge-class search, filter, and sort**: across folders and metadata facets (type, rating, labels, keywords, and other attributes).
- [ ] **Drag a folder onto the sidebar**: to add as a favourite.
- [ ] **Keyboard navigation:** Explicit Home/End/Page Up/Page Down keyboard nav in list/gallery.
- [ ] **Drag files out**: to Finder/Mail/Messages etc. (`NSItemProvider`/`NSPasteboardWriter` on gallery/list items).
- [ ] **Toolbar customisation**
- [ ] **Reopen last folder on launch**: currently the app always launches with no folder selected — only window frame/split-position/column-width survive quit-and-relaunch via macOS Secure State Restoration; there's no folder-URL persistence anywhere in `AppModel`/`LedgerApp.swift`. Noted during the v1.4 manual smoke pass (2026-09-25), not a regression — just never implemented.

### Devices

- [ ] **Camera/SD card photo import**: a new "Devices" sidebar entry (alongside Canon EOS-1V, same section) for any connected camera or memory card, built on Apple's native `ImageCaptureCore` (`ICDeviceBrowser`/`ICCameraDevice` — the same framework Photos.app/Preview/Image Capture.app use), adopting the system's native photo-import UI/paradigm rather than a custom-built one. No existing groundwork — `ImageCaptureCore` isn't referenced anywhere in the codebase yet.

### Import

- [ ] **Import conflict-resolution, revisited**: a real UI for unresolved/ambiguous import rows, designed against how matching actually behaves rather than assumed. Full context, the structural finding from the 2026-08-29 attempt (no current adapter path can produce `.multipleTargets` or a multi-candidate `.duplicateSourceIdentifier`), and a recommended approach are in `docs/import-conflict-resolution-plan-2026-08.md`.

### EOS-1V

- [ ] **Roll metadata database**: a Ledger-owned overlay of user-editable info (starting with Title/Remarks, extensible to any field via per-roll/per-frame overrides) layered on top of the camera's immutable downloaded data, plus a second "Ledger-enriched" CSV export alongside the existing untouched-camera-data export. Full data model, file-by-file plan, and rationale (including why this isn't a database engine) in `docs/eos1v-roll-metadata-plan-2026-08.md`.
- [ ] **Seamless import pipeline:** rather than exporting a CSV then re-importing it, make the import pipeline for a folder of photos from an EOS-1V camera seamless, without the user having to export and import CSV files.
- [ ]  **Date/time write: u**sing the eos1v-serial script, write updated date/time to the camera via the ES-E1 cable.
- [ ] **Multiple camera gate:** if the data being downloaded from the camera doesn't match what Ledger already has, prompt the user. Need to decide the policy - overwrite or add to existing lens data stored.

### Metadata

- [ ] **Copy/paste field selector**: using the same UI/plumbing as preset sheets — "Copy selected fields…" pops up a window to pick fields, then paste applies only those.

### Export & Output

- [ ] **Print support**: batch output as PDF contact sheets     

---

## Parked

- [ ] **Audit/validation mode**: surfaces missing/inconsistent metadata (missing DateTimeOriginal, missing GPS, missing copyright, conflicting IPTC/XMP). Inspector "Issues" section with one-click fixes where safe.
- [ ] **Sidecar management**: XMP sidecar create/rebuild/apply; browser badges for sidecar-exists and sidecar-differs-from-embedded states.

-
