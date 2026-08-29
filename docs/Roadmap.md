# ROADMAP

Current baseline: **v1.2.3**.

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

## v1.1 — Import System Completion + Settings

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

## v1.2

- [x] Welcome/version screen using `AppWelcomeViewController` from SharedUI (WhatsNewKit-backed). Show on first run; reuse for "What's New" on major version updates.
- [x] Batch Rename first release: preview, token rendering, selection/folder scope, deterministic ordering, collision disambiguation, backup-aware execution, and rename restore support.
- [x] Expanded inspector metadata coverage across EXIF / IPTC / XMP, including rating, pick flag, colour label, and field visibility controls.
- [x] Finder-style breadcrumb bar.
- [x] Dock icon badge and Dock menu shortcuts for favourites, recents, and Open Folder.
- [x] List column customisation (including Exif-backed columns).
- [x] Drag to reorder sidebar favourites.
- [x] Click-to-drag rubber-band selection in gallery view.
- [x] **Metadata export CSV/JSON**: select fields, export to CSV or JSON for spreadsheet editing or audit reporting.
- [x] **Backup retention policy**: keep-last-N model, persistence, prune path wiring, and Settings UI controls. Infrastructure (`BackupManager.pruneOperations`) already exists; this is the Settings surface and wiring.
- [x] Sidebar rewritten in AppKit.
- [x] SharedUI/AppKit browser parity hardening for focus, keyboard, and selection behaviour in list/gallery/inspector flows.
- [x] Browser context-menu handoff to Photos, Lightroom, and Lightroom Classic.
- [x] Thumbnail pipeline rewrite with shared cache / broker hardening.
- [x] Inspector preview cache size cap (currently trimmed by URL list only; large folders cache all previews with no memory ceiling).
- [x] Date/Time adjust workflow in Inspector + Image menu: AppKit-backed date controls, `Set…` launch flow, Shift/Time Zone/Specific/File modes, Apply-to (`Original` / `Digitised` / `Modified`) targeting, and effective-change preview/apply gating.
- [x] Workflow sheet parity pass across Import / Batch Rename / Date-Time: shared `WorkflowSheetContainer` rhythm, `WorkflowFormRow` adoption, and aligned section/footer spacing.
- [x] Location adjust workflow (MapKit): workflow sheet + Inspector/Image-menu entry points, search + map interaction, latitude/longitude preview line, preview popover, and staged GPS lat/lon writes.
- [x] Performance streamlining pass, Phases 1-3 (no feature cuts): payload/runtime/CPU reductions tracked in `docs/v1.2-performance-streamlining-plan.md`. Phase 4 (architecture guardrails) carried forward to v1.3.

---

## v1.2.3 (Patch) — macOS Golden Gate Readiness

Compatibility and modernisation pass for macOS 27 on Xcode 27. Full build against SDK 27 is clean (2026-08-15): no `@State` macro or `@ContentBuilder` source breakage, so no forced SwiftUI fixes. UI/Liquid Glass adoption deliberately deferred.

- [x] **Geocoder migration**: `CLGeocoder` / `reverseGeocodeLocation` / `placemark` in `DateTimeAdjustSheetView.swift` are deprecated as of macOS 26. Migrated to MapKit `MKReverseGeocodingRequest` + `addressRepresentations` (both reverse-geocode and search paths share `applyResolvedPlace(from:)`). Known behaviour change: the new API exposes no structured administrative area, so **State/Province is removed from the Set Location sheet entirely** (no checkbox, no "no resolved value" warning; `LocationAdvancedField.geocodableCases` is the single source). Manual entry remains via the inspector's IPTC State field — verified against MKAddressRepresentations' runtime surface, decision 2026-08-15.
- [x] Fix SharedUI concurrency warning: capture of non-Sendable `SourceID.Type` in an isolated closure (`QuickLookPanelCoordinator.swift`). Fixed by constraining `SourceID: Hashable & Sendable` — correct semantics for an ID that crosses the KVO/main-actor boundary; both consumers (Ledger `URL`, Librarian `String`) already satisfy it.
- [x] Fix capture-semantics warning in apply/restore path (`AppModel+ApplyRestore.swift`): inner post-apply task used `[weak self]` while the enclosing apply closure held `self` strongly. Dropped the weak capture to match the sibling alert task — `AppModel` is app-lifetime and the task is short and unstored, so no cycle risk; state reset (`isApplyingMetadata`) now reliably runs.
Deferred: HDR-aware previews (moved to v2.0 — belongs with the in-app viewer and gallery-pipeline rewrite; benefit today is limited since film-scan TIFFs are SDR).

