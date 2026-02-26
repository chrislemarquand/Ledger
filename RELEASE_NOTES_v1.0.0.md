# Ledger v1.0.0 (Draft)

## Highlights
- Added persistent sidebar favorites with pin, unpin, and simple reordering.
- Standardized file action labels and enable/disable logic across menu bar and list/gallery context menus.
- Added reduced-motion-aware animation handling for inspector transitions and focus scrolling.
- Added AppModel test coverage for favorites reconciliation, reorder behavior, and file action state transitions.

## Bug fixes and stability
- Removed main-actor isolation warning in split view resize observer callback.
- Added release check script scaffold for test/build/warning/bug-gate validation.

## Deferred to v1.0.1
- Full sidebar organizer (drag-and-drop groups/import-export).
- Final branding consolidation across all user-facing labels.
