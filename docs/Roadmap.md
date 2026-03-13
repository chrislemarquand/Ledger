# ROADMAP

Current baseline: **v1.1**.

This file is the active forward roadmap.
Historical pre-v1 detail remains in `ROADMAPOLD.MD`.

---

## v1.0.1 (Patch) — Stability + Trust

Released: **2026-03-04**.

- [x] **Inspector map sustained CPU** (~10% at idle): live `MKMapView` display link ran unconditionally; replaced with `MKMapSnapshotter` static snapshot. Fixed post-1.0.0.
- [x] Folder-switch render parity across sort modes (`B43`): fixed mismatch where `Date/Size/Kind` transitions could flash/reorder differently from `Name`. Browser switch is now atomic and preserves visible content until replacement is ready.
- [x] Locked-file preflight/reporting (`B42` / `R22`): preflight check on `FileAttributeKey.immutable` and `.isWritableKey` before apply; locked files reported with targeted message rather than silently written through.
- [x] `pendingCommitsByFile` cleared on metadata reload success (inspector can show stale applied values if a subsequent apply partially fails).
- [x] `Task.isCancelled` checks after `Task.sleep` in deferred async tasks (metadata prefetch, preview preload — cancellation is currently swallowed by `try?`, body runs regardless).
- [x] `NumberFormatter`/`DateFormatter` instances promoted to static properties where currently allocated per-call.
- [x] Sidebar context menu improvements: label polish (Unpin, Move Up/Down) and Remove action for recents and pinned folders; removing the selected folder reverts to no-selection state.

---

## v1.1 (Minor) — Import System Completion + Settings

Released: **2026-03-10**.

### General UX
- [x] Status bar message audit: review all status messages for necessity; promote any that warrant it to modal dialogs.
- [x] UI/UX polish: settings pane layout and sizes.

### Inspector Groundwork (prerequisite for Settings)
- [x] `inspectorRefreshRevision`: eliminate the duplicate `@State` copy in `InspectorView`; model's `@Published` value is now the single source of truth.
- [x] Edit-session snapshots: moved `editSessionSnapshots` out of `InspectorView` `@State` and into `AppModel` so edit-in-progress state is model-owned.
- [x] `groupedEditableTags`: migrated from tuple-array to dictionary-based grouping (with stable ordered section projection for UI consumers).

### Import
- [x] Unified import framework and shared UI flow for:
  - [x] CSV
  - [x] GPX
  - [x] Reference Folder
  - [x] EOS-1V CSV
- [x] Single import flow: load source -> match/preview/conflicts -> target scope (selection/folder) -> apply.
- [x] EOS-1V ingest parity in Swift (mapping/normalization/matching semantics from existing EOS-1V tool).
- [x] EOS-1V lens-tag resolver architecture: remove hardcoded lens inference and route through a policy layer that can read future Settings defaults plus per-import overrides.
- [x] Import sheet preview/stage parity hardening + structured import report output.
- [x] **Reference-based metadata apply**: select one image as reference, apply chosen metadata fields to a selection. Uses ExifTool `-tagsFromFile`. Sheet UI: select reference file → choose field groups → preview diff → confirm.

### Settings
- [x] Inspector field visibility controls.
- [x] Backup enable/disable controls with menu/context behavior alignment.
- [x] Clear recent folders action (handled via existing context-menu remove flow).

### Export
- [x] ExifTool CSV export feature.
- [x] Send to Photos handoff workflow.
- [x] Send to Lightroom Classic handoff workflow.

---

## v1.2 (Minor) — Editing Productivity

Completing the core "do things to metadata" toolkit.

- [ ] Batch Rename (first release).
- [ ] Rename hardening:
  - [ ] Collision handling.
  - [ ] Preview determinism.
  - [ ] Undo/recovery safety.
- [ ] Add more Exif fields to Inspector view (including rating).
- [ ] **Timestamp sync tools**: "Set file date from DateTimeOriginal" and "Set DateTimeOriginal from file date". Preview + confirm dialog, batch-safe with backup support.
- [ ] **ExifTool-native DateTimeDigitized backfill**: optional post-import/apply pass that fills missing `EXIF:CreateDate` from `FileCreateDate` only (no app-side date parsing, no overwrite of existing values).
- [ ] Metadata copy/paste:
  - [ ] Field-level copy/paste.
  - [ ] Metadata-set copy/paste.

