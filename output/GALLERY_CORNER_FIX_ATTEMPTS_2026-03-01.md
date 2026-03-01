# Gallery Corner Regression - Attempt Log (2026-03-01)

Issue reported:
- In gallery view, thumbnail corners appear square on folder load, then switch to rounded only after a pending-edit orange dot appears.
- Expected: rounded corners at all times.

## Attempts made in this session

1. Inspector spinner centering
- File: `Sources/Ledger/InspectorView.swift`
- Change: centered loading `ProgressView`.
- Status: kept.
- Reason: separate UX issue, confirmed desired.

2. Inspector pending-dot layout isolation
- File: `Sources/Ledger/InspectorView.swift`
- Change: moved loading spinner and pending-dot to `.overlay(...)` so pending-dot does not change preview image layout/size.
- Status: kept.
- Reason: fixes inspector preview image resize when pending-dot appears.

3. Inspector rounded-corner experiments
- File: `Sources/Ledger/InspectorView.swift`
- Changes attempted:
  - Always-on rounded background layer.
  - Extra clip/contentShape layering.
  - Direct image clipShape for rounded corners.
- Outcome: did not solve reported gallery-corner issue.
- Status: reverted.

4. Gallery thumbnail container corner clipping
- File: `Sources/Ledger/BrowserGalleryView.swift`
- Changes attempted:
  - Added corner radius + masksToBounds on `thumbnailContainer`.
  - Added/remixed corner settings between `thumbnailContainer` and `thumbnailImageView`.
  - Added `cornerCurve = .continuous` on involved layers.
- Outcome: user reported issue persisted.
- Status: reverted.

## Current state after requested rollback

Reverted:
- Gallery corner-style experiments in `BrowserGalleryView.swift`.
- Inspector corner-style experiments in `InspectorView.swift`.

Kept (per request):
- Inspector loading spinner centered.
- Inspector pending-dot no longer shrinks preview image.

## Notes for handoff

Most likely root-cause area to investigate next:
- `AppKitGalleryItem` render/update lifecycle in `Sources/Ledger/BrowserGalleryView.swift`.
- Specifically interaction between initial image assignment (`setImage`), thumbnail pipeline fallback image, and cell state refresh (`configure` / `refreshVisibleCellState`).
- Verify whether first-render image source differs (e.g., fallback icon template vs decoded image) and whether that source carries/ignores layer masking until pending state triggers a redraw path.
