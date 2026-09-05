# Native (ImageIO) EXIF Reader — Feasibility Scoping

Exploratory scoping only — nothing here is committed or scheduled. Written up 2026-09-05 after a
conversation working through the idea interactively; captures the reasoning, the real measurements
taken during that conversation, and what a real spike would need to answer next.

## The original question

Folder loads feel instant for filesystem data (name, size, dates) but slow for EXIF data to
arrive. The question: would writing our own Swift-based EXIF reader (via Apple's ImageIO
framework) meaningfully improve read performance over the current exiftool-subprocess pipeline?

The user's own starting hypothesis was skeptical, reasoning that metadata has to be read from disk
on every folder load regardless of implementation language, and that a persistent cache (GRDB/Core
Data) would be a large undertaking with an unsolved staleness problem, so probably not worth it.

## Verdict on the caching-layer half of the question

**Agreed, no further investigation warranted.** A persistent metadata cache doesn't avoid the
fundamental problem — correctness still requires either a filesystem-watcher invalidation system
(complex, unreliable once other apps touch the same files) or staleness tolerance with manual
refresh, which is materially what the app already does *in memory* today
(`AppModel.metadataByFile` + `staleMetadataFiles`), just not persisted across launches. The only
thing a persistent store buys is surviving relaunches, which is a small win relative to its
complexity and staleness risk. Independent of the native-reader question below — not worth
pursuing on its own.

## Verdict on native (ImageIO) reads: real, measured upside — but not a slam dunk

The premise "it must be read from disk anyway, so there's no room to improve" turned out not to be
the right framing. The dominant cost in the current pipeline isn't disk I/O or parsing — it's
**process-spawn overhead**, and the ceiling on how far that can be pushed down without changing the
implementation is not where the real gain lives.

### What's already been measured (from `docs/v1.4-progress.md`'s Phase 2.1 work)

- Opening a folder with **no** metadata column/subtitle enabled: 220 → 0 exiftool subprocess
  launches after Phase 2.1's demand-gating, ~177–392ms total for a 1,012-file corpus. Metadata
  reading is already off by default unless something visible needs it.
- Opening the same 1,012-file folder **with** a metadata column enabled: **127 exiftool subprocess
  launches spanning ~33 seconds**, confirmed via direct `ps -o %cpu` sampling (sustained 90–130%
  CPU) and via `ExifToolProcess`/`FolderMetadataPrefetch` signposts.

### Fresh benchmarks taken this session, against the real perf corpus (`scripts/performance/corpus/browse`)