---

## v1.3 (Minor) — Native Workflow UX + Customisation

Navigation, drag/drop, and letting users shape the interface.

- [ ] Drag files out to Finder/Mail/Messages etc. (NSItemProvider/NSPasteboardWriter on gallery/list items).
- [ ] Drag a folder onto the sidebar to add as a favourite.
- [ ] Drag to reorder sidebar favourites.
- [ ] Explicit Home/End/Page Up/Page Down keyboard nav in list/gallery.
- [ ] Finder-style breadcrumb bar.
- [ ] Dock icon badge and right click options
- [ ] List column customisation (including Exif-backed columns).
- [ ] Gallery metadata lines/subtitle customisation.
- [ ] Toolbar customisation.
- [ ] **Backup retention policy**: keep-last-N model, persistence, prune path wiring, and Settings UI controls. Infrastructure (`BackupManager.pruneOperations`) already exists; this is the Settings surface and wiring.

---

## v1.4 (Minor) — Metadata Quality

Deeper inspection, quality checking, and raw-file workflows.

- [ ] **Audit/validation mode**: surfaces missing/inconsistent metadata (missing DateTimeOriginal, missing GPS, missing copyright, conflicting IPTC/XMP). Inspector "Issues" section with one-click fixes where safe.
- [ ] **Sidecar management**: XMP sidecar create/rebuild/apply; browser badges for sidecar-exists and sidecar-differs-from-embedded states.
- [ ] Inspector clear-field control: optional trailing `x.circle.fill` action per field for staged-clear UX.
- [ ] ExifTool console: live readout of ExifTool commands and output as operations run, mirroring what would appear if running ExifTool directly in the terminal.

---

## v1.5 (Minor) — Search

Making the collection queryable.

- [ ] Metadata-aware query model.
- [ ] Search UI integration.
- [ ] Search persistence/history (scope permitting).

---

## v1.6 (Minor) — Performance + Infrastructure

Hardening the foundation before the v2.0 architecture rewrite.

- [ ] Large-folder performance pass (1000+ images).
- [ ] Render/browse pipeline optimisation.
- [ ] Thumbnail cache TTL / age-based eviction (currently LRU only; cross-folder sessions accumulate stale entries).
- [ ] Inspector preview cache size cap (currently trimmed by URL list only; large folders cache all previews with no memory ceiling).
- [ ] **Full native QuickLook rewrite**: replace current preview implementation with a fully native QuickLook integration.
- [ ] AppKit groundwork (named prerequisite tasks for v2.0 gallery/sidebar rewrite — to be decomposed into specific items before v1.6 planning).

---

## v2.0 (Major) — Gallery Rewrite + Power User Features

Major architecture overhaul and its true dependents.

- [ ] Major gallery/browser architecture rewrite (AppKit-shell-first, Mondrian-inspired).
- [ ] Sidebar rewritten in AppKit.
- [ ] Click-to-drag rubber-band selection in list and gallery views (depends on gallery rewrite).
- [ ] **Finder-style gallery view**: filmstrip along bottom, large preview at top — third browser mode alongside list and grid (depends on gallery rewrite).
- [ ] **Import conflict-resolution UI**: dedicated conflict workspace for unresolved/ambiguous import rows with per-row target choice, side-by-side field diff, and bulk resolve actions.
- [ ] **EOS-1V lens-tag policy system**: merges resolver enhancements and policy controls into one mature feature. Policy modes (`Do not write lens` / `Single lens for import` / `Focal-length mapping table`), unknown focal length behaviour, named lens profiles, import-sheet override selector. *Explicit prerequisite for v3.0.*
- [ ] **Metadata export CSV/JSON**: select fields, export to CSV or JSON for spreadsheet editing or audit reporting.

---

## v3.0 (Major) — Direct EOS-1V Ingest (CSV Transport)

Depends on the v2.0 EOS-1V lens-tag policy system being mature.

- [ ] Connect to EOS-1V and retrieve native shooting-data CSV directly.
- [ ] Feed retrieved CSV into Ledger import pipeline for normal preview/match/apply.
- [ ] Research-first reverse-engineering path:
  - [ ] Prioritise macOS 9 driver analysis.
  - [ ] Use Windows XP driver as validation/fallback.
- [ ] Ship clean Swift behavioural reimplementation only.
