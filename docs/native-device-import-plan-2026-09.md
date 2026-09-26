# Native Device Import (RAW/JPEG Split → Lightroom/Archive) — Plan — 2026-09-26

Directional scoping for a v2.0+ feature, written up at the user's request
after a conversation exploring how Ledger could reduce the manual steps in
their current digital-camera import workflow. **This is speculative, not
committed** — no code has changed, and several open questions below need
real answers (not assumptions) before implementation starts. Tracked from
`docs/ROADMAP.md`'s v2.0+ → Devices section, alongside the existing
`ImageCaptureCore` card/camera-import item this builds on.

## The problem this is scoping (user's own workflow, verbatim context)

Today, importing from a digital camera's SD card is two manual steps done
by hand:
1. Import RAW files into Lightroom CC (RAW+JPEG together isn't well
   supported the way Lightroom Classic supports it).
2. Copy the JPEGs into a separate folder via Finder.

The user wants Ledger to absorb the messiness of this split — ingest the
card, separate RAW from JPEG, route each to where it needs to go — rather
than treating an SD card as just another folder to browse (today's actual
behaviour, confirmed: `mountedVolumeSidebarItems()` in
`AppModel+Sidebar.swift` lists any mounted external volume as a generic
sidebar "Sources" entry with no device-awareness at all).

This is explicitly analogous to the existing film-scan workflow already
described in the user's own written process: **lab scans land in a Mac
staging folder → Ledger fixes metadata → then handed to Lightroom**. The
digital-camera version would be **SD card → Ledger splits + files/tags →
JPEGs organized, RAWs handed to Lightroom** — same shape, one extra split
step, camera-native ingest instead of a manual folder drop.

## What already exists (verified against code, not assumed)

This is a smaller lift than it first looked, because two of the three
pieces already work today:

- **RAW→Lightroom CC handoff already exists and already works the way
  this feature would need.** `sendToLightroom(_:)`
  (`AppModel+Actions.swift:210`, calling into
  `sendToExternalPhotoApp(.lightroom, fileURLs:)` at `:218`) does
  `NSWorkspace.shared.open(uniqueURLs, withApplicationAt: appURL, ...)` —
  handing file URLs directly to the Lightroom CC app, the same mechanism
  as a Finder "Open With." This resolved what was initially flagged as
  the biggest open question in this scoping conversation (whether
  Lightroom CC needs a watched-sync-folder approach, which it doesn't
  support the way Lightroom Classic does) — it doesn't apply here at all.
  `sendToLightroomClassic(_:)` and `sendToPhotos(_:)` (which stages into a
  temp directory first, `makePhotosImportStagingDirectory`) are the other
  two existing handoff targets, all keyed off `ExternalPhotoAppTarget`
  (private enum, top of `AppModel+Actions.swift`).
- **JPEG organizing/tagging tools already exist** — this is exactly the
  film-scan workflow's "fix metadata before handoff" step
  (capture date, camera/lens, keywords, location), already built and in
  daily use; nothing new needed there beyond pointing it at the JPEG
  subset of a card import instead of a manually-dropped folder.
- **The import pipeline's adapter pattern already exists** and would be
  the natural place to add a new source: `ImportSourceKind`
  (`Import/ImportModels.swift:4`) currently has `.csv`, `.gpx`,
  `.referenceFolder`, `.eos1v`, each with its own adapter conforming to
  `ImportSourceAdapter` (`Import/ImportSourceAdapter.swift`) — e.g.
  `CSVImportAdapter.swift`, `EOS1VImportAdapter.swift`,
  `ReferenceFolderImportAdapter.swift`. A new adapter is the expected
  shape for whatever this feature's "prepare" stage produces, matching
  every existing import source rather than inventing a parallel
  mechanism.
