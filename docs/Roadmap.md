# ROADMAP

Current baseline: **v1.0.1**.

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

Primary objective: get import right end-to-end.

### General UX
- [ ] Status bar message audit: review all status messages for necessity; promote any that warrant it to modal dialogs.

### Inspector Groundwork (prerequisite for Settings)
- [ ] `inspectorRefreshRevision`: eliminate the duplicate `@State` copy in `InspectorView`; model's `@Published` value should be the single source of truth.
- [ ] Edit-session snapshots: move `editSessionSnapshots` out of `InspectorView` `@State` and into `AppModel` so edit-in-progress state is model-owned.
- [ ] `groupedEditableTags`: migrate from tuple-array to dictionary-based grouping.

### Import
- [ ] Unified import framework and shared UI flow for:
  - [ ] CSV
  - [ ] GPX
  - [ ] Reference Folder
  - [ ] EOS 1V CSV
- [ ] Single import flow: load source -> match/preview/conflicts -> target scope (selection/folder) -> apply.
- [ ] EOS 1V ingest parity in Swift (mapping/normalization/matching semantics from existing EOS 1V tool).
- [ ] EOS 1V lens-tag resolver architecture: remove hardcoded lens inference and route through a policy layer that can read future Settings defaults plus per-import overrides.
- [ ] Import conflict-resolution UX (unmatched/conflict buckets, explicit user resolution).
- [ ] Deterministic import reporting and dry-run parity.
- [ ] **Reference-based metadata apply**: select one image as reference, apply chosen metadata fields to a selection. Uses ExifTool `-tagsFromFile`. Sheet UI: select reference file → choose field groups → preview diff → confirm.

### Browser
- [ ] Click-to-drag rubber-band selection in list and gallery views.

### Settings
- [ ] Inspector field visibility controls.
- [ ] Backup enable/disable controls with menu/context behavior alignment.
- [ ] Backup retention policy.
- [ ] Clear recent folders action.
- [ ] EOS 1V import lens-tag policy controls:
  - [ ] Policy mode: `Do not write lens`, `Single lens for import`, `Focal-length mapping table`.
  - [ ] Unknown focal length behavior: `Leave empty`, `Use fallback`, or `Warn/skip`.
  - [ ] Named lens profiles + import-sheet override selector.

---

## v1.2 (Minor) — Editing Productivity

- [ ] Batch Rename (first release).
- [ ] Metadata copy/paste:
  - [ ] Field-level copy/paste.
  - [ ] Metadata-set copy/paste.
- [ ] Rename hardening:
  - [ ] Collision handling.
  - [ ] Preview determinism.
  - [ ] Undo/recovery safety.
- [ ] **Timestamp sync tools**: "Set file date from DateTimeOriginal" and "Set DateTimeOriginal from file date". Preview + confirm dialog, batch-safe with backup support.

---

## v1.3 (Minor) — Native Workflow UX + Customisation

Merges former v1.3 and v1.4 into one release.

- [ ] Drag files out to Finder/Mail/Messages etc. (NSItemProvider/NSPasteboardWriter on gallery/list items).
- [ ] Drag a folder onto the sidebar to add as a favourite.
- [ ] Drag to reorder sidebar favourites.
- [ ] Explicit Home/End/Page Up/Page Down keyboard nav in list/gallery.
- [ ] Finder-style breadcrumb bar.
- [ ] List column category editing (including Exif-backed columns).
- [ ] Gallery metadata lines/subtitle customisation.
- [ ] Toolbar customisation/editing.
- [ ] Send to Photos handoff workflow.
- [ ] Send to Lightroom Classic handoff workflow.
- [ ] **Full native QuickLook rewrite**: replace current preview implementation with a fully native QuickLook integration.

---

## v1.4 (Minor) — Metadata Search

Moves before performance: search will expose large-folder performance gaps, making the sequence logical.

- [ ] Metadata-aware query model.
- [ ] Search UI integration.
- [ ] Search persistence/history (scope permitting).
- [ ] **Audit/validation mode**: surfaces missing/inconsistent metadata (missing DateTimeOriginal, missing GPS, missing copyright, conflicting IPTC/XMP). Inspector "Issues" section with one-click fixes where safe.

---

## v1.5 (Minor) — Performance

- [ ] Large-folder performance pass (1000+ images).
- [ ] Render/browse pipeline optimisation.
- [ ] Thumbnail cache TTL / age-based eviction (currently LRU only; cross-folder sessions accumulate stale entries).
- [ ] Inspector preview cache size cap (currently trimmed by URL list only; large folders cache all previews with no memory ceiling).
- [ ] Continued targeted AppKit groundwork.

---

## v2.0 (Major) — Gallery + Power User Features

- [ ] Major gallery/browser architecture rewrite (AppKit-shell-first, Mondrian-inspired — see `photos-reverse-engineering.md`).
- [ ] Sidebar rewritten in AppKit.
- [ ] **Finder-style gallery view**: filmstrip along bottom, large preview at top — third browser mode alongside list and grid.
- [ ] **Metadata export CSV/JSON**: select fields, export to CSV or JSON for spreadsheet editing or audit reporting.
- [ ] **Import conflict-resolution UI (power-user)**: dedicated conflict workspace for unresolved/ambiguous import rows with per-row target choice, side-by-side field diff, and bulk resolve actions.
- [ ] **Sidecar management**: XMP sidecar create/rebuild/apply; browser badges for sidecar-exists and sidecar-differs-from-embedded states.
- [ ] ExifTool console: live readout of ExifTool commands and output as operations run, mirroring what would appear if running ExifTool directly in the terminal.
- [ ] Architecture reference docs:
  - [ ] `output/roadmap/photos-reverse-engineering.md`
  - [ ] `output/roadmap/sf-symbols-architecture-analysis.md`
  - [ ] `output/roadmap/Gruber.md`

---

## v3.0 (Major) — Direct EOS 1V Ingest (CSV Transport)

- [ ] Connect to EOS 1V and retrieve native shooting-data CSV directly.
- [ ] Feed retrieved CSV into Ledger import pipeline (from v1.1) for normal preview/match/apply.
- [ ] Research-first reverse-engineering path:
  - [ ] Prioritize macOS 9 driver analysis.
  - [ ] Use Windows XP driver as validation/fallback.
- [ ] Ship clean Swift behavioral reimplementation only.
