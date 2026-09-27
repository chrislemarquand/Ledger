# ROADMAP

Current baseline: **v1.4**. Now: **v1.4.1 / v1.5** (unplanned; see below).

This file is the active forward roadmap.
Full detail for shipped work (every pre-v1.0 backlog item, and every item in
v1.0.1 through v1.4) has moved to `docs/ROADMAPOLD.MD` — also captured,
release by release, in `CHANGELOG.md`.

---

## Shipped: v1.0.1 – v1.4

Summary only — full item-by-item detail in `docs/ROADMAPOLD.MD` and `CHANGELOG.md`.

- **v1.0.1** (Patch, 2026-03-04) — Stability + Trust: inspector map CPU fix, folder-switch render parity, locked-file preflight/reporting, misc cleanup.
- **v1.1** (2026-03-10) — Import System Completion + Settings: unified import framework (CSV/GPX/Reference Folder/EOS-1V), reference-based metadata apply, inspector/settings groundwork, ExifTool CSV export, Photos/Lightroom Classic handoff.
- **v1.2** — Batch Rename first release, expanded inspector metadata coverage, Finder-style breadcrumb bar, AppKit sidebar rewrite, full native QuickLook rewrite, thumbnail pipeline rewrite, Date/Time + Location adjust workflows, performance streamlining Phases 1-3.
- **v1.2.3** (Patch) — macOS Golden Gate Readiness: macOS 27/Xcode 27 compatibility pass (geocoder migration, SharedUI concurrency fix, apply/restore capture-semantics fix).
- **v1.3** (2026-08-31) — Import Maturity + Polish: EOS-1V lens-tag policy system (named lens profiles, ambiguous-lens picker, unknown-focal-length prompt), direct EOS-1V camera connection over the ES-E1 cable, iCloud Drive file-state UI, Finder-style Gallery view, gallery subtitle customisation, metadata copy/paste, ExifTool console, bundled ExifTool bumped to 13.55.
- **v1.4** (2026-09-26) — Performance + Native Foundations: no new user-facing features by design — a measured performance/efficiency pass (non-blocking interaction paths, demand-driven metadata/thumbnail loading, bounded caches) and a native-macOS-foundations pass (menu bar owned from launch, native window/list persistence, a full macOS 26→27 chrome-workaround audit, a UI consistency/polish sweep, reopen-last-folder-on-launch). Closed out by an external architecture-outcome review that found and fixed two real remaining defects (observer-lifecycle mismatches, incomplete task cancellation) same-day; its other six findings deferred to v1.4.1/v1.5 (below), not dropped.

---

## v1.4.1 / v1.5 — Deferred hardening

