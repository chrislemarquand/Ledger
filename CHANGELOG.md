# Changelog

## 0.5 - 2026-02-24
- Unified thumbnail generation/request path across Gallery and List via a shared broker and global cache usage.
- Simplified Quick Look transitions to native frame-driven behavior by removing custom transition-image plumbing.
- Improved inspector metadata continuity during rotate/apply flows by keeping last-known metadata visible while refresh completes.
- Fixed gallery selection ring orientation/size mismatches and stabilized ring behavior during rapid rotate/selection changes.
- Tuned gallery selector visuals:
  - border thickness increased to `3.5`
  - added configurable outward selector gap around thumbnails.
- Improved keyboard responder handoff when switching Gallery/List view modes to avoid inactive-state row skipping.
- Added regression tests for rotate/apply metadata continuity and staged image-op normalization.
- Consolidated UI metrics into shared tokens for cleaner, more maintainable visual tuning.

## 0.4 - 2026-02-22
- Added `Reveal in Finder` to image/file context menus in both Gallery and List views (positioned below `Open in ...`).
- Added `Open in Finder` to sidebar item context menus (including Source items).
- Updated sidebar context menu entries to use SF Symbols.
- Simplified sidebar menu naming:
  - `Pin to Pinned` -> `Pin`
  - `Unpin Pinned` -> `Unpin`
- Matched sidebar context menu icon color to standard menu text color (non-accented).