---

## v1.3 — Import Maturity + Polish

### Import
- [ ] **Import conflict-resolution UI**: reverted 2026-08-29 — a first pass (`ImportConflictResolutionSheetView`) was built and shipped, then stripped back out to the original blocking "future update" alert. The build surfaced a real structural finding (no current import adapter can actually produce a `.multipleTargets` or multi-candidate `.duplicateSourceIdentifier` conflict — see below), which changes what this feature should even be. Deferred to a proper pass; see `docs/import-conflict-resolution-plan-2026-08.md` and the v2.2+ entry.
- [ ] **EOS-1V lens-tag policy system**: originally scoped as policy modes + unknown-focal-length handling + named lens profiles + override selector. Decision 2026-08-29: the `Do not write lens`/`Single lens for import` policy modes are **not being pursued** — the EOS-1V CSV is a source of truth and this feature is just interpreting it into accurate EXIF values; if a resolved lens is wrong for a given frame, editing it after import is trivial, so a dedicated policy switch isn't worth the complexity. Scope narrowed to just the registry (done) and the picker UI (done):
  - [x] **Named lens profiles**: `LensProfile` registry (`LensProfiles.swift`) replacing the hardcoded embedded CSV (`EOSLensMappingEmbedded.swift`, now unused at runtime — reference copy at `~/Desktop/eos-lens-mapping-reference.csv`, safe to delete once manually re-entered lenses are confirmed complete). Editable via Settings → General → "Manage Lenses…" (bridging to SwiftUI via `NSHostingController` + `presentAsSheet`), Prime/Zoom radio toggle, per-lens focal range + aperture(s). `applyEOSLensPolicy`'s matching now sources from `AppModel.lensProfiles` instead of the embedded table.
  - [x] **Ambiguous-lens picker → one sheet**: `EOSLensChoiceSheetView` replaces the old loop of blocking `NSAlert`s (`ImportSession.chooseLens`, removed). One sheet lists every ambiguous frame at once (filename, focal length, frame aperture, a native grey `InspectorPopupField` dropdown per row), grouped by focal length with a live-linked "Apply to all at this focal length" checkbox per group. A frame left on "Leave Blank" now just skips that one field — the rest of the batch still stages, unlike the old alert's full-abort cancel.
  - [ ] Unknown focal length behaviour (no registered lens covers a row's focal length) — still undecided/open, smaller than the dropped policy-mode work.

### Browse
- [x] **iCloud Drive file-state UI**: make it obvious in list/gallery/inspector when a file is a cloud placeholder rather than downloaded locally (evicted/dataless items currently look like a thumbnail/metadata loading failure — exiftool reads time out silently and previews stall while fileproviderd materialises multi-hundred-MB scans). Detect via `URLResourceValues` (`isUbiquitousItem` / `ubiquitousItemDownloadingStatus`) and badge undownloaded items with an iCloud symbol using SharedUI's `makeGalleryOverlaySymbol` (`Gallery/GalleryOverlay.swift`), in the style of Librarian's shared-library `person.2.fill` grid badge. Consider a download affordance/progress and skipping exiftool reads until files are materialised.
- [x] **Finder-style gallery view**: filmstrip along bottom, large preview at top — third browser mode alongside list and grid.
- [x] Gallery metadata lines/subtitle customisation.
- [x] Explicit Home/End/Page Up/Page Down keyboard nav in list/gallery.

### Metadata
- [x] Metadata copy/paste:
  - [x] Field-level copy/paste.
  - [x] Metadata-set copy/paste.
- [x] ExifTool console: live readout of ExifTool commands and output as operations run, mirroring what would appear if running ExifTool directly in the terminal.

### Maintenance
- [ ] Bump bundled ExifTool from 13.50 to latest (13.59 as of 2026-07-25). Includes three security updates (13.53, 13.54, 13.59), Exif 3.1 spec tags (13.56), and Canon/Nikon/Sony lens improvements.
- [ ] No-op batch rename: suppress the staged/applied state when a rename pattern produces no changes (filenames unchanged).

---

## v1.4 — Architecture Foundations (Pre-2.0)

No new user-facing features — isolated architecture/perf work ahead of the v2.0 gallery rewrite, so a regression pass only has to account for the refactor, not new surface area. Structured as four sequenced themes rather than a flat list — rationale, dependency ordering, and an "is the app actually hacky" assessment in `docs/v1.4-architecture-plan-2026-08.md`. ALSO NOT MENTIONED HERE BUT I WANT INCLUDED, DO A PASS OF THE ENTIRE CODEBASE FOR REDUNDANT / OUT OF DATE CODE AND EXPLORE WAYS TO KEEP THE APP BINARY SMALL. 

### A. Structural decomposition (do first — makes B and D safer)
- [ ] **Performance streamlining Phase 4 (carried over from v1.2)**: architecture guardrails from `docs/v1.2-performance-streamlining-plan.md` — split `MainContentView.swift` into feature-focused files (menu wiring, split-view shell, observers, context menu actions); continue decomposing large `AppModel` extensions where natural boundaries exist; audit `AppModel` `@Published` properties to isolate hot-path/transient state from broad UI observation. `MainContentView.swift` is also where this session's menu-bar regression happened — a monolithic file mixing menu wiring with everything else is why two different timing contracts sharing one function went unnoticed. Split before touching Theme B or D.

### B. Chrome & window-system foundations (native-feel surface, most visible to the user)
- [ ] **Chrome & menu-bar timing audit (consolidated)**: macOS 26 Liquid Glass-era workarounds (sidebar inset machinery, window-config timing flashes — inventory and method tracked in SharedUI `docs/Roadmap.md` "macOS 26 chrome-workaround audit") **and** menu bar architecture (top-level menus injected into `NSApp.mainMenu` at runtime from `NativeThreePaneSplitViewController`'s view lifecycle rather than existing from launch — no nib, no SwiftUI `.commands`; deliberately deferred one run-loop tick and re-applied on every menu-bar click to defend against SwiftUI's runtime independently mutating `NSApp.mainMenu` when hosted views appear, which is also why the menu bar visibly arrives a beat after launch) are the same class of problem — an OS/framework-timing workaround of unconfirmed continued necessity — and should be investigated as one effort rather than two. Root causes, code references, and fix options in `docs/menu-bar-architecture-audit-2026-08.md` (menu bar) and SharedUI's `docs/Roadmap.md` (chrome inventory).
- [ ] **Window/list-column resize fix** (moved from v1.3 — architecture debt, not a feature): window frame, split dividers, and table column widths are restored via three independent absolute-pixel autosave systems with no reconciliation against current available width, causing inconsistent window size and columns/scrollbar overflow. Root-cause diagnosis and fix plan in `docs/window-list-resize-diagnosis-2026-07.md`. Same window/layout-lifecycle-timing territory as the chrome/menu-bar audit above — natural to sequence alongside it.
- SharedUI scope pulled in alongside this theme (already tracked there, not duplicated here): sidebar inactive-window label colour not dimming, and `AppKitSidebarController` sidebar-cell rebuild (replace hand-constrained layout with a standard `NSStackView`) — both same "native fidelity" bucket, and SharedUI's own doc already notes they overlap each other.

### C. Data/pipeline hardening (independent of A/B, can proceed in parallel)
- [ ] AppKit/UI + performance/memory/disk audit follow-ups: see `docs/appkit-ui-performance-audit-2026-07.md`. Notably batching `exiftool` metadata writes into a single invocation instead of one process per file, and adding eviction to the thumbnail disk cache.
- [ ] **Thumbnail pipeline audit**: fix Icon-view folder-switch flash (cells briefly paint a generic fallback icon before the real thumbnail/size/cloud-badge pop in) caused by `ThumbnailService.cachedImage` only checking the in-memory cache, never the on-disk one; then a proper pass across the pipeline's synchronous-paint-vs-async-data pattern, which has produced this same class of bug repeatedly (folder-switch render parity in v1.2, several reverted/partial fixes pre-v1.0.1, and this session's icon subtitle-refresh bug). Root cause, git history, and phased plan in `docs/thumbnail-pipeline-audit-2026-08.md`. Quick fix (synchronous disk-cache read) already shipped; wider pass still open.

