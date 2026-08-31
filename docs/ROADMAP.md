# ROADMAP

Current baseline: **v1.2.3**. Now: **v1.3**.

This file is the active forward roadmap.
Full detail for shipped work (every pre-v1.0 backlog item, and every item in
v1.0.1 through v1.2.3) has moved to `docs/ROADMAPOLD.MD` — also captured,
release by release, in `CHANGELOG.md`.

---

## Shipped: v1.0.1 – v1.2.3

Summary only — full item-by-item detail in `docs/ROADMAPOLD.MD` and `CHANGELOG.md`.

- **v1.0.1** (Patch, 2026-03-04) — Stability + Trust: inspector map CPU fix, folder-switch render parity, locked-file preflight/reporting, misc cleanup.
- **v1.1** (2026-03-10) — Import System Completion + Settings: unified import framework (CSV/GPX/Reference Folder/EOS-1V), reference-based metadata apply, inspector/settings groundwork, ExifTool CSV export, Photos/Lightroom Classic handoff.
- **v1.2** — Batch Rename first release, expanded inspector metadata coverage, Finder-style breadcrumb bar, AppKit sidebar rewrite, full native QuickLook rewrite, thumbnail pipeline rewrite, Date/Time + Location adjust workflows, performance streamlining Phases 1-3.
- **v1.2.3** (Patch) — macOS Golden Gate Readiness: macOS 27/Xcode 27 compatibility pass (geocoder migration, SharedUI concurrency fix, apply/restore capture-semantics fix).

---

## v1.3 — Import Maturity + Polish

### Import

- [ ] **EOS-1V lens-tag policy system**: originally scoped as policy modes + unknown-focal-length handling + named lens profiles + override selector. Decision 2026-08-29: the `Do not write lens`/`Single lens for import` policy modes are **not being pursued** — the EOS-1V CSV is a source of truth and this feature is just interpreting it into accurate EXIF values; if a resolved lens is wrong for a given frame, editing it after import is trivial, so a dedicated policy switch isn't worth the complexity. Scope narrowed to just the registry (done) and the picker UI (done):
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

- [ ] Bump bundled ExifTool from 13.50 to latest (13.59 as of 2026-07-25). Includes three security updates (13.53, 13.54, 13.59), Exif 3.1 spec tags (13.56), and Canon/Nikon/Sony lens improvements.
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
- [ ] **Unify window and list persistence**: prefer AppKit's native window, split-view, and table-column autosave mechanisms; remove competing persistence and layout feedback loops. Detailed diagnosis: `docs/window-list-resize-diagnosis-2026-07.md`.
- [ ] **Complete the coordinated SharedUI audit**: review macOS 26 chrome workarounds on macOS 26 and 27, retaining only those with current evidence; keep SharedUI-owned implementation work tracked in SharedUI `docs/Roadmap.md`.

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

### Devices

- [ ] **Camera/SD card photo import**: a new "Devices" sidebar entry (alongside Canon EOS-1V, same section) for any connected camera or memory card, built on Apple's native `ImageCaptureCore` (`ICDeviceBrowser`/`ICCameraDevice` — the same framework Photos.app/Preview/Image Capture.app use), adopting the system's native photo-import UI/paradigm rather than a custom-built one. No existing groundwork — `ImageCaptureCore` isn't referenced anywhere in the codebase yet.

### Import

- [ ] **Import conflict-resolution, revisited**: a real UI for unresolved/ambiguous import rows, designed against how matching actually behaves rather than assumed. Full context, the structural finding from the 2026-08-29 attempt (no current adapter path can produce `.multipleTargets` or a multi-candidate `.duplicateSourceIdentifier`), and a recommended approach are in `docs/import-conflict-resolution-plan-2026-08.md`.

### EOS-1V

- [ ] **Roll metadata database**: a Ledger-owned overlay of user-editable info (starting with Title/Remarks, extensible to any field via per-roll/per-frame overrides) layered on top of the camera's immutable downloaded data, plus a second "Ledger-enriched" CSV export alongside the existing untouched-camera-data export. Full data model, file-by-file plan, and rationale (including why this isn't a database engine) in `docs/eos1v-roll-metadata-plan-2026-08.md`.

### Metadata

- [ ] **Copy/paste field selector**: using the same UI/plumbing as preset sheets — "Copy selected fields…" pops up a window to pick fields, then paste applies only those.

### Export & Output

- [ ] **Print support**: batch output as PDF contact sheets     

---

## Parked

- [ ] **Audit/validation mode**: surfaces missing/inconsistent metadata (missing DateTimeOriginal, missing GPS, missing copyright, conflicting IPTC/XMP). Inspector "Issues" section with one-click fixes where safe.
- [ ] **Sidecar management**: XMP sidecar create/rebuild/apply; browser badges for sidecar-exists and sidecar-differs-from-embedded states.

-
