# Gallery Thumbnail Corner Radius — Debug Session 2 (2026-03-01)

## Bug

In gallery view, thumbnails display with square corners after the real thumbnail has
loaded. Rounded corners only appear after the pending-edit orange dot appears for a
file. Expected: rounded corners at all times.

**Important correction to the previous session's handoff note:** The bug persists even
after the real decoded thumbnail has replaced the fallback workspace icon. It is not
limited to the fallback-icon phase. The square corners are visible on fully-loaded
real photos. This rules out the "NSIconImageRep vs CGImage rendering path" theory as
the primary cause.

---

## What the code is supposed to do

In `AppKitGalleryItem.configureViewHierarchy()` (`BrowserGalleryView.swift`):

```swift
thumbnailImageView.wantsLayer = true
thumbnailImageView.layer?.cornerRadius = UIMetrics.Gallery.thumbnailCornerRadius  // 8pt
thumbnailImageView.layer?.masksToBounds = true
```

This is the standard native AppKit approach for rounded corners on a layer-backed view.
It should work. It demonstrably does not.

The pending-edit path calls `refreshVisibleCellState(needsFullReconfigure: true)` →
`cell.configure(...)` → `setImage(...)` + `updateTileSide(...)`. After that configure
call, corners appear rounded. The code path is ostensibly identical to the initial
configure call — same methods, same layer properties already set — yet it behaves
differently.

---

## Attempts made in this session

All three attempts were made to `BrowserGalleryView.swift` only.
`InspectorView.swift` was not touched.

---

### Attempt 1 — Re-apply cornerRadius in `setImage()` after image assignment

**Theory:** NSImageView replaces its backing CALayer when `image` is first assigned
(nil → first image). The layer created by `wantsLayer = true` in `configureViewHierarchy()`
gets properties set, but when `thumbnailImageView.image = someImage` is called,
NSImageView internally creates a new layer optimised for image rendering. That new
layer has default `cornerRadius = 0` and `masksToBounds = false`.

**Change:** Added two lines at the end of `setImage()`, after every image assignment:

```swift
thumbnailImageView.layer?.cornerRadius = UIMetrics.Gallery.thumbnailCornerRadius
thumbnailImageView.layer?.masksToBounds = true
```

**Result:** No change. Corners still square after real thumbnails loaded.

**Why it likely failed:** `setImage()` is called from `configure()`, which also calls
`updateTileSide()`. `updateTileSide()` changes `imageWidthConstraint.constant` and
`imageHeightConstraint.constant`. Auto Layout then runs a layout pass and updates
`thumbnailImageView.frame`. If NSImageView reconfigures its layer when its frame
changes (or at any point during that layout pass), the properties set moments earlier
in `setImage()` are wiped before rendering. This is consistent with the observation
that the pending-edit path — which also calls `configure()` → `updateTileSide()` →
layout — somehow fixes the corners, suggesting the fix needs to happen AFTER layout
settles, not before.

---

### Attempt 2 — Wrap `thumbnailImageView` in a plain `NSView` clip container

**Theory:** NSImageView has unusual internal layer management that makes its own layer
unreliable for `cornerRadius`/`masksToBounds`. A plain `NSView` has stable layer
management. `NSView.layer.masksToBounds = true` on a plain view clips all of its
sublayers — including a child NSImageView's layer — to the parent's rounded bounds.

**Change:** Added a `clipContainer: NSView` between `thumbnailContainer` and
`thumbnailImageView`. `clipContainer` got `wantsLayer = true`, `cornerRadius = 8`,
`masksToBounds = true`. `thumbnailImageView` filled `clipContainer` via all-sides
constraints. The fitted-size constraints (`imageWidthConstraint`,
`imageHeightConstraint`) moved to `clipContainer` instead of `thumbnailImageView`.

**Result:** No change. Corners still square.

**Why it likely failed:** Same root cause as Attempt 1. The Apple NSView documentation
states the backing layer is "created on demand — typically during the first display of
the view." In `configureViewHierarchy()` (called from `loadView()`), the view is not
yet in a window or displayed. `clipContainer.layer` may be nil at that point, making
`layer?.cornerRadius = 8` a silent no-op. The layer is then created later with
default `cornerRadius = 0`. Nothing in the code path ever re-applies the value to the
real layer.

---

### Attempt 3 — Re-apply cornerRadius in `viewDidLayout()`

**Theory:** `viewDidLayout()` is called after the view is in the window and after
layout — the backing layer genuinely exists at that point. Setting `cornerRadius` and
`masksToBounds` there means they land on the real rendering layer, not a nil
placeholder.

**Change:** Added two lines to `viewDidLayout()` after `updateTileSide()`:

```swift
thumbnailImageView.layer?.cornerRadius = UIMetrics.Gallery.thumbnailCornerRadius
thumbnailImageView.layer?.masksToBounds = true
```