### D. `@Observable` migration + Combine retirement (do last — right before the v2.0 boundary)
- [ ] Move `AppModel` (and remaining `ObservableObject` types) from `@Published`/`objectWillChange` (~58 properties) to the `@Observable` macro for per-property view invalidation — the largest available SwiftUI performance lever for the inspector/browser, and best done before v2.0 rebuilds views on top. Fold in removal of the four remaining `import Combine` sites (per project guideline preferring async/await). Watch interactions with `inspectorRefreshRevision` and other manual-notify patterns that exist to work around whole-object invalidation. Sequenced last so it migrates the smaller, better-organized surface Theme A produces, rather than today's monolith.

---

## v2.0 (Major) — Bridge Core

- [ ] **Major Photos.app-style rewrite of gallery view architecture.**
- [ ] Finder-style hierarchical browsing as the core file-browser model.
- [ ] In-app image viewing as a core workflow for Ledger-supported image formats.
- [ ] **HDR-aware rendering** (moved from v1.2.3, 2026-08-15): decode HDR/gain-map images via ImageIO `kCGImageSourceDecodeToHDR` (+ `kCGComputeHDRStats`); render inspector/grid previews with `NSImage.DynamicRange.constrainedHigh` (`NSImageView.preferredImageDynamicRange` / SwiftUI `allowedDynamicRange`) and the in-app viewer with `.high` on EDR displays. SDR files are unaffected (decode option is a no-op). Keep the JPEG thumbnail disk cache SDR; HDR applies to live decodes only. Benefits iPhone HEICs, gain-map JPEGs, and HDR DNGs — not classic film-scan TIFFs.

