# Ledger

**Edit your photo metadata the right way.**

Ledger is a native macOS app for browsing and editing photo metadata — EXIF, IPTC, and XMP — across single images or entire folders at once. It's built around ExifTool, the most trusted metadata engine available, wrapped in a clean, fast Mac interface.

---

## Why Ledger

Metadata tools are often slow, hard to use, or buried inside larger editing apps. Ledger focuses entirely on the job of reading and writing metadata: browsing your files, editing fields in bulk, and writing changes back to disk with a single action — with an automatic backup every time.

---

## Browse

- Three-panel layout with sidebar, browser, and inspector
- Sidebar with Favourites, Recents, and Locations; drag to reorder favourites
- Finder-style breadcrumb bar for the current folder location
- List, Icon, and Gallery browser views with adjustable zoom; Gallery pairs a
  filmstrip with a large preview, Finder-style
- Configurable list columns and Icon/Gallery subtitles — rating, camera, lens,
  date taken, title, rights, dimensions, and more
- iCloud Drive file-state indicators, so a cloud placeholder is clearly badged
  rather than looking like a broken thumbnail or a metadata load failure
- Rubber-band selection in gallery view
- Sort by name, date, size, or kind
- Quick Look preview with arrow-key navigation
- Dock badge showing pending edits, with Dock menu shortcuts for favourites, recents, and Open Folder

---

## Edit

- Edit EXIF, IPTC, and XMP fields across a single image or a whole selection simultaneously
- Star rating, pick flag, and colour label support
- **Adjust Date and Time** — shift by duration, set a time zone, set a specific date/time, or copy from file; apply to Original, Digitised, or Modified timestamps
- **Set Location** — interactive map with address search and advanced coordinate fields; GPS coordinates shown on a map in the inspector
- **Batch Rename** — token-based renaming with text, sequence, and date tokens; selection or folder scope; collision handling, extension override, and full restore support
- Copy a single field or a file's whole metadata set, and paste it onto other files
- Stage rotate and flip operations before committing to disk
- Undo and redo metadata edits at the field level

---

## Apply

- Write all pending changes to disk in one action via ExifTool
- Automatic backup before every write; restore from backup at any time
- Backup retention controls in Settings — keep the last N backups, or clear them all
- Clear pending edits without writing
- ExifTool console — a live readout of every ExifTool command and its output as operations run

---

## Canon EOS-1V

Connect a Canon EOS-1V directly over the ES-E1 cable, from its own sidebar
entry:

- Wake, search, and download shooting data with live status
- Shooting-data roll table with local delete/restore, and Canon-format CSV
  export verified byte-for-byte against real ES-E1 exports
- Named lens profiles — manage your own lens registry instead of a fixed
  built-in list
- Set the camera's on-board clock from the Date and Time tab

---

## Import and Export

- Import metadata from CSV, GPX track logs, reference folders, reference images, and Canon EOS-1V CSV exports
- Preview every import before writing; structured completion report
- Export an ExifTool CSV for external editing and re-import
- Export metadata to CSV or JSON for audit or spreadsheet workflows

---

## Presets

Save, edit, and apply named metadata presets to any selection.

---

## Handoff

Open selected files directly in Photos, Lightroom, or Lightroom Classic from the browser context menu.

---

## Supported Formats

JPEG, TIFF, PNG, HEIC/HEIF, DNG, ARW (Sony), CR2/CR3 (Canon), NEF (Nikon), ORF (Olympus), RW2 (Panasonic), RAF (Fujifilm)

---

## Requirements

- macOS 26 or later
- Apple silicon Mac

ExifTool is bundled — no separate installation required.

---

## Getting Ledger

Ledger is distributed as a signed and notarised direct-download app — no App Store required.

Download the latest release from the [Releases](https://github.com/chrislemarquand/Ledger/releases) page and open the DMG. Ledger checks for updates automatically using [Sparkle](https://sparkle-project.org).

---

## Open Source Acknowledgements

Ledger is built on the shoulders of several excellent open source projects:

- [ExifTool](https://exiftool.org) — © Phil Harvey (Artistic/GPL)
- [Sparkle](https://sparkle-project.org) — © 2006 Andy Matuschak et al. (MIT)

---

## License

Ledger is released under the [MIT License](LICENSE).

---

© 2026 Chris Le Marquand