Not yet scheduled to either number specifically — these are the findings the
2026-09-27 external architecture-outcome review flagged as real but explicitly
deferred rather than fixed under release pressure (full text:
`docs/v1.4-architecture-outcome-review-2026-09-27.md`; logged at the time in
`docs/v1.4-progress.md`'s Decision log). All are hardening/correctness, not
features — pick up as a patch release or fold into whichever of v1.4.1/v1.5
ends up scheduled first.

- [ ] **Menu validation does synchronous filesystem/app discovery**: `AppModel+Actions.swift`'s `fileActionState` eagerly resolves the default app and both Lightroom variants (filesystem checks, bundle reads, `NSWorkspace` queries) before switching on the requested action — so validating even Apply/Discard can trigger unrelated external-app discovery on the synchronous menu-validation path. `Open With` submenu construction has the same shape. Direction: compute only what the specific action needs; keep native menu/responder-chain ownership.
- [ ] **Metadata demand includes hidden modes and stays folder-wide**: `hasVisibleMetadataColumnDemand` (`AppModel+FileLoading.swift`) counts persisted List columns as "visible demand" even while List is hidden, and Icon subtitles regardless of active mode; once triggered, prefetch scans folder-wide in enumeration order rather than viewport-first. A real supported configuration (not just a benchmark artifact), so this genuinely conflicts with the visible-demand/lightweight goal for that configuration. Direction: correct the active-mode demand check; defer full viewport prioritization pending measurement.
- [ ] **Hidden-surface inactivity isn't structurally guaranteed**: the browser container's explicit-update routing proves hidden controllers get no `update` calls, but Gallery's `LargePreviewCard`/`LargePreviewPane` SwiftUI content independently observes the whole `AppModel` regardless of view-hidden state. Doesn't by itself justify an Observation migration — if picked up, verify actual invalidation/task behaviour rather than assuming it from the container switch.
- [ ] **macOS 26 and map-drag verification still incomplete**: the manual smoke checklist's §7 (macOS 26 chrome) is honestly marked SKIPPED, not silently passed — no macOS 26 machine/VM has been available across two release cycles now. Separately, the map-drag reentrant-layout issue (`docs/v1.4-progress.md:2169`) was never re-reproduced after later, unrelated fixes; treat as unresolved verification, not proof it's fixed. Needs a real macOS 26 environment, and a specific repro-and-close of the map drag sequence.
- [ ] **Correct the ExifTool-batching rejection's rationale** (no behavior change): the existing rejection (see `docs/ROADMAPOLD.MD`'s v1.4 Phase 3.2 entry) overstates its case — ExifTool supports multiple command groups per invocation via `-execute` without needing `-stay_open`. The rejection itself still stands (backup interleaving and per-file result attribution remain genuinely nontrivial); just don't carry "batching requires a persistent `-stay_open` process" forward as true premise in future planning.
- [ ] **Sidebar scroll-repair may no longer be needed**: `AppKitSidebarController.applyInitialScrollPositionIfNeeded()` (SharedUI) still unconditionally scrolls to zero once an inset appears, despite the root cause being fixed elsewhere (toolbar-before-content construction order, Phase 4.3). No consumer other than this repair was found to depend on it. Before removing: check all consumers and verify launch/restoration behaviour directly; don't substitute another timing patch.

Also still open from the v1.4 judgment table, not urgent: a real 20–50-folder
memory/pressure measurement to substantiate the metadata-cache-eviction policy
(currently asserted, not demonstrated), and the UI-test matrix/isolated-
preferences gaps noted in `docs/v1.4-progress.md`'s decision log, which limit
how much confidence broad "all PASS" claims should carry without implying the
production architecture itself needs redesign.

---

## v2.0+ — A better Bridge

Directional, not committed — less specified than v1.3/v1.4 on purpose; expect this section to be re-scoped as it gets closer.

### Browse