---

## v2.1

- [ ] Drag files out to Finder/Mail/Messages etc. (NSItemProvider/NSPasteboardWriter on gallery/list items).
- [ ] Drag a folder onto the sidebar to add as a favourite.
- [ ] Bridge-class search, filter, and sort across folders and metadata facets (type, rating, labels, keywords, and other attributes).
- [ ] Smart folders.

---

## v2.2+

- [ ] Workflow automation / workflow builder for repeatable multi-step jobs.
- [ ] Triage/culling workflow.
- [ ] Batch output: PDF contact sheets.
- [ ] Copy/paste field selector (using same UI/plumbing as preset sheets) - 'copy selected fields..'pops up a window to select your fields and then paste only those
- [ ] **Import conflict-resolution, revisited**: a real UI for unresolved/ambiguous import rows, designed against how matching actually behaves rather than assumed. Full context, the structural finding from the 2026-08-29 attempt (no current adapter path can produce `.multipleTargets` or a multi-candidate `.duplicateSourceIdentifier`), and a recommended approach are in `docs/import-conflict-resolution-plan-2026-08.md`.

---

## Parked

- [ ] **Audit/validation mode**: surfaces missing/inconsistent metadata (missing DateTimeOriginal, missing GPS, missing copyright, conflicting IPTC/XMP). Inspector "Issues" section with one-click fixes where safe.
- [ ] **Sidecar management**: XMP sidecar create/rebuild/apply; browser badges for sidecar-exists and sidecar-differs-from-embedded states.

---

## Completed

- [x] Render/browse pipeline optimisation.
- [x] Thumbnail cache TTL / age-based eviction (currently LRU only; cross-folder sessions accumulate stale entries).
- [x] **Full native QuickLook rewrite**: replace current preview implementation with a fully native QuickLook integration.

---

## Cancelled

- [ ] Toolbar customisation.
- [ ] Inspector clear-field control: optional trailing `x.circle.fill` action per field for staged-clear UX.
- [ ] Large-folder performance pass (1000+ images).
- [ ] Connect to EOS-1V and retrieve native shooting-data CSV directly.
- [ ] Feed retrieved CSV into Ledger import pipeline for normal preview/match/apply.
- [ ] Research-first reverse-engineering path:
  - [ ] Prioritise macOS 9 driver analysis.
  - [ ] Use Windows XP driver as validation/fallback.
- [ ] Ship clean Swift behavioural reimplementation only.
