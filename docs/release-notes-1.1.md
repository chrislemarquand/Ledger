# Ledger 1.1 — Release Notes

## What's New

### Import
Ledger now has a full import system for bringing metadata into your images from external sources. A single consistent sheet handles all five import types:

- **CSV** — import metadata from a spreadsheet, matched by filename or row order.
- **GPX** — tag images with GPS coordinates from a GPX track log.
- **Reference Folder** — copy metadata from a folder of reference images to your working set.
- **Reference Image** — apply metadata from a single image to a selection or whole folder.
- **EOS-1V** — import shooting data from a Canon EOS-1V CSV export, including lens resolution for ambiguous focal lengths.

Each import shows a preview before anything is written. If the import completes cleanly the sheet closes automatically; if there are warnings or conflicts it stays open with a structured report so you can review what happened.

### Settings
A new Settings window (Cmd+,) lets you control which metadata fields appear in the inspector, and enable or disable automatic backups.

### Export
All three export actions — ExifTool CSV, Send to Photos, and Send to Lightroom Classic — now ask you to confirm the scope (Selection or Folder) before proceeding. If you have unapplied changes, you'll be warned before handing off to Photos or Lightroom.

## Bug Fixes

- Apply confirmation is now a sheet attached to the main window rather than a blocking dialog.
- Inspector preview no longer shows a stale image after applying changes.
- Toolbar buttons now update immediately when switching between macOS Light and Dark mode.
- Settings panes size correctly and scroll from the top on open.
- Preset editor and manager no longer carry over stale state when reopened.
- Pluralisation corrected throughout ("1 file", not "1 files").
