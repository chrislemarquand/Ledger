# Stacks — Plan — 2026-09-26

Directional scoping for a v2.0+ feature, written up at the user's request
during the "Bridge competitor" v2.0 positioning conversation. **This is
speculative, not committed** — no code has changed. Tracked from
`docs/ROADMAP.md`'s v2.0+ → Browse section.

## The idea

Group related files (most immediately: RAW+JPEG pairs from a single
shutter press) into one visual unit in the browser — Lightroom/Bridge's
"Stacks" concept. Raised alongside the device-import RAW/JPEG-split work
(`docs/native-device-import-plan-2026-09.md`) and Cull Mode
(`docs/cull-mode-plan-2026-09.md`) — the same pairing detection those
features need is the same detection Stacks needs, so this should share
logic with both rather than being built three times.

## How Lightroom/Bridge actually do this (checked, not assumed)

Worth being precise here because the user's initial framing ("metadata
should be shared between them... RAW/JPG is a simple metadata match")
describes something **neither Lightroom nor Bridge actually does**.
Their Stacks are a purely visual/organizational grouping mechanism:
- Files are grouped (manually, or via "Auto-Stack by Capture Time" in
  Lightroom) into a collapsible unit with one representative "top" image.
- Collapsing/expanding, reordering within the stack, and promoting a
  different member to the top are all UI-only operations.
- **Metadata is never synchronized between stack members by either
  app.** Each file keeps fully independent metadata; a RAW and its
  paired JPEG can drift apart (e.g. edit one, not the other) with no
  warning or reconciliation from the stack mechanism itself.

So a literal "equivalent to Lightroom/Bridge Stacks" would just be visual
grouping, nothing more — the metadata-sharing idea is a deliberate
**departure/improvement** from how the reference tools behave, not a
port of existing behaviour. Worth being explicit about that distinction
before designing, since it changes what "stacks" means for Ledger.

## The real design question: which fields sync, and for which stack types

The user's own framing already identifies the right axis, just needs
sharpening: **RAW+JPEG pairs are the same exposure, same shutter press —
almost every field is identical or should be kept identical.** Bracketed
exposures, panorama sequences, or focus-stack frames are *different*
exposures of the same subject — some fields are naturally shared
(keywords, GPS, rating/pick flag, caption — properties of the *subject/
scene*), while others are naturally per-frame and should never be forced
to match (shutter speed, aperture, ISO, exact capture timestamp — where
brackets differ by design, sometimes by more than a second).

Proposed field classification (needs real confirmation against Ledger's
actual field catalog before implementation, not assumed):
- **Always-sync fields** (subject/organizational — sync across every
  stack type, RAW+JPEG or bracket alike): keywords, GPS/location,
  rating, pick flag, colour label, caption/description, copyright.
- **Never-forced fields** (capture-technical — never auto-synced,
  differ legitimately even within a RAW+JPEG pair in rare cases, e.g. a
  camera that processes JPEG with different white balance than the RAW's
  as-shot value): exposure settings, white balance, lens data.
- **RAW+JPEG-specific**: since these two are definitionally the same
  exposure, the technical fields *should* actually match in practice —
  worth deciding whether Ledger enforces/repairs drift here (a "these
  should match but don't" warning) rather than just leaving the
  never-forced category permanently silent for this stack type
  specifically.

## What already exists to build on

- The RAW/JPEG pairing detection this needs is the same detection the
  device-import plan already identifies as needed
  (`docs/native-device-import-plan-2026-09.md`'s "RAW+JPEG pair
  detection" open question) — one shared implementation, not two.
- Ledger's existing field catalog (`orderedEditableTagSections`, per
  `AppModelTests.testOrderedEditableTagSectionsFollowFieldCatalogSectionOrder`)
  already has a notion of field sections/ordering — the always-sync/
  never-forced classification above should be expressed against that
  existing catalog structure, not a new parallel one.
- Existing batch-apply/paste machinery (`AppModel+MetadataClipboard.swift`,
  preset system) already knows how to apply a field set to multiple
  files — stack-sync could reuse that mechanism rather than inventing new
  propagation code.

## Open questions (need real design decisions, not assumptions)

- **Stack UI**: collapsed/expanded like Lightroom (one row/cell
  represents the whole stack, expandable), or a lighter-weight badge/
  grouping indicator that never actually hides members? Interacts with
  existing List/Icon/Gallery view modes — needs a design pass per view
  mode, not just one.
- **When does sync happen**: live (editing one member immediately
  propagates to synced fields on the rest of the stack), or on-demand
  (an explicit "Sync Stack" action, safer but adds a step)? Live sync
  risks surprising a user who didn't realize a field was stack-linked;
  on-demand is safer but weaker as a feature.
- **Auto-detection vs. manual stacking**: RAW+JPEG pairing can likely be
  fully automatic (basename match, verified camera behaviour). Bracket/
  panorama grouping is much harder to detect reliably and may need to
  stay manual (user selects frames, "Group into Stack"), at least
  initially.
- **Drift handling for RAW+JPEG's technical fields**: does Ledger warn,
  auto-repair, or silently ignore the case where the same physical
  exposure was captured with different EXIF-source technical values
  between the RAW and its parallel JPEG?
- **Interaction with Cull Mode**: does culling a stack cull all members
  together (reject the RAW, reject the JPEG) or can members be
  independently picked/rejected within a stack? Needs to be decided
  jointly with `docs/cull-mode-plan-2026-09.md`, not separately.
