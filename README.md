# Ledger

A native macOS photo metadata editor. Browse folders of images, edit EXIF, IPTC, and XMP fields in bulk, and write changes back to disk — all powered by ExifTool.

---

## Features

**Browse**
- Sidebar with Favourites, Recents, and Locations
- List and gallery browser views with adjustable zoom
- Sort by name, date, size, or kind
- QuickLook preview with arrow-key navigation

**Edit**
- Edit EXIF, IPTC, and XMP fields across single or multiple images simultaneously
- Stage rotate and flip operations before committing to disk
- Undo and redo metadata edits at the field level
- GPS coordinates shown on a map in the inspector

**Apply**
- Write changes to disk via ExifTool in one action
- Automatic backup before every write; restore from backup at any time
- Clear pending edits without writing

**Presets**
- Save, edit, and apply named metadata presets to any selection

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