| Approach | Time | Per-file |
|---|---|---|
| exiftool, 1 process reading a 20-file batch (today's actual batching) | 101ms | ~5ms |
| exiftool, 5 separate single-file spawns | 283ms | ~56.6ms/spawn |
| Native ImageIO (`CGImageSourceCopyPropertiesAtIndex`), in-process, 20 files | 13.8ms | ~0.7ms |

The dominant cost is Perl interpreter + `Image::ExifTool` module load per process spawn
(~50–60ms), not disk I/O or parsing. The existing batch-of-20 already amortizes this well — a
native in-process reader is still roughly **7–8x faster than the already-optimized exiftool
path**, with zero subprocess overhead at all. Extrapolated (not re-measured at full scale) to the
1,012-file case, ImageIO's ~0.7ms/file rate implies well under a second for the whole folder,
versus the ~33s measured for the metadata-column-enabled exiftool case.

### Field coverage: better than the "ImageIO is basic" stereotype, checked against a real file

Dumped `CGImageSourceCopyPropertiesAtIndex` + `CGImageSourceCopyMetadataAtIndex` against a real
corpus JPEG (`5I6A5704.JPG`, Canon EOS 5D Mark IV). Findings, not assumed:
- Full standard EXIF/TIFF/GPS/IPTC dictionaries, cleanly keyed.
- A `{MakerCanon}` dictionary — Canon MakerNote data — plus `{ExifAux}` and `{PictureStyle}`.
- 66 XMP tags via the generic `CGImageMetadataTag` API, including `exif:`/`tiff:`/`aux:` namespace
  mirrors and a `rating` field in the XMP core (`xap`) namespace.
- XMP itself is a genuinely helpful case: it's just RDF/XML, so `CGImageMetadataCopyTags` walks
  whatever's actually embedded rather than being limited to a fixed, Apple-blessed vocabulary the
  way the EXIF/TIFF/GPS/IPTC dictionaries are. Any XMP field Ledger cares about should be reachable
  this way as long as the file actually has that block populated — this wasn't exhaustively
  verified across every namespace Ledger uses (`.xmpDM`/`.xmpRights` specifically weren't seen
  populated in the one sample file checked, which may just mean this file has no rights metadata
  rather than a coverage gap).

### The actual hard part: it's not naming, it's that exiftool disagrees with itself

The instinct that "mapping would be easy since exiftool is open source" is half right — reading
exiftool's source is genuinely useful for understanding its *composite/derived* tag formulas
(exact recipes for things like combining GPS ref+magnitude into a signed value). But it doesn't
make ImageIO's independently-written parser produce the same answer, and the belief that common
fields are easy to match is true **because EXIF/TIFF/XMP are published standards both tools
implement against the same spec** — not because exiftool's source is readable. You don't need
Phil Harvey's Perl to know what `FNumber` means; Apple's engineers didn't either.

**Concrete finding, from a real CR2 in the corpus (`5I6A8634.CR2`)**, asking exiftool for exactly
Ledger's field catalog (`AppModel.EditableTag.common`) split by which internal group each value
comes from:

| Field | ExifIFD (standard) | Canon MakerNote / Composite | Agree? |
|---|---|---|---|
| ISO | 2000 | 2074.94 (Composite) | **No** |
| FNumber | 7.1 | 7.127 (Canon) | No (rounding) |
| ExposureTime | 0.008 | 0.00716 (Canon) | **No** |
| MeteringMode | 5 | 3 (Canon) | **No — different enum code entirely** |
| GPSLongitude | 0.221375 | -0.221375 (Composite, sign-corrected) | Expected (needs combining) |
| Make / Model / LensModel / FocalLength / WhiteBalance / ExposureCompensation | agree | agree | Yes |

**exiftool disagrees with itself**, depending on whether you read the standard EXIF tag or the
manufacturer's own MakerNote-derived version of the same concept — for exactly the fields a
photographer cares about most (exposure, ISO, metering). Ledger's own current code doesn't
explicitly pick one: `ExifToolService.parseSnapshot` iterates every group:key pair exiftool
returns, and both e.g. `ExifIFD:ISO` and `Composite:ISO` become separate `MetadataField`s that
collide on the same internal id (`MetadataField.id = "\(namespace.rawValue):\(key)"`, since both
groups normalize to the same `.exif` namespace) — so which value actually reaches the UI today
depends on array/iteration order, not a deliberate choice. This is a pre-existing quirk, not
something this scoping pass fixed, but it means **"match what exiftool says" isn't a single
well-defined target** — a native reader would first need a deliberate decision about which of
exiftool's own competing answers is the one to replicate, for each ambiguous field.

**SerialNumber / LensSerialNumber risk, not yet tested**: these were not verified against an
actual EOS-1V capture (Ledger's marquee-supported camera). Older-camera serial numbers are often
MakerNote-only fields with no standard-EXIF equivalent, which is exactly the kind of thing
ImageIO's smaller MakerNote parser may not cover as deeply as exiftool's ~20-year reverse-engineered
tables. This needs a real EOS-1V-sourced RAW file, not assumed from the one modern 5D Mark IV
JPEG/CR2 checked so far.

### Why this stays read-only

ImageIO's write-back support for embedding IPTC/XMP is far more limited/fragile than exiftool's —
nobody is proposing replacing exiftool for writes. That means this would be a **permanent
two-pipeline architecture** (native read + exiftool write), with a real, ongoing risk of the two
disagreeing on some field — the same "two paths sharing one piece of state" shape that has already
caused at least one real regression in this codebase (the metadata-copy/paste incident referenced
in `docs/menu-bar-architecture-audit-2026-08.md`), just a different specific mechanism.

## Recommendation

Worth a real, scoped exploratory spike — not a quick patch, and not a "just do it," given the
concrete disagreement found above. If pursued:

1. Build a narrow, read-only `ImageIOMetadataReader` covering exactly `AppModel.EditableTag.common`
   (~35 fields) — not a general-purpose EXIF reader.
2. For each field where exiftool's own groups already disagree (ISO, ExposureTime, MeteringMode,
   FNumber, GPS sign-combining), make an explicit decision about which value to target, rather than
   silently picking whichever ImageIO happens to expose.
3. Build a diff tool comparing the new reader's output against exiftool's actual output across the
   whole real perf corpus (`scripts/performance/corpus/browse`) — JPEG, TIFF, and CR2 at minimum —
   for exactly the fields in the catalog. Get an actual EOS-1V-sourced file into the corpus for
   this specifically; none of the CR2s checked during this scoping pass were confirmed to be from
   an EOS-1V.
4. Only invest in wiring this into the real app (folder-load, inspector, prefetch) if the mismatch
   rate from step 3 is low and every mismatch is individually understood and either acceptable or
   fixable, not just "close enough."
5. If pursued, this is naturally a v2.0+/post-v2.0 item — no dependency on anything currently
   in-flight, and the read-only, additive nature means it could land on its own timeline whenever
   picked up.

## What this doc is not

Not a plan with tasks/stages the way `docs/eos1v-roll-metadata-plan-2026-08.md` or
`docs/import-conflict-resolution-plan-2026-08.md` are — those describe committed work. This is a
feasibility scoping pass for an idea that hasn't been decided on yet. See `docs/ROADMAP.md`'s new
"Post-v2.0 — Exploratory / Under Investigation" section for where this sits relative to committed
work.
