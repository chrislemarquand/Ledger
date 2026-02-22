# v1.0.0 Bug Backlog

## Severity rubric
- `P0`: data loss, crash, or corruption.
- `P1`: broken core workflow.
- `P2`: polish and usability issues.

## Open issues
- [ ] `P1` Verify context-menu parity and enabled states in list/gallery/menu bar across mixed selections.
- [ ] `P1` Verify favorites pin/unpin/reorder flows after relaunch and invalid path cleanup.
- [ ] `P2` Validate reduced-motion behavior for inspector section expand/collapse and field focus scrolling.
- [ ] `P2` Full manual QA matrix execution and sign-off (open/apply/refresh/restore, presets, GPX import).

## Closed during this pass
- [x] `P1` Remove actor isolation warning for split resize observer callback (`MainContentView.swift`).
