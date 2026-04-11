# Inspector Fields — Candidate Additions

Suggested fields to add to the inspector. All are writable via ExifTool and
togglable in Settings. Prioritised by Lightroom roundtrip value.

Current fields (already implemented): Make, Model, SerialNumber, LensModel,
FNumber, ExposureTime, ISO, FocalLength, ExposureCompensation, ExposureProgram,
Flash, MeteringMode, DateTimeOriginal, CreateDate, ModifyDate, GPSLatitude,
GPSLongitude, GPSAltitude, GPSImgDirection, Title (XMP-dc), Description (XMP-dc),
Subject (XMP-dc), Artist, Copyright, Creator (XMP-dc), Rating (XMP-xmp),
Label/Colour Label (XMP-xmp), Pick/Flag (XMP-xmpDM).

---

## Priority 1 — Lightroom Core ✓ Done

| Label | ExifTool Tag | Input Type | Notes |
|---|---|---|---|
| Rating | `XMP-xmp:Rating` | integer 0–5 | The Lightroom rating field. Use this — not `EXIF:Rating` (Microsoft-only, Lightroom ignores it). |
| Colour Label | `XMP-xmp:Label` | enum picker | Must be exact strings: `Red`, `Yellow`, `Green`, `Blue`, `Purple`. Lightroom users can rename labels in their catalog (e.g. "Red" → "Urgent") but the XMP value is always the raw colour name. Display with a coloured swatch. |
| Pick / Flag | `XMP-xmpDM:Pick` | enum picker | −1 = rejected, 0 = unflagged, 1 = picked. Written to XMP by Lightroom Classic since v13.2 (2024); catalog-only on older versions. |

### Notes
- **Rating −1 vs Pick**: Lightroom Classic uses both `XMP-xmp:Rating = -1` and
  `XMP-xmpDM:Pick = -1` for rejected state. Suggest Ledger exposes Rating as 0–5
  only, with a separate Rejected toggle backed by `XMP-xmpDM:Pick`, rather than
  surfacing −1 as a rating value.
- **Pick / Flag and LrC 13.2**: Before Lightroom Classic 13.2 (Oct 2024), flags
  were catalog-only and never written to XMP. A UI note may be warranted.

---

## Priority 2 — Location Detail

Natural extension of the existing GPS coordinate fields.

| Label | ExifTool Tag | Input Type | Notes |
|---|---|---|---|
| Sublocation | `XMP-iptcCore:Location` | text | Specific place within a city (e.g. "Tate Modern, Turbine Hall") |
| City | `XMP-photoshop:City` | text | Lightroom writes to both this and `IPTC:City` |
| State / Province | `XMP-photoshop:State` | text | |
| Country | `XMP-photoshop:Country` | text | |
| Country Code | `XMP-iptcCore:CountryCode` | text | ISO 3166 alpha-2/3 |

---

## Priority 3 — Editorial / Press

Useful for professional and archival workflows.

| Label | ExifTool Tag | Input Type | Notes |
|---|---|---|---|
| Headline | `XMP-photoshop:Headline` | text | One-line synopsis, distinct from Title |
| Caption Writer | `XMP-photoshop:CaptionWriter` | text | Who wrote the description |
| Credit | `XMP-photoshop:Credit` | text | e.g. "© Chris Lemarquand / Agency" |
| Source | `XMP-photoshop:Source` | text | Agency or originating organisation |
| Instructions | `XMP-photoshop:Instructions` | text | Handling/usage instructions |
| Job ID | `XMP-photoshop:TransmissionReference` | text | Lightroom's "Job Identifier" field |

---

## Priority 4 — Rights Detail

Extension of the existing Copyright field.

| Label | ExifTool Tag | Input Type | Notes |
|---|---|---|---|
| Copyright Status | `XMP-xmpRights:Marked` | boolean toggle | Copyrighted / Public Domain. Exposed in Lightroom's Copyright Status dropdown. |
| Usage Terms | `XMP-xmpRights:UsageTerms` | text | Licence terms |
| Copyright URL | `XMP-xmpRights:WebStatement` | text | Link to rights statement |

---

## Implementation Notes

### IPTC dual-write

Lightroom Classic writes XMP and IPTC fields simultaneously when saving metadata
to file. Ledger currently emits a single ExifTool tag per field (one write
argument in `ExifToolCommandBuilder.writeArguments`). For full Lightroom roundtrip
fidelity, fields with an IPTC counterpart should emit both tags in the same
ExifTool invocation. The mapping belongs as a static dictionary in
`ExifToolCommandBuilder` — no changes needed elsewhere in the pipeline.

Fields that do **not** need dual-writing: all EXIF camera/capture/date/GPS fields,
Rating, Pick/Flag, Colour Label, and all Priority 4 rights fields — none have
standard IPTC equivalents.

#### Current fields — need dual-write

| Field | Currently writes | Also write |
|---|---|---|
| Title | `XMP:Title` | `IPTC:ObjectName` |
| Description | `XMP:Description` | `IPTC:Caption-Abstract` |
| Keywords | `XMP:Subject` | `IPTC:Keywords` |
| Copyright | `EXIF:Copyright` | `IPTC:CopyrightNotice` |
| Creator | `XMP:Creator` | `IPTC:By-line` |

#### Priority 2 (Location Detail) — all need dual-write

| Field | XMP tag | Also write |
|---|---|---|
| Sublocation | `XMP-iptcCore:Location` | `IPTC:Sub-location` |
| City | `XMP-photoshop:City` | `IPTC:City` |
| State / Province | `XMP-photoshop:State` | `IPTC:Province-State` |
| Country | `XMP-photoshop:Country` | `IPTC:Country-PrimaryLocationName` |
| Country Code | `XMP-iptcCore:CountryCode` | `IPTC:Country-PrimaryLocationCode` |

#### Priority 3 (Editorial) — all need dual-write

| Field | XMP tag | Also write |
|---|---|---|
| Headline | `XMP-photoshop:Headline` | `IPTC:Headline` |
| Caption Writer | `XMP-photoshop:CaptionWriter` | `IPTC:Writer-Editor` |
| Credit | `XMP-photoshop:Credit` | `IPTC:Credit` |
| Source | `XMP-photoshop:Source` | `IPTC:Source` |
| Instructions | `XMP-photoshop:Instructions` | `IPTC:SpecialInstructions` |
| Job ID | `XMP-photoshop:TransmissionReference` | `IPTC:OriginalTransmissionReference` |

### Colour Label values
`XMP-xmp:Label` values are case-sensitive English strings. Lightroom will not
match a label unless it is exactly `Red`, `Yellow`, `Green`, `Blue`, or `Purple`.
An empty string removes the label.

### Tags to avoid
- `EXIF:Rating` / `EXIF:RatingPercent` — Microsoft-only tags (0x4746/0x4749),
  marked `Avoid` in ExifTool. Lightroom Classic does not read them.
- `XMP-lr:PrivateRTKInfo` — Lightroom internal opaque field. Do not write.
