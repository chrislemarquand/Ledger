# Ledger 1.2 — Release Notes

## What's New

### Batch Rename

Ledger 1.2 adds a full first release of Batch Rename. You can preview filename changes before anything is written, apply them to a selection or a whole folder, use text / sequence / date tokens, override extensions, and restore renamed files from backup if you need to roll the operation back.

### Inspector and Metadata Workflows

The inspector now covers a much broader set of metadata. Rating, flag, and colour label are available alongside expanded EXIF, IPTC, and XMP sections for camera, capture, date and time, location, descriptive, editorial, and rights fields. Field visibility remains configurable in Settings.

### Browser Productivity

This release also adds a Welcome / What's New screen, a Finder-style breadcrumb bar, a pending-edits Dock badge, Dock-menu shortcuts for favourites and recent folders, drag-to-reorder favourites, and configurable list columns with metadata-backed values.

### Browser Interaction and Handoff

Gallery view now supports rubber-band selection, and list/gallery browser surfaces now expose direct handoff to Photos, Lightroom, and Lightroom Classic from their context menus.

### Backups and Export

Backups are more practical in 1.2. Settings now includes retention controls and a clear-backups action, and rename-backed restore flows are part of the normal backup path. Metadata can also be exported to CSV or JSON for audit or spreadsheet workflows.

## Quality Improvements

- Browser keyboard, focus, and selection behavior were hardened across the AppKit / SharedUI browser path.
- Thumbnail and preview loading now use a more robust shared cache and broker pipeline.
- Restore from Backup correctly follows files through rename-backed apply and restore flows.
