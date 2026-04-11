# Ledger

A native macOS photo metadata editor. Browse folders of images, edit EXIF, IPTC, and XMP fields in bulk, and write changes back to disk — all powered by ExifTool.

---

## Features

**Browse**
- Sidebar with Favourites, Recents, and Locations; drag to reorder favourites
- Finder-style breadcrumb bar for the current folder location
- List and gallery browser views with adjustable zoom
- Configurable list columns with metadata-backed values (rating, camera, lens, date taken, title, rights, dimensions)
- Rubber-band selection in gallery view
- Sort by name, date, size, or kind
- QuickLook preview with arrow-key navigation
- Dock pending-edits badge and Dock-menu shortcuts for favourites, recents, and Open Folder

**Edit**
- Edit EXIF, IPTC, and XMP fields across single or multiple images simultaneously
- Star rating, pick flag, and colour label alongside expanded EXIF / IPTC / XMP field coverage
- **Adjust Date and Time**: shift by duration, set time zone, set a specific date/time, or copy from file; apply to Original, Digitised, or Modified tags
- **Set Location**: interactive map with address search and advanced coordinate fields
- **Batch Rename**: token-based rename with text, sequence, and date tokens; selection or folder scope; collision handling, extension override, and restore support
- Stage rotate and flip operations before committing to disk
- Undo and redo metadata edits at the field level
- GPS coordinates shown on a map in the inspector

**Apply**
- Write changes to disk via ExifTool in one action
- Automatic backup before every write; restore from backup at any time
- Backup retention controls (keep-last-N) and clear-backups action in Settings
- Clear pending edits without writing
- Handoff to Photos, Lightroom, and Lightroom Classic from browser context menus

**Import / Export**
- Import metadata from CSV, GPX track logs, reference folders, reference images, and Canon EOS-1V CSV exports
- Preview every import before writing; structured report on completion
- Export an ExifTool CSV for external editing and re-import
- Export metadata to CSV or JSON for audit or spreadsheet workflows

**Presets**
- Save, edit, and apply named metadata presets to any selection

**Settings**
- Control which metadata fields appear in the inspector
- Enable or disable automatic backups; configure backup retention

---

## Supported formats

JPEG, TIFF, PNG, HEIC/HEIF, DNG, ARW (Sony), CR2/CR3 (Canon), NEF (Nikon), ORF (Olympus), RW2 (Panasonic), RAF (Fujifilm)

---

## Requirements

- macOS 15 or later
- Apple Silicon or Intel Mac

ExifTool is bundled — no separate installation required.

---

## Installation

Download the latest release from the [Releases](../../releases) page, unzip, and drag **Ledger.app** to your Applications folder.

---

## Development tests

Run the full suite with:

```bash
./scripts/test/run_all.sh
```

This uses `swift test --parallel`, which is the stable mode for this project environment.

---

## Credits

Powered by [ExifTool](https://exiftool.org/) by Phil Harvey.

---

## License

© 2026 Chris Le Marquand. All rights reserved.