**Result:** No change. Corners still square.

**Why it likely failed:** Unknown. This should have worked by the same reasoning that
explains why the pending-edit path fixes corners (that path also calls `configure()` →
`updateTileSide()` → layout → `viewDidLayout()`). The fact that it doesn't suggests
either:

a) `thumbnailImageView.layer` is still nil in `viewDidLayout()` (possible if
   NSCollectionViewItem's lifecycle defers layer creation further than expected), or

b) something in NSImageView's rendering pipeline overrides `masksToBounds` after
   `viewDidLayout()` returns and before drawing, or

c) the fix in `viewDidLayout()` IS applying the values but NSImageView's
   rendering for the fallback workspace icon (NSIconImageRep) draws outside the
   layer's masked bounds regardless — and the pending-edit path swaps in a different
   NSImage instance that NSImageView renders differently.

---

## What is definitively known

1. `cornerRadius = 8` and `masksToBounds = true` set in `configureViewHierarchy()`
   do not produce rounded corners.

2. The bug affects real decoded thumbnails (CGImage-backed NSImages), not just
   fallback workspace icons. It is not a rendering-mode issue between NSIconImageRep
   and CGImage.

3. Rounded corners appear after the pending-edit `configure()` call. That call goes
   through exactly the same `setImage()` → `updateTileSide()` → layout sequence as
   the initial configure. The only observable difference is:
   - `hasPendingEdits` changes from `false` to `true` (→ `pendingDot.isHidden = false`)
   - `displayImageForCurrentStagedState` may return a new `NSImage` wrapper object
     (different identity) even if the underlying pixel data is unchanged

4. Printing `thumbnailImageView.layer` has not been done. It is not known whether
   `layer` is nil or non-nil at any of the attempted set-points.

---

## Recommended investigation for next programmer

**Step 1 — Determine whether `layer` is nil at each attempted set-point.**

Add temporary print statements:

```swift
// In configureViewHierarchy(), after setting layer properties:
print("configureViewHierarchy layer:", thumbnailImageView.layer as Any)

// In viewDidLayout():
print("viewDidLayout layer:", thumbnailImageView.layer as Any,
      "cornerRadius:", thumbnailImageView.layer?.cornerRadius as Any)
```

If `layer` is nil in `configureViewHierarchy()` but non-nil in `viewDidLayout()`, the
Attempt 3 fix (applying in `viewDidLayout()`) should have worked but didn't for an
unknown reason. If `layer` is nil even in `viewDidLayout()`, the problem is that
NSCollectionViewItem's view lifecycle is deferring layer creation further than expected.

**Step 2 — Determine what specifically the pending-edit configure path does differently.**

Add a temporary log in `setImage()` to record identity and whether the image is
the same object as before:

```swift
print("setImage: old=\(thumbnailImageView.image as Any) new=\(image as Any) same=\(thumbnailImageView.image === image)")
```

Determine whether `displayImageForCurrentStagedState` returns a new NSImage instance
on the pending-edit path. If it does, the nil→first-image vs non-nil→image distinction
is irrelevant (both would be non-nil→new-image transitions).

**Step 3 — Check whether NSImageView is overriding `masksToBounds`.**

Add a subclass or KVO observation on `thumbnailImageView.layer` to detect if
`masksToBounds` is being set to `false` after your code sets it to `true`. NSImageView
is known to interact with its backing layer in non-standard ways.

**Step 4 — Consider `NSImageView.layerContentsRedrawPolicy`.**

NSImageView may set `layer.contentsRedrawPolicy` in a way that causes layer
reconfiguration. Try:

```swift
thumbnailImageView.layerContentsRedrawPolicy = .onSetNeedsDisplay
```

before setting `layer?.cornerRadius`. This may prevent NSImageView from resetting the
layer.

**Step 5 — Consider `NSImageView.layer.contentsGravity`.**

If NSImageView renders via `layer.contents` (CALayer contents gravity mode), check
whether setting `layer.contentsGravity = .resizeAspect` explicitly prevents any
internal reconfiguration that wipes `cornerRadius`.

---

## Files involved

- `Sources/Ledger/BrowserGalleryView.swift` — `AppKitGalleryItem` class, specifically
  `configureViewHierarchy()`, `viewDidLayout()`, `setImage()`, `configure()`,
  `updateTileSide()`
- `Sources/Ledger/ThumbnailService.swift` — `fallbackIcon(for:side:)` returns an
  `NSWorkspace` icon (NSIconImageRep-backed NSImage); may be relevant if rendering
  path differs from CGImage thumbnails
- `Sources/Ledger/InspectorView.swift` — **not involved in this bug**; was not edited
  in this session; the inspector pending-dot overlay fix from session 1 is still in place

## Current code state

`BrowserGalleryView.swift` is at the original baseline — no fix attempts remain.
All three attempts have been fully reverted.
