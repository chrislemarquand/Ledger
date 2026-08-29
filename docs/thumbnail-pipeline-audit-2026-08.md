# Thumbnail Pipeline Audit — 2026-08-29

Plan for a v1.4 pass at Ledger's thumbnail pipeline, prompted by a reported bug: switching folders in Icon view briefly flashes every cell to a generic file-type icon (with subtitle "—" and no cloud badge) before the real thumbnails, sizes, and overlays pop in a frame or two later. Diagnosis and plan only — no code changed as part of this document.

## The bug

`BrowserIconViewController.collectionView(_:itemForRepresentedObjectAt:)` (`Sources/Ledger/BrowserIconView.swift:579-604`) configures each cell synchronously with:

```swift
let baseImage = ThumbnailPipeline.cachedImage(for: item.url, minRenderedSide: 1)
    ?? ThumbnailPipeline.fallbackIcon(for: item.url, side: 128)
```

`ThumbnailService.cachedImage(for:minRenderedSide:)` (`Sources/Ledger/ThumbnailService.swift:125-130`) only checks `memoryCache`, an `NSCache`. It never consults the on-disk thumbnail cache that `request(url:requiredSide:forceRefresh:)` (same file, line 164) reads from via `generate(fileURL:maxPixelSize:)`. So on a `NSCache` miss — which happens whenever a folder hasn't been visited yet this app session, or its thumbnails were evicted under memory pressure — every cell paints the grey fallback icon first, then `requestThumbnail(for:in:tileSide:)` (line 606) kicks off the async path, which *does* hit the disk cache, resolves quickly, and swaps the real image in a moment later. That swap is the visible flash. The same two symptoms noted alongside it (subtitle showing "—", cloud badge missing) are downstream of the same root cause: they're derived from `BrowserItem` fields that are also hydrated asynchronously after the initial synchronous cell configure (see `AppModel+FileLoading.swift:161-219`), and a subtitle-refresh bug in that exact path was fixed this session (see below).

## Relevant git history

This is not a new problem for the codebase — folder-switch visual stability has been patched several times, each time addressing a different symptom of the same underlying tension (an initial synchronous paint vs. asynchronously-arriving real data):

- **`b60ff80` — "Rewrite thumbnail pipeline: NSCache, disk cache, SharedUI generator"**: added the on-disk thumbnail cache specifically so thumbnails "survive app restart," but never wired it into the synchronous `cachedImage` lookup cell configuration relies on. This is the gap the current bug lives in — the disk cache exists, it's just never checked synchronously.
- **`61d634b` — "detect stale disk-cached thumbnails via source file mtime"**: hardened the disk-cache *read* path for correctness (a cached JPEG for an externally-edited file is now correctly treated as a miss), but again only inside the async `generate` path, not the synchronous one.
- **`3ab4915` — "Improve first-paint thumbnail responsiveness on folder open"** and **`936e846` — "Prioritize current folder by canceling stale thumbnail queue"**: both improved *how fast* the async path resolves (warm-loading first-screen thumbnails at a modest size, canceling stale in-flight requests from the previous folder), but didn't change the fact that there's always at least one synchronous-then-async round trip.
- **`5076ead`, reverted one minute later as `cadd255` — "prevent empty-state flicker during folder switch"**: same instinct (something visibly flashes when the folder changes), different layer (whole-browser empty/loading state, not per-cell thumbnails). The revert suggests the `isFolderContentLoading` flag was set and cleared around code that hadn't actually gone async yet, making it a no-op — abandoned without a working fix.
- **`c639ad8` — "resume gallery thumbnail loading after view switches"** and **`b8f66b0` — "restore native menus and stabilize gallery thumbnails after apply"**: closer cousins — thumbnails not reappearing/refreshing correctly after switching view modes or applying edits — same pipeline, adjacent trigger.
- **The `[x] Folder-switch render parity across sort modes` roadmap item** (`docs/Roadmap.md`, v1.2): "fixed mismatch where `Date/Size/Kind` transitions could flash/reorder differently from `Name`. Browser switch is now atomic and preserves visible content until replacement is ready" — folded into the v1.0.1 release (`55991ac`) via the `shouldPublishHydratedOnly`/`prehydratedItems` split still present today in `AppModel+FileLoading.swift:165-211`. This is the most relevant prior art: it already solved "don't show a half-built state on switch" for the *list/order* of items under non-name sorts by publishing a fully-hydrated item array up front instead of an empty-then-filling one. It did not extend the same "wait for real data, then publish atomically" idea to thumbnails or to the default Name-sort path (which still publishes items with `sizeBytes: nil` etc. immediately, see `AppModel+FileLoading.swift:199-211`).
- **This session** (2026-08-29): fixed a related bug where the Icon-view subtitle field (`iconSubtitleColumnID`) didn't refresh after a folder switch until manually toggled — root cause was that `BrowserItem` attribute hydration (size, dates, kind) republishes `items` with unchanged URLs, which `BrowserIconViewController.renderState()`'s change-detection didn't treat as a change. Fixed by comparing `items != lastRenderedItemsForSubtitle` directly (`BrowserIconView.swift:266-280`). This is the exact same "synchronous paint precedes asynchronous real data, and something in between doesn't know the real data has arrived" shape as the thumbnail flash — different code path, same disease.

