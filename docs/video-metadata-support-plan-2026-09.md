# Video Metadata Support — Plan — 2026-09-26

Directional scoping for a v2.0+ feature, written up at the user's request
during the "Bridge competitor" v2.0 positioning conversation, prompted by
the observation that a digital camera's card usually has video clips
(MOV/MP4) alongside stills, and today's import/browsing entirely ignores
them. **This is speculative, not committed** — no code has changed.
Tracked from `docs/ROADMAP.md`'s v2.0+ → Browse section.

## Current state (verified against code)

Video is currently invisible to Ledger everywhere. `AppModel.swift:731`'s
`supportedImageExtensions` — the single whitelist every folder
enumeration (`enumerateImages`, `enumerateImagesRecursively`,
`countSupportedImages`) filters against — is:

```swift
["jpg", "jpeg", "tif", "tiff", "png", "heic", "heif", "dng", "arw", "cr2", "cr3", "nef", "orf", "rw2", "raf"]
```

No video extension appears anywhere. A card with MOV/MP4 clips on it
today just has those files silently skipped during enumeration — not
shown as unsupported, not shown at all.

## The ExifTool question — answered empirically, not assumed

The user's stated uncertainty ("I don't know if exiftool can handle
video metadata so we might need to consider a separate engine") was the
right thing to check rather than guess on, given this session's own
established pattern of verifying platform/tooling capability empirically
before designing against it. Tested directly against the same ExifTool
version Ledger bundles (13.55), reading and writing a real `.mov` file
(a copy of a bundled system asset, never a real user file):

- **Read support** (`exiftool -listf`): `AVI`, `HEIC`, `HEIF`, `M4V`,
  `MOV`, `MP4`, `MTS` are all readable.
- **Write support** (`exiftool -listwf`): only `M4V`, `MOV`, `MP4` are
  writable — the QuickTime-container family. `AVI` and `MTS` (AVCHD,
  common on older camcorders/action cams) are **read-only**.
- **Confirmed live** on a real `.mov` file: writing
  `QuickTime:CreateDate` (a native QuickTime atom), `XMP:Keywords`, and
  GPS latitude/longitude (landed in the file's embedded XMP, read back
  correctly via `-GPS:all` and the `Composite` GPS tags) all succeeded
  and read back correctly after the write.

**Conclusion: no separate metadata engine is needed for the common
case.** ExifTool — the same engine, same bundled binary Ledger already
ships — reads and writes MOV/MP4/M4V's metadata, both native QuickTime
atoms and embedded XMP, exactly as it does for stills. The user's
instinct that **separate UI fields** would be needed is correct and is
the real work here: video metadata lives in a different tag group
(`QuickTime:*`) with a different vocabulary than a still's `EXIF:*`/
`IPTC:*`/`XMP:*` tags (e.g. `QuickTime:CreateDate` vs. a photo's
`EXIF:DateTimeOriginal`), so Ledger's field catalog needs new entries
mapping to those tags — not a new engine underneath them.

The one real gap: **AVI and MTS are read-only**. Any camera/camcorder
that records video in one of those (rather than MOV/MP4/M4V) would be
viewable/reportable in Ledger but not editable. Worth checking what
format the user's own gear actually records video in before treating
this as a non-issue — if it's MOV or MP4 (true for the great majority of
modern mirrorless/DSLR cameras' video mode), this doesn't matter; if it's
older AVCHD/MTS gear, it would.

## Export/handoff destination — open, not resolved here

The user's assumption was that video "wouldn't go in Lightroom/Lightroom
Classic" and would go to Photos.app instead. This wasn't independently
verified in this session (unlike the ExifTool question, which was
directly testable locally) — Adobe's current video support in Lightroom
CC/Classic isn't something this session checked against real behaviour,
so **treat that assumption as unconfirmed, not settled**, before scoping
a specific handoff path. What is confirmed: `sendToPhotos(_:)`
(`AppModel+Actions.swift`) stages files into a temp directory and opens
them via Photos.app — Photos.app has long supported video natively, so
that path should work unchanged for video files once Ledger can select
them at all; extending `sendToLightroom`/`sendToLightroomClassic` to
video (if Adobe's apps do support it) would need the same live-verification
discipline as everything else in this plan, not an assumption either way.

## Scope (proposed — needs confirmation, not yet agreed)

In scope, if this goes forward:
- Add MOV/MP4/M4V (the writable set) to folder enumeration, at least
  initially — AVI/MTS could be added as read-only-visible later once the
  UI has a story for "this file's metadata can't be edited here."
- A new field-catalog section for video-specific fields (`QuickTime:*`
  tags), separate from the existing photo field sections but reusing the
  same editing UI patterns (`InspectorTagFieldView` variants) where the
  underlying value shape matches (dates, GPS, keywords/XMP fields are
  structurally the same across photos and video once mapped to the right
  tag names).
- Thumbnail/preview generation for video (a poster frame, likely via
  AVFoundation `AVAssetImageGenerator` rather than ExifTool, which
  doesn't do image extraction) — a genuinely new piece of work, not
  covered by the ExifTool findings above at all.

Explicitly out of scope for now:
- Any video playback/editing/trimming — Ledger doesn't do image editing
  either; this is a metadata tool, not a media editor, for video the same
  as for stills.
- AVI/MTS write support — not possible via ExifTool; would need a
  different engine entirely if ever pursued, and there's no indication
  yet that it's needed.

## Open questions (need real answers, not assumptions)

- What video format does the user's actual camera gear record in? Decides
  whether the AVI/MTS read-only gap matters at all.
- Does Lightroom CC/Classic actually support video import today, and if
  so does `NSWorkspace.open(_:withApplicationAt:)` (the same mechanism
  `sendToLightroom` already uses) work for video files the same way it
  does for stills? Needs live testing against the real apps, not assumed
  from the user's recollection or this session's general knowledge.
- How does video fit the RAW+JPEG Stacks idea (`docs/stacks-plan-2026-09.md`)
  — a camera shooting RAW+JPEG+video-alongside-stills produces a third,
  unrelated file per "moment" rather than a pair; likely just excluded
  from stacking rather than force-fit into the pairing model, but worth
  an explicit decision.
- Poster-frame thumbnail generation performance/caching — should reuse
  the existing thumbnail disk-cache infrastructure (v1.4 Phase 3.3) once
  a poster frame exists, not build a parallel cache.
