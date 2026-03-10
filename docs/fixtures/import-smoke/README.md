# Import Smoke Fixtures

These fixtures support the manual smoke checklist at `docs/v1.1-smoke-checklist.md`.

## Files

- `exiftool-safe.csv`: CSV with unique `SourceFile` values (`001.jpg`..`003.jpg`) for filename auto-match.
- `exiftool-fallback-row-order.csv`: CSV that should force row-order fallback (blank + duplicate `SourceFile`).
- `exiftool-review-warnings-partial.csv`: CSV for post-import review mode on successful import (parser warnings + partial outcomes when `If no match` is `Skip`).
- `exiftool-review-conflicts.csv`: CSV with missing filenames to trigger unresolved conflicts and post-import review mode.
- `eos1v-smoke.csv`: EOS 1V sample with 3 frames.
- `gpx-smoke.gpx`: GPX sample with two points around `2026-01-01T12:00:00Z`.

## Reference Folder Import

Reference-folder fixtures depend on real image metadata, so create them from your target folder:

1. Make a folder `docs/fixtures/import-smoke/reference-folder` (already present).
2. Copy one or more real images from your active target folder into it.
3. Keep filenames identical to target files (for matching).