- [ ] **Finder-style hierarchical browsing**: the core file-browser model, replacing today's flat folder-at-a-time navigation.
- [ ] **In-app image viewing**: a core workflow for Ledger-supported image formats, no external viewer needed.
- [ ] **Cull Mode**: a general-purpose, full-window review/compare mode activatable on any folder at any time (not restricted to right after an import, though that's one expected entry point) — a dedicated chrome treatment (Photos.app's Edit-mode style window change was the reference point) makes it unambiguous you've left metadata-editing and entered rapid pick/reject triage. Reuses the existing Pick flag (`pick: Int`, -1/0/1) already backing `InspectorRatingFlagView` rather than inventing a new field, and the existing `sendToLightroom`/`sendToLightroomClassic`/`sendToPhotos` handoff actions for a non-destructive "Send Picks to…" exit path — kept strictly separate from a "Delete Rejected" exit path, which follows the app's existing destructive-action convention (its own explicit confirmation, never a side effect of exiting the mode). Full scoping, open design questions (layout, keyboard bindings, menu-bar behaviour, chrome implementation approach), and what already exists to build on in `docs/cull-mode-plan-2026-09.md` — speculative, not committed.
- [ ] **HDR-aware rendering** (moved from v1.2.3, 2026-08-15): decode HDR/gain-map images via ImageIO `kCGImageSourceDecodeToHDR` (+ `kCGComputeHDRStats`); render inspector/grid previews with `NSImage.DynamicRange.constrainedHigh` (`NSImageView.preferredImageDynamicRange` / SwiftUI `allowedDynamicRange`) and the in-app viewer with `.high` on EDR displays. SDR files are unaffected (decode option is a no-op). Keep the JPEG thumbnail disk cache SDR; HDR applies to live decodes only.
- [ ] **Stacks**: group related files (RAW+JPEG pairs first; bracket/panorama sequences later) into one visual browser unit. Checked against how Lightroom/Bridge actually behave — their Stacks are purely visual grouping with **no metadata sync between members** — so the proposed selective sync (subject/organizational fields like keywords/GPS/rating always sync; capture-technical fields like exposure/lens never forced) is a deliberate departure from, not a port of, the reference tools. Shares its RAW+JPEG pairing detection with the device-import and Cull Mode work rather than reimplementing it three times. Full scoping and open questions in `docs/stacks-plan-2026-09.md` — speculative, not committed.
- [ ] **Video metadata support**: today video is entirely invisible — `supportedImageExtensions` (`AppModel.swift:731`) has no video extension, so clips on a camera card are silently skipped everywhere. Checked empirically (not assumed) against the exact ExifTool version Ledger bundles (13.55): reads `AVI`/`HEIC`/`HEIF`/`M4V`/`MOV`/`MP4`/`MTS`, but only **writes** `M4V`/`MOV`/`MP4` (confirmed live — QuickTime-native atoms, embedded XMP, and GPS all wrote and read back correctly on a real `.mov`); `AVI`/`MTS` (older camcorder/AVCHD formats) are read-only. So **no separate metadata engine is needed** for the common MOV/MP4 case — same bundled ExifTool, new field-catalog entries for the `QuickTime:*` tag vocabulary, plus real new work for poster-frame thumbnailing (AVFoundation, not ExifTool). Export destination (Photos.app vs. Lightroom/Classic) not yet confirmed — treated as an open question, not assumed either way. Full findings and scope in `docs/video-metadata-support-plan-2026-09.md` — speculative, not committed.
- [ ] **Map-based review across a selection**: plot every geotagged file in the current selection/folder on a map at once, distinct from the existing single-file "Set Location" sheet — useful for reviewing a whole trip/shoot geographically rather than one file's coordinates at a time.
- [ ] **Smart folders**: saved metadata-facet queries surfaced like regular folders.
- [ ] **Bridge-class search, filter, and sort**: across folders and metadata facets (type, rating, labels, keywords, and other attributes).
- [ ] **Drag a folder onto the sidebar**: to add as a favourite.
- [ ] **Keyboard navigation:** Explicit Home/End/Page Up/Page Down keyboard nav in list/gallery.
- [ ] **Drag files out**: to Finder/Mail/Messages etc. (`NSItemProvider`/`NSPasteboardWriter` on gallery/list items).
- [ ] **Toolbar customisation**
- [ ] **File Provider extension support** (OneDrive/Dropbox/Google Drive and any other Finder-integrated cloud provider): today's cloud-download tracking (`CloudDownloadTracker.swift`) is entirely iCloud-specific — built on `NSMetadataQuery` scoped to `NSMetadataQueryUbiquitousDataScope`/`UbiquitousDocumentsScope`, reading `NSMetadataUbiquitousItemDownloadingStatusKey`/`PercentDownloadedKey`, and triggering downloads via `FileManager.startDownloadingUbiquitousItem(at:)` — all Apple-only, iCloud Drive-only APIs with no awareness of other providers. Third-party providers integrate with Finder through the separate, provider-agnostic **File Provider extension framework** (`NSFileProviderExtension`/`NSFileProviderManager`), a distinct API surface for querying placeholder/dataless state and triggering materialization. Genuinely separate implementation work, not an extension of the existing tracker — likely a second tracker built against the File Provider APIs, unified with the iCloud one behind a common protocol so the browser/inspector UI doesn't need to know which provider backs a given file. User-facing design intent (confirmed 2026-09-26): reuse the existing iCloud cloud-badge/progress UI as-is, not a new visual treatment — only the user-facing text changes to name the actual provider (e.g. "Downloading from Dropbox" instead of "Downloading" / iCloud's current wording), matching whichever provider backs the file.
- [ ] **Safe-eject affordance for external volumes in the sidebar** (Finder-style hover eject glyph): confirmed feasible with a real, sanctioned API — `NSWorkspace.shared.unmountAndEjectDevice(at: URL) throws` (bridged from `unmountAndEjectDeviceAtURL:error:`, available since 10.6, still current in the macOS 27 SDK), the same call Finder itself uses for safe unmount/eject. The overlay itself is plain UI, not a special API: a trailing accessory button (eject SF Symbol) shown on hover in the sidebar's `NSOutlineView` row (`AppKitSidebarController`) for rows backed by `.mountedVolume`. The ejectable/removable determination this needs (`volumeIsEjectableKey`/`volumeIsRemovableKey`) is already being fetched today in `mountedVolumeSidebarItems()` (`AppModel+Sidebar.swift`) for the external-volume filter — just not yet threaded through to `SidebarItem` for the UI to use. Low-risk, no missing platform capability; natural to build alongside the other external-volume work above.

### Devices

- [ ] **Camera/SD card photo import**: a new "Devices" sidebar entry (alongside Canon EOS-1V, same section) for any connected camera or memory card, built on Apple's native `ImageCaptureCore` (`ICDeviceBrowser`/`ICCameraDevice` — the same framework Photos.app/Preview/Image Capture.app use), adopting the system's native photo-import UI/paradigm rather than a custom-built one. No existing groundwork — `ImageCaptureCore` isn't referenced anywhere in the codebase yet. Full scoping, including a RAW/JPEG-split-and-route idea (JPEGs organized via Ledger's existing tools, RAWs handed to the already-working `sendToLightroom` action) and the possibility of a future iOS/iPadOS import-companion app, in `docs/native-device-import-plan-2026-09.md` — speculative, not committed.

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
- [ ] **Expanded export-to-disk**: a native batch export (Lightroom/Photos.app-style) — resize/dimensions, megapixel/quality target, format conversion, output folder — for output that isn't a handoff to another app. Distinct from today's only "output" paths, which are all app-handoffs (`sendToLightroom`/`sendToLightroomClassic`/`sendToPhotos`, `AppModel+Actions.swift`) — this would let a batch of finals go straight to disk (or a share/upload target) without needing another app open at all, matching the "lightweight, native" v2.0 positioning.