**Conclusion**: the disk-cache-not-checked-synchronously gap has never been fixed. The wider pattern (cells/subtitles/badges painting a placeholder before async data lands, with inconsistent or absent "did the real data arrive" signaling) has been chased symptom-by-symptom at least five times across the project's history without ever being addressed as one root cause.

## Quick fix (do first, small and contained)

Extend `ThumbnailService.cachedImage(for:minRenderedSide:)` (`Sources/Ledger/ThumbnailService.swift:125-130`) to fall back to a synchronous disk-cache read on an `NSCache` miss, before returning `nil`:

1. On miss, check `isDiskCacheStale` (already exists, from `61d634b`) against `diskURL(for: fileURL)`.
2. If not stale and the file exists, synchronously `Data(contentsOf:)` + decode it (cheap: a local JPEG at thumbnail resolution, no network, sub-millisecond on SSD/APFS).
3. Populate `memoryCache` on the way out so the next lookup for the same URL is a pure memory hit.

This closes the gap left open by `b60ff80` with one function change and no architecture impact. All three call sites that already prefer `cachedImage` over generating fresh (`BrowserIconView.swift:586`, `BrowserFilmstripViewController.swift:339,453`, `BrowserListView.swift:698`) get the fix automatically, since they all go through the same API.

## Wider pass (v1.4 scope — do properly, not as a follow-on patch)

1. **Define explicit per-item load stages** instead of the current implicit binary (memory-cached vs. fallback icon): `.unknown → .diskCached → .warm`, each with a defined visual. Apply the same thinking to `BrowserItem` attribute hydration (size/dates/kind) and to metadata-derived subtitle/aperture/lens fields — right now each of these three data sources (thumbnail pixels, filesystem attributes, exiftool metadata) has its own independent synchronous-then-async path with its own ad hoc "did it change" tracking bolted onto `renderState()`, which is exactly why the subtitle bug and the thumbnail flash are the same shape of bug found twice.
2. **Audit every `ThumbnailPipeline.cachedImage`/fallback-icon call site** for the same fix once the API itself is disk-aware — Icon (`BrowserIconView.swift`), Filmstrip (`BrowserFilmstripViewController.swift`), and List (`BrowserListView.swift`) all currently duplicate this pattern independently. Confirm behavior is identical across all three (relevant to the Icon/Filmstrip "drift" concern already tracked from this session's Gallery View work).
3. **Reconcile the warmup/priority scheduling machinery** (`startInitialThumbnailWarmup`, `scheduleDeferredFolderMetadataPrefetch`, stale-queue cancellation from `936e846`) against the now-synchronous disk-cache fix — some of the existing delay/priority tuning may be solving a problem that mostly goes away once disk hits are synchronous, or may need retuning now that first paint is faster.
4. **Revisit `isFolderContentLoading`** (`5076ead`/`cadd255`) with the benefit of now actually understanding the async boundary — it's plausible a version of that flag is still the right tool for the *whole-browser* empty-state case, just needs to be set/cleared around the correct (actually-async) span of work instead of synchronously.
5. **Decide whether the "atomic publish" pattern from the sort-mode fix should extend to Name-sort folder loads and to thumbnails.** Today only non-Name sorts get `prehydratedItems` (a fully-attributed array published once); Name-sort (the default) and all thumbnails still publish-then-fill. If the wider pass concludes atomic publish is the right general answer, this could subsume most of the point-fixes above.
6. **Add disk-cache eviction.** Already an open, separate roadmap item (`docs/Roadmap.md`, v1.4: "AppKit/UI + performance/memory/disk audit follow-ups ... adding eviction to the thumbnail disk cache") — natural to fold into the same pass since it touches the same code.
7. **Write down a regression check.** This class of bug has resurfaced repeatedly with no recorded manual QA step anywhere in the repo. At minimum, add one to whatever smoke-test doc is current at the time: switch away from and back to a folder whose thumbnails are disk-cached but not memory-cached (e.g. after `invalidateAllCachedImages()` or a fresh launch), confirm no flash.

## Files referenced

- `Sources/Ledger/ThumbnailService.swift:100-179`
- `Sources/Ledger/BrowserIconView.swift:266-280, 579-621, 646-681`
- `Sources/Ledger/BrowserFilmstripViewController.swift:339, 453, 486, 508-556`
- `Sources/Ledger/BrowserListView.swift:698, 828-840`
- `Sources/Ledger/AppModel+FileLoading.swift:161-219, 414-443`
- `docs/appkit-ui-performance-audit-2026-07.md` (disk-cache eviction, already tracked)
- `docs/v1.2-performance-streamlining-plan.md` (Phase 4 architecture guardrails, adjacent scope)