- **What's genuinely missing**: `ImageCaptureCore` itself
  (`ICDeviceBrowser`/`ICCameraDevice`) isn't referenced anywhere in the
  codebase — confirmed via a full-repo search. Today's mounted-volume
  sidebar path (`NSWorkspace` volume mount/unmount notifications +
  `FileManager` enumeration — the same code just fixed for the physical-
  disconnect sidebar bug during v1.4 §8 testing, see
  `v1.4-progress.md`'s Phase 6 section) is a completely different,
  device-unaware mechanism from `ImageCaptureCore`'s device-connect
  events and per-file device APIs. Also missing: any RAW/JPEG pairing
  logic (grouping by basename), and any per-file-type routing UI at all.

## Scope (proposed — needs confirmation, not yet agreed)

In scope, if this goes forward:
- A native "camera/card" sidebar entry distinct from a plain mounted
  volume, built on `ImageCaptureCore` (the existing roadmap item).
- RAW+JPEG pair detection (matching basename, differing extension) so a
  camera's RAW+JPEG-together shooting mode is understood as pairs, not
  two unrelated file lists.
- JPEG routing: apply Ledger's existing metadata tools, then file into a
  user-chosen folder structure (the user's own convention is
  `YYYYMMDD - Place` on an external archive drive).
- RAW routing: hand off to the *already-existing* `sendToLightroom(_:)`
  action, called on the RAW subset — no new handoff mechanism.

Explicitly out of scope for now:
- Any change to the EOS-1V device path (`EOS1VSessionController`/
  `eos1v-serial`) — unrelated mechanism, unrelated hardware, already has
  its own dedicated device entry.
- Automating the Lightroom Classic archive-to-HDD / "Remove From All
  Synced Photographs" steps described in the user's workflow — those
  happen entirely inside Adobe's apps, outside anything Ledger can
  observe or drive.
- The iOS/iPadOS companion app — see its own section below; explicitly
  future/unscoped, not part of this plan's implementation surface.

## Open questions (need real answers before design, not assumptions)

- **Pairing UI**: does the user want RAW+JPEG pairs presented/confirmed
  before routing (a review step, similar to the existing ambiguous-lens
  picker's one-sheet-per-batch pattern in
  `Import/EOSLensChoiceSheetView`), or should it just happen automatically
  whenever a basename match is found? Cameras vary in how strictly they
  guarantee basename pairing across RAW/JPEG — this needs checking against
  the user's actual camera's file-naming behaviour, not assumed.
- **JPEG destination**: stage into a Ledger-managed staging folder first
  (matching the film-scan workflow's explicit staging step), or file
  directly into the final `YYYYMMDD - Place` archive structure? The film
  workflow uses a staging step deliberately; worth checking whether the
  same applies here or whether the SD-card case is different (e.g. no
  metadata to *fix* yet since digital EXIF is usually already correct at
  capture, unlike scanned film).
- **Device detection scope**: does this need to handle a card *reader*
  (SD card mounted as a plain volume via a reader) as well as a
  *tethered camera* (`ICCameraDevice` over USB, no card reader at all)?
  `ImageCaptureCore` covers both, but their file-listing/thumbnail APIs
  differ, and the user's stated workflow ("plug the card reader into
  the iPad") suggests the reader case matters at least as much as direct
  tethering.
- **Interaction with the existing mounted-volume sidebar path**: once a
  card/camera is recognized as a device, should it stop appearing as a
  generic mounted-volume "Sources" entry at all (to avoid the same card
  showing up twice, once as a device and once as a plain volume), or can
  both coexist? Needs a real design decision once `ImageCaptureCore`
  groundwork exists to test against.

None of these are answered here — this section exists so implementation
doesn't start from assumptions the way three past sessions' worth of
"guess first, verify never" mistakes did on unrelated bugs this project
(documented in `v1.4-progress.md`'s Phase 6 section and this repo's
`feedback_finder_parity_verify_first`/
`feedback_write_failing_test_before_more_guessing` memory).

## iOS/iPadOS companion app (future — explicitly unscoped)

Raised in conversation as a "maybe eventually" idea, not something to
design in detail yet. The one real constraint worth recording now, so a
future session doesn't have to rediscover it: **Ledger's metadata-writing
engine is built on ExifTool as a subprocess** (bundled binary,
`ExifToolCSVExportService`, etc.) — this does not port to iOS/iPadOS.
App Store sandboxing does not allow spawning arbitrary executables, so a
Ledger iPad app could not do the same depth of metadata writing the Mac
app does without either:
- a pure Swift/ImageIO-based metadata read/write layer (real, but
  narrower field coverage than ExifTool), or
- deferring actual metadata writes to the Mac app entirely.

Given that constraint, the shape that makes sense (not a design, just the
direction worth keeping in mind) is an iPad app scoped to **card-side
JPEG triage and organizing, handing off intent rather than doing
Lightroom-grade metadata work itself**:
- RAW import while travelling is already handled by Lightroom mobile
  today (the user's own existing practice) — an iPad Ledger app would not
  need to touch that side at all.
- The gap on iPad is the same as on Mac: nothing currently splits a card's
  JPEGs out and organizes them. An iPad app could read the card via
  Files/`UIDocumentPicker`, apply the same RAW/JPEG pairing logic, and
  file the JPEGs into an iCloud Drive folder using the same
  `YYYYMMDD - Place` convention.
- Lightweight native tagging (location/keywords/caption) at import time,
  without ExifTool, would cover immediate usability; a full metadata pass
  would still happen later on the Mac.
- The more structurally interesting idea, worth remembering rather than
  designing now: the iPad app stages *decisions* (which files are
  RAW/JPEG, what folder/keywords/location to apply) as a small file
  alongside the JPEGs in iCloud Drive, and the Mac app's existing
  prepare/apply pattern (already used for batch rename and metadata
  staging — see `BatchRenameStagingResult` in `AppModel+Actions.swift` for
  the existing shape of "stage now, apply later") picks it up and actually
  executes the ExifTool writes once reconnected. This keeps all
  ExifTool-dependent work exclusively on the platform that can run it.

Nothing here is scoped for implementation. Revisit once (a) the Mac-side
native device import above has some real shape, and (b) there's an actual
reason to prioritize a companion app over other v2.0+ work.