---

## Post-v2.0 — Exploratory / Under Investigation

Ideas scoped for feasibility but not committed, decided on, or scheduled — distinct from v2.0+
above (which is directional but intended) and from Parked below (deprioritized). An item here has
had at least an initial investigation pass; promote it to v2.0+ (or later) if/when it's actually
decided on.

- [ ] **Native (ImageIO) EXIF reader, read-only**: replace exiftool subprocess calls with a native
  Swift reader for the read path only (folder load, metadata prefetch, inspector display) — writes
  stay on exiftool. Real measured upside (a native reader is ~7-8x faster per file than the
  already-batched exiftool path in this session's benchmarks), but exiftool itself was found to
  disagree with its own standard-EXIF-tag vs. manufacturer-MakerNote values for several
  photography-relevant fields (ISO, ExposureTime, MeteringMode, FNumber) on a real CR2, so this
  isn't a mechanical port. Full scoping, real benchmark numbers, and a recommended validation
  approach in `docs/native-exif-reader-feasibility-2026-09.md`.
- [ ] **Native (Swift/IOKit) EOS-1V driver**: replace the Python (`eos1v-serial`) subprocess with a
  native transport for the four operations Ledger actually uses (`inspect`/`settings`/`download`/
  `set-clock`), motivated by not wanting a Python/pyusb/libusb dependency chain in the app rather
  than by any feature/performance gain. **Safety-critical**: a previous, separate project in this
  exact space destroyed a camera in March 2026 by misclassifying a write opcode as harmless. This
  round starts from a working, already-shipped reference implementation instead of guesswork, which
  is the key difference — but the same hard rules apply (verified-semantics-only opcode allowlist,
  no un-derived write opcodes, no teardown without confirmed completion). Also surfaced a real,
  separate finding worth its own follow-up: the current Python tool may not actually be bundled/
  distributable to real customers at all. Full scoping, the incident writeup, and a required staged
  validation approach (offline byte-equivalence testing as a hard gate before any live hardware
  test) in `docs/native-eos1v-driver-feasibility-2026-09.md`.

## Parked

- [ ] **Audit/validation mode**: surfaces missing/inconsistent metadata (missing DateTimeOriginal, missing GPS, missing copyright, conflicting IPTC/XMP). Inspector "Issues" section with one-click fixes where safe.
- [ ] **Sidecar management**: XMP sidecar create/rebuild/apply; browser badges for sidecar-exists and sidecar-differs-from-embedded states.

-
