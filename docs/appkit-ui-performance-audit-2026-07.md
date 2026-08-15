# AppKit/UI + Performance/Memory/Disk Audit — 2026-07-25

Two passes over `main` (clean tree, commit `ef47bf0`), done against the goal of keeping Ledger as close to a native Mac app as possible (minimal custom reimplementations of system-provided functionality) and as performant as possible for large photo libraries.

---

## Pass 1: Native UI fidelity (AppKit/SwiftUI, HIG, accessibility)

Overall picture: disciplined AppKit-first app. Gallery is genuine `NSCollectionView` + `NSCollectionViewCompositionalLayout`, toolbar is real `NSToolbar`, drag-and-drop is real `NSDraggingSource`/`NSPasteboardWriting`, context menus are real `NSMenu`. No custom window chrome, no custom scrollbars, no hand-rolled animation engine. `PinchZoomAccumulator` and `ToolbarAppearanceAdapter` (SharedUI) are narrow, justified patches over real AppKit gaps, not reimplementations of system behaviour.

### Critical
None found.

### Important
1. **`WorkflowInlineRadioGroup` duplicates a native SwiftUI control** — `Sources/Ledger/DateTimeAdjustSheetView.swift:636-700`. `NSViewRepresentable` wrapping a hand-built `NSStackView` of `NSButton` radios. SwiftUI's `Picker(selection:) { }.pickerStyle(.radioGroup)` covers this, including per-option disabling. Check whether the original justification still holds; if not, replace and delete the wrapper.
2. **Accessibility inconsistent between AppKit and SwiftUI layers.** SharedUI's SwiftUI inspector controls set explicit labels (`InspectorRatingFlagView.swift:112-174`, `InspectorPopupField.swift:21-55`, `InspectorDatePickerField.swift:12-58`), but `AppKitGalleryItem` (`Sources/Ledger/BrowserGalleryView.swift:667+`) — the primary content surface — sets no explicit `accessibilityLabel`/`accessibilityDescription` on the thumbnail image view, relying on the adjacent title field alone. Worth an explicit VoiceOver pass on the gallery.
3. **No `dismantleNSView` anywhere in Ledger or SharedUI.** Not currently harmful (audited representables hold only weak coordinator references), but no established teardown pattern exists for the next representable that registers KVO/NotificationCenter observers or a delegate.

### Positive / already right
- Gallery selection (rubber-band, keyboard) goes through `super.mouseDown`/`super.keyDown`, only intercepting cases AppKit doesn't handle for the app's selection model.
- Thumbnail pipeline (`ThumbnailService.swift`) is off-main-thread throughout — `NSCache` + disk tier + actor-based concurrency broker (max 4 concurrent), decode via `ImageIO`/`CGImageSourceCreateThumbnailAtIndex`.
- Toolbar/drag-drop/context menus are all real AppKit, no reimplementations.
- Window chrome: `WindowToolbarSetup.swift` uses standard `.fullSizeContentView` + unified toolbar; `titlebarAppearsTransparent` not referenced anywhere — zero manual chrome hacks.
- Colors are fully semantic — zero hardcoded `NSColor(red:...)`/hex literals in either repo.
- `AppAnimation.swift` (`Motion`/`appAnimation()`) checks `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` and disables itself accordingly — correct accessibility-respecting pattern.
- `AppModel` is `@MainActor`; `DispatchQueue.main.async` usage (~20 sites) is deliberate SwiftUI re-entrancy avoidance with inline rationale, not a threading band-aid.
- `NSViewRepresentable` coordinators are reused via `context.coordinator` (not recreated per-update); sizing uses `intrinsicContentSize` overrides rather than direct frame-setting — both classic bridge pitfalls avoided except for the `dismantleNSView` gap above.

### Not fully verified (follow-up, not asserted as broken)
- Accessibility coverage on `BrowserListView.swift` cells beyond one icon (`:731`).
- `QuickLookPanelCoordinator.swift` and the `AppKitSidebarController` drag/drop implementation, not reviewed in depth.
- `AppWelcomeViewController`/WhatsNewKit beep-on-dismiss — tracked separately as a known unresolved bug.

---

## Pass 2: Memory / Disk / Performance

### Critical

1. **Batch metadata writes spawn one `exiftool` process per file.** `Sources/ExifEditCore/ExifToolService.swift:90-115` (`writeMetadata`) loops `for file in operation.targetFiles { try run(...) }` — one `Process()` launch per file, funnelled through by `ExifEditEngine.apply` and `writeMetadataWithoutBackup` (`Sources/ExifEditCore/ExifEditEngine.swift:22-53`). Bundled exiftool is a Perl script (PERL5LIB setup at `ExifToolService.swift:270-279`), so each invocation pays real interpreter-startup cost — editing a large multi-select means hundreds of sequential process spawns. Reads are already batched into one invocation (`ExifToolCommandBuilder.readArguments`); writes are not, despite exiftool supporting `-@ argfile`/combined invocation. **Single biggest perf lever in the app.**

