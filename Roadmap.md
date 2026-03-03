# ROADMAP

Current baseline: **v1.0.0**.

This file is the active forward roadmap.
Historical pre-v1 detail remains in `ROADMAPOLD.MD`.

---

## v1.0.1 (Patch) — Stability + Trust

- [x] **Inspector map sustained CPU** (~10% at idle): live `MKMapView` display link ran unconditionally; replaced with `MKMapSnapshotter` static snapshot. Fixed post-1.0.0.
- [ ] Locked-file preflight/reporting (`B42` / `R22`).
- [ ] QA sign-off closure for v1 baseline matrix (partial restore failure subtitle; chmod partial-failure apply test).
- [ ] `pendingCommitsByFile` cleared on metadata reload success (inspector can show stale applied values if a subsequent apply partially fails).
- [ ] `Task.isCancelled` checks after `Task.sleep` in deferred async tasks (metadata prefetch, preview preload — cancellation is currently swallowed by `try?`, body runs regardless).
- [ ] `NumberFormatter`/`DateFormatter` instances promoted to static properties where currently allocated per-call.

---

## v1.1 (Minor) — Import System Completion + Settings

Primary objective: get import right end-to-end.

### Import
- [ ] Unified import framework and shared UI flow for:
  - [ ] CSV
  - [ ] GPX
  - [ ] Reference Folder
  - [ ] EOS 1V CSV
- [ ] Single import flow: load source -> match/preview/conflicts -> target scope (selection/folder) -> apply.
- [ ] EOS 1V ingest parity in Swift (mapping/normalization/matching semantics from existing EOS 1V tool).
- [ ] Import conflict-resolution UX (unmatched/conflict buckets, explicit user resolution).
- [ ] Deterministic import reporting and dry-run parity.

### Settings
- [ ] Inspector field visibility controls.
- [ ] Backup enable/disable controls with menu/context behavior alignment.
- [ ] Backup retention policy.
- [ ] Clear recent folders action.

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

---

## v1.3 (Minor) — Native Workflow UX Expansion

- [ ] Send to Photos handoff workflow.
- [ ] Send to Lightroom Classic handoff workflow.
- [ ] Finder-style breadcrumb bar.
- [ ] Browser presentation customization:
  - [ ] List column category editing (including Exif-backed columns).
  - [ ] Gallery metadata lines/subtitle customization.
- [ ] Toolbar customization/editing.
- [ ] Multi-window workflow support (`New Window`, per-window navigation/state expectations).
- [ ] Drag-and-drop workflows (in/out and internal where appropriate).
- [ ] Explicit Home/End/Page Up/Page Down behavior in list/gallery contexts.
- [ ] Accessibility and VoiceOver completion work (including keyboard-only operation checks).
- [ ] Sidebar AppKit groundwork: cancel stale image-count tasks on sidebar refresh; address SwiftUI List scroll-position instability (deferred from v1.0 audit).
- [ ] Inspector AppKit groundwork: `groupedEditableTags` dictionary-based grouping; address `inspectorRefreshRevision` UInt64 hack and manual edit-session `@State` snapshot pattern.

---

## v1.4 (Minor) — Performance

- [ ] Large-folder performance pass (1000+ images).
- [ ] Render/browse pipeline optimization.
- [ ] Thumbnail cache TTL / age-based eviction (currently LRU only; cross-folder sessions accumulate stale entries).
- [ ] Inspector preview cache size cap (currently trimmed by URL list only; large folders cache all previews with no memory ceiling).
- [ ] Continued targeted AppKit groundwork.

---

## v1.5 (Minor) — Metadata Search

- [ ] Metadata-aware query model.
- [ ] Search UI integration.
- [ ] Search persistence/history (scope permitting).

---

## v1.6 (Minor) — Pre-v2 Convergence

- [ ] Final seam hardening for v2 migration readiness.
- [ ] Stabilization overflow from v1.1-v1.5.

---

## v2.0 (Major) — Photos-Style Gallery Rewrite

- [ ] Major gallery/browser architecture rewrite.
- [ ] AppKit-shell-first structure with targeted SwiftUI islands.
- [ ] Use these docs as guidance for behavior and architecture:
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

