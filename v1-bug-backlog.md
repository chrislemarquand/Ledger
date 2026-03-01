# v1.0.0 Bug Backlog

## Severity rubric
- `P0`: data loss, crash, or corruption.
- `P1`: broken core workflow.
- `P2`: polish and usability issues.

## Open issues
- [ ] `P1` Folder-switch UX regression: opening a folder can briefly flash the "No Supported Images" empty state before thumbnails render. Marked as a regression from earlier builds and currently unresolved; attempted fixes were reverted (`267d49f`, `2c8658a`).
- [ ] `P1` Verify context-menu parity and enabled states in list/gallery/menu bar across mixed selections.
- [ ] `P1` Verify favorites pin/unpin/reorder flows after relaunch and invalid path cleanup.
- [ ] `P2` Validate reduced-motion behavior for inspector section expand/collapse and field focus scrolling.
- [ ] `P2` Full manual QA matrix execution and sign-off (open/apply/refresh/restore, presets, GPX import).

## Closed during this pass
- [x] `P1` Remove actor isolation warning for split resize observer callback (`MainContentView.swift`).