2. **Thumbnail disk cache has no size cap or eviction policy.** `Sources/Ledger/ThumbnailService.swift:21-48` — disk cache lives under `Library/Caches/<bundleID>/thumbnails` (correct location) but is never pruned automatically; only explicit full wipes exist (`invalidateAllCachedImages()`/`invalidateCachedImages(for:)`, lines 136-148). For a large library browsed over months this grows unbounded until macOS opportunistically purges `Caches` (not deterministic). Add periodic age- or size-based pruning.

### Important

3. Gallery does a full `reloadData()` on filter/sort/list changes (`Sources/Ledger/BrowserGalleryView.swift:270-278`), gated behind a change-detection flag so not reflexive, and per-item invalidation already uses targeted `reloadItems(at:)`. Low urgency, but not a diffable-data-source apply — could stutter at very large (tens-of-thousands-item) filtered views.

4. `NSCache` memory tier bounds are explicit and sane (`countLimit = 2_000`, `totalCostLimit = 200MB`, `ThumbnailService.swift:12-17`) — flagged for visibility, not a bug.

### Positive / already handled well

- Backup files are properly managed: `-overwrite_original` passed (`ExifToolCommandBuilder.swift:38`) so exiftool never leaves its own `_original` files scattered in the library; the app's own `BackupManager` writes to `Application Support/.../Backups/<uuid>/` and `pruneOperations(keepLast:)` is invoked after every apply (`AppModel.swift:777-779`) — bounded retention.
- Thumbnails are always downsampled at generation via `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize` (`ThumbnailGenerator.swift:13-25`, SharedUI) — no full-resolution image load found anywhere in the preview/editing path.
- NotificationCenter observers are consistently paired with removal (tokens stored, cleared in `deinit`) across `BrowserListView.swift:147-190`, `BrowserGalleryView.swift:53-94`, `MainContentView.swift:121-125,348-360,552-...`, `AppModel+FileLoading.swift:440-455`. No orphaned observers found; no `Timer.scheduledTimer` usage anywhere to leak.
- Logging uses `OSLog`/`Logger` (`AppModel.swift:5,10`), not a custom file-based log — no unbounded log-growth risk; rotation is OS-managed. (Note: this differs from Librarian's planned file-based `AppLog` — the two apps use different logging approaches.)
- Launch path is lean: `AppDelegate.applicationDidFinishLaunching` (`LedgerApp.swift:140-159`) does cheap synchronous UI setup only; metadata loading happens off the critical path via async, batched calls (`AppModel+MetadataPipeline.swift:23`). No synchronous exiftool calls or full-library scans at launch.
- Temp file usage is minimal and scoped (`AppModel+Actions.swift:250`, `BackupManager.swift:31`) — no evidence of leaked temp files across sessions.

### Citations
- `Sources/Ledger/ThumbnailService.swift:12-17, 21-48, 136-148`
- `Sources/ExifEditCore/ExifToolService.swift:77-115, 261-358`
- `Sources/ExifEditCore/ExifEditEngine.swift:22-53`
- `Sources/ExifEditCore/ExifToolCommandBuilder.swift:29-38`
- `Sources/ExifEditCore/BackupManager.swift:36-61, 123-144`
- `Sources/Ledger/AppModel.swift:726-779`
- `Sources/Ledger/AppModel+ApplyRestore.swift:172, 204, 439`
- `Sources/Ledger/BrowserGalleryView.swift:244-278, 667+`
- `Sources/Ledger/BrowserListView.swift:147-190`
- `Sources/Ledger/MainContentView.swift:121-125, 348-360, 552-...`
- `Sources/Ledger/AppModel+FileLoading.swift:440-455`
- `Sources/Ledger/LedgerApp.swift:140-159`
- `Sources/Ledger/AppModel+MetadataPipeline.swift:6-38`
- `Sources/Ledger/DateTimeAdjustSheetView.swift:636-700, 1232-1270`
- `/Users/chrislemarquand/Xcode Projects/SharedUI/Sources/SharedUI/Utilities/ThumbnailGenerator.swift:13-45`

---

## Summary of actionable follow-ups for v1.3+

1. Batch `exiftool` writes into a single invocation (`-@ argfile`) instead of one process per file — critical, biggest perf win.
2. Add eviction (age/size-based) to the thumbnail disk cache.
3. Replace `WorkflowInlineRadioGroup` with native SwiftUI `Picker(.radioGroup)` if the disabled-state requirement doesn't block it.
4. Add explicit accessibility labels to gallery thumbnail items (`AppKitGalleryItem`).
5. Establish a `dismantleNSView` convention before the next stateful `NSViewRepresentable` is added.
