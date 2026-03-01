# Roadmap

Current version: **0.7** (build 111). Target: **v1.0**.

Reference items by ID: **B1–B20** bugs · **P1–P24** polish · **N1–N8** native rewrites · **A1–A2** architecture · **R1–R19** post-v1.0 roadmap.

---

## Severity guide

| Label | Meaning |
|-------|---------|
| Blocker | Crash or data loss — fix before any build |
| Must | Broken feature — must fix for v1.0 |
| Should | Wrong or inconsistent behaviour — fix for v1.0 |
| Nice | Cosmetic / polish — nice to have before 1.0 |

---

## v1.0 — Outstanding bugs

### Menus & state
- [x] **B1** ~~Apply metadata menu state~~ — ✅ SwiftUI Button removed; AppKit NSMenuItem injected in Folder menu; `validateMenuItem` enables only when selection has pending edits.
- [x] **B2** ~~Clear metadata menu state~~ — ✅ Same fix as B1.
- [x] **B3** ~~Restore from backup menu state~~ — ✅ Same fix as B1; enabled only when selection has a restorable backup.
- [x] **B4** 🟡 **Cannot reproduce** — restoring does not succeed for all files in a folder; some retain edited metadata after restore. (QA checklist #46) Could not reproduce after B17 fix (2026-02-26); possible the `clearLoadedContentState` reordering resolved the silent-skip path. Reopen if it resurfaces.
- [x] **B17** ✅ **TCC approval leaves browser empty** — selecting Downloads (or Desktop) triggers a macOS TCC permission prompt; while the prompt is shown `enumerateImages` returns 0 results; after the user approves, the app regains focus but `loadFiles` was never retried. Fix: (1) `loadFiles` restructured to capture `enumerationError` before calling `clearLoadedContentState`, then re-apply it after — so the "Folder Unavailable" error state is now actually shown instead of silently degrading to "No Images"; (2) `reloadFilesIfBrowserEmpty()` added to `AppModel`; (3) `applicationDidBecomeActive` added to `AppDelegate` — calls `reloadFilesIfBrowserEmpty()` so any TCC-gated folder with an empty browser is automatically retried the moment the user returns to the app.
- [x] **B5** ~~View → As Gallery / As List broken~~ — ✅ SwiftUI Buttons removed; AppKit NSMenuItems injected with `validateMenuItem` setting checkmarks; Cmd+1 / Cmd+2 key equivalents preserved.
- [x] **B6** ~~View → Sort By checkmark stuck on Name~~ — ✅ SwiftUI Picker removed; AppKit NSMenu injected with `validateMenuItem` setting checkmarks on every menu open.
- [x] **B7** ~~View → Zoom In / Zoom Out not disabled in list mode~~ — ✅ SwiftUI Buttons removed; AppKit NSMenuItems injected; `validateMenuItem` disables both in list mode and at min/max zoom.
- [x] **B8** ~~Inspector / sidebar menu labels always say "Hide"~~ — ✅ Static "Toggle Sidebar" / "Toggle Inspector" labels; always correct regardless of state.

### Inspector
- [x] **B9** ✅ **Stale metadata shown after Apply** — root cause: `pendingEditsByFile[url]` was cleared before the exiftool re-read completed, causing `performRecalculateInspectorState` to fall back to the stale `metadataByFile` snapshot. Fix: `pendingCommitsByFile` captures the applied string values just before clearing; used as a middle fallback (after `pendingEditsByFile`, before `availableSnapshot`) so the inspector shows the written value throughout the reload window; cleared per-file in `loadMetadataForSelection` when the fresh snapshot arrives.

### Browser gallery
- [x] **B10** ~~Gallery selector changes colour on rotate~~ — ✅ Fixed in 0.6 via `stagedOpsDisplayToken`; cell no longer fully redraws on rotate.
- [x] **B11** ~~Thumbnail flicker on rotate / flip~~ — ✅ Fixed in 0.6 via `stagedOpsDisplayToken`; display transform updated without clearing thumbnail cache.
- [x] **B20** ✅ `Blocker` **Gallery thumbnails glitch/reload repeatedly after folder open** — resolved via the clean rewrite track `B20a–B20e` (baseline reset, shared thumbnail service, cell-owned lifecycle in gallery/list, native selection baseline, and unified inspector preview pipeline).
- [x] **B20a** `Must` **Thumbnail rewrite Step 1 — baseline commit** — completed in commit `26536c5` (`Baseline: track thumbnail rewrite plan and deferred UX list`) as the branchpoint before rewrite work.
- [x] **B20b** `Must` **Thumbnail rewrite Step 2 — single native thumbnail service** — completed: extracted thumbnail cache/request broker/generation strategy into `ThumbnailService` and switched existing list/gallery wrappers to delegate to the shared service.
- [x] **B20c** `Must` **Thumbnail rewrite Step 3 — AppKit cell-owned lifecycle** — completed: gallery requests are owned by `AppKitGalleryItem` and list requests are owned by `BrowserListNameCellView`/`BrowserListIconView`; both cancel on reuse (`prepareForReuse`) and guard async completion with per-cell request tokens.
- [x] **B20d** `Should` **Thumbnail rewrite Step 4 — native selection baseline** — completed: gallery selection now uses a Finder-like square thumbnail-zone highlight baseline, and square thumbnails render with equal inner padding on all four sides; image-hugging selector ring removed from the v1 rewrite path (tracked as optional post-v1.0 reintroduction in R19).
- [x] **B20e** `Must` **Thumbnail rewrite Step 5 — unify inspector preview pipeline** — completed: inspector preview loading/preload/background warm paths now request images through the same shared thumbnail broker/service used by list/gallery, with shared cache/dedupe and priority-based request dispatch.

### Sidebar
- [x] **B19** ✅ **No TCC prompt on startup for Desktop/Downloads** — startup privacy access policy was consolidated so launch/background paths do not probe privacy-sensitive filesystem locations. Key points: (1) startup reconciliation of favorites/recents skips existence/readability validation for privacy-sensitive paths; (2) privacy-sensitive sidebar counts never load in background and only load after explicit user selection of that exact item. Result: Desktop/Downloads counts stay blank on app open; TCC prompt appears only on explicit selection.
- [x] **B12** ✅ Implementation is correct; residual patchy shadow rendering matches Xcode's sidebar on macOS 26.2 — confirmed system compositor bug, not an app issue. Removed custom layer code; moved window config to `viewWillAppear`.

### About panel
- [x] **B13** ✅ About panel showed version 0.5 (1) instead of current version; `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` were hardcoded in target build settings, silently overriding Base.xcconfig. Removed from project.pbxproj — xcconfig is now sole source of truth.

### SwiftUI rendering
- [x] **B14** ✅ **`@Published` mutated during view update** — two sources fixed: (1) `.onChange(of: model.selectedSidebarID)` deferred `handleSidebarSelectionChange` via `Task { @MainActor in … }` to keep `loadFiles`/`clearLoadedContentState` out of the SwiftUI update cycle; (2) `BrowserListViewController.update()` called from `updateNSViewController` called `setSelectionFromList` synchronously when `shouldAdoptTableSelectionIntoModel()` returned true — fixed by clearing the table's stale row selection before `reloadData()` when items change (NSTableView preserves selection by row index across reloads), and additionally deferring `setSelectionFromList` via `Task` in the `shouldAdoptTableSelectionIntoModel()` path for robustness.
- [x] **B15** ❌ `Should` **NSHostingView reentrant layout** — partially resolved: the B14 fix eliminated most instances. One remaining instance fires when QuickLook opens via spacebar: `makeKeyAndOrderFront` + `NSApp.activate` in `present()` trigger `windowDidResignKey` on the main window, which fires SwiftUI's `controlActiveState` update mid-keyDown event. Deferring these calls via `Task` fixes the warning but corrupts QL's opening animation (wrong source frame for `sourceFrameOnScreenFor`) and breaks the locked-height logic. Not fixable without a deeper architectural change; the skipped layout pass on QL open has no visible user impact.

### Resources
- [x] **B16** ❌ **Missing bundle resource "default.csv"** — investigated: no CSV code or references exist anywhere in the app sources. Message originates from a system framework (likely the image thumbnail pipeline or QuickLook generator) that looks for an optional `default.csv` in the app bundle and falls back gracefully when absent. No visible user impact; not actionable without a stack trace identifying the call site.

---

## v1.0 — Outstanding polish

### Sidebar
- [x] **P1** ~~SF Symbol accentcolor in context menus~~ — ✅ `.tint(Color.primary)` applied to context menu content, overriding the inherited accent tint; per-item `symbolRenderingMode`/`foregroundStyle` overrides removed.
- [x] **P2** ❌ **Sidebar resize** — snap-to-collapse on drag is intentional macOS 26 Liquid Glass sidebar design (matches Finder and Xcode on 26.2); not an app bug. Three earlier attempts to override this behaviour reverted.
- [x] **P3** ❌ **Sidebar toggle animation drops frames** — gallery thumbnails resize on every frame of the sidebar animation via `shouldInvalidateLayout(forBoundsChange:) -> true`, which is correct `NSCollectionViewFlowLayout` behaviour. Frame drops are a consequence of macOS 26's longer native `toggleSidebar` animation vs the shorter inspector animation (0.16s). Expected framework behaviour; no fix available without fighting the layout design.
- [x] **P4** ✅ **Sidebar section collapse not instant under Reduce Motion** — `NavigationSidebarView` now reads `@Environment(\.accessibilityReduceMotion)`; `toggleSection` uses `Transaction` with `disablesAnimations = true` when set, matching the pattern already used by inspector sections. (QA checklist #55)
- [x] **P5** ❌ **Recents section does not animate on collapse/expand** ❌ `DisclosureGroup` approach tried and reverted: SwiftUI renders `DisclosureGroup` in a `.listStyle(.sidebar)` List with a left-side chevron (tree-view style), not the right-side chevron used by native macOS sidebar section headers. No SwiftUI API to move the indicator without a fully custom `DisclosureGroupStyle`. Reverting preserves correct right-side chevron on all sections; Recents animation remains broken.
- [x] **P6** ✅ **Favourites flows after relaunch** — verified in `AppModelTests`: pin/unpin/reorder survives relaunch (`testFavoriteOrderPersistsAcrossRelaunch`), and stale missing favourites are pruned on load via canonical-path reconciliation (`testFavoriteReconciliationDropsInvalidPaths`).

### Browser list
- [x] **P7** ✅ **Column headers don't sort** — `NSSortDescriptor` prototypes added to all four columns; `tableView(_:sortDescriptorsDidChange:)` maps the clicked column key to `model.browserSort` and `model.browserSortAscending`; clicking the active column header toggles ascending/descending (matching Finder); nil values always sort last regardless of direction; `syncSortIndicator()` keeps the header arrow in sync when sort changes via the View menu; both sort column and direction persist across launches. Foundation is in place for R15 (configurable columns).
- [x] **P8** ✅ **Selection out of view when switching gallery ↔ list** — list view: `browserDidSwitchViewMode` notification → `scrollRowToVisible`; gallery view: `lastRenderedViewMode` tracked in `renderState()`; on `justBecameActive`, `scrollSelectionIntoView()` calls `layoutSubtreeIfNeeded()` then `scrollToVisible(attrs.frame)` (deferred one run loop); `syncSelection` suppressed from scrolling during mode switch via `!justBecameActive` guard.

### Browser gallery
- [x] **P9** ✅ Gallery selection ring geometry was tuned in 0.6; superseded by **B20d** in 0.7 baseline where gallery selection moved to a native tile-level highlight.

### QuickLook
- [x] **P10** ✅ **QuickLook position inconsistent** — `QLPreviewPanel.center()` called before `makeKeyAndOrderFront` for first open; `NSWindow.didResizeNotification` observer locks panel height to QL's natural choice for the first image and derives width from QL's own aspect ratio for each subsequent image (mirrors Finder's behaviour); panel stays centred on screen across all navigation; if the panel is already open and the user has dragged it, size/position are still corrected on image change.

### Inspector
- [x] **P11** ~~Inspector toggle label static~~ — ✅ toolbar label and tooltip now dynamic via `updateInspectorToggle(with:)`. (QA log #6 was stale)
- [x] **P12** ✅ Inspector toggle moved to immediately before the search field; Apply button now precedes it.
- [x] **P13** ✅ **Inspector section collapse not instant under Reduce Motion** — `DisclosureGroup` binding setters already use `Transaction` with `disablesAnimations = true` when `reduceMotion` is on; `.animation(appAnimation(), value:)` on the outer scroll view returns nil under Reduce Motion. (QA checklist #56)
- [x] **P14** ❌ **Inspector dropdown widths inconsistent** — `Picker(.menu)` renders as `NSPopUpButton` which has a content-driven intrinsic width and does not respond to `.frame(maxWidth: .infinity)`; each picker is as wide as its longest option. Not fixable without `NSViewRepresentable` to set `contentHuggingPriority(.defaultLow, for: .horizontal)` on the underlying button.
- [x] **P15** ✅ **Date / time picker layout** — `DatePicker(.stepperField)` has a fixed intrinsic width and does not stretch; removed `.frame(maxWidth: .infinity)` from the picker and added `Spacer()` between it and the X button so the picker sits at its natural size left-aligned and the clear button is pinned to the right edge, matching the "no date" state layout.
- [x] **P24** ✅ **Inspector picker sends invalid tag `""`** — was a race symptom of B14: `draftValues` being mutated mid-render caused the Picker selection to return `""` while its `options` list (computed before the mutation) didn't include a `""` entry. Resolved by the B14 fix; Picker options and selection binding now evaluate against a consistent model state.

### Menus
- [x] **P16** ~~"Folder" menu item should say "Image"~~ — ✅ `CommandMenu("Folder")` renamed to `CommandMenu("Image")`.
- [x] **P17** ✅ **Apply metadata: split into two actions** — Image menu Apply is now split into "Apply Metadata Changes to [N Image(s)]" (dynamic selection count label, Cmd+S) and "Apply Metadata Changes to Folder" (folder-wide apply flow matching toolbar Apply). Both actions validate enabled state independently. Context-menu Apply label now uses the same dynamic selection-count title helper as the menu bar for exact wording parity.
- [ ] **P26** `Should` **Image-menu command scope + macOS-convention menu placement** — ensure image-level commands operate only on the current selection; place folder-wide actions in the macOS-conventional location (either a distinct subsection or the Folder menu); ensure context-menu actions always apply only to the right-click target selection.
- [ ] **P27** `Should` **Finalise menu structure** — lock the final top-level and context-menu command layout based on the agreed macOS-convention split from this conversation (including scope clarity between File/Image/Folder and consistent context-menu targeting).

### Status / toolbar
- [x] **P25** ✅ **Toolbar pane grouping** — added `inspectorTrackingSeparator` (`NSTrackingSeparatorToolbarItem` bound to `contentSplitController.splitView` divider 0); toolbar now has three zones: sidebar (`toggleSidebar`), browser (`openFolder`, `viewMode`, `sort`, `zoomOut`, `zoomIn`, `flexibleSpace`, `presetTools`, `applyChanges`), inspector (`toggleInspector`); each zone tracks its pane on resize. Hard line at toolbar bottom on inspector collapse is expected macOS Liquid Glass behaviour.
- [x] **P18** ✅ **Subtitle / status area** — subtitle priority stack: applying → loading → transient status message → `"X of N images"` (partial selection) → `"N images"` (idle); preview-preload progress removed (not user-meaningful). Wording uses "images" throughout.
- [x] **P19** ✅ **Apply partial failure count** — `"Applied X of N — Y failed"` / `"Restored X of N — Y failed"`; raw error string no longer appended inline.

### Other
- [x] **P20** ✅ Credits now use `smallSystemFontSize` matching the About panel's native credits area. Also fixed B13: `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` removed from target-level project.pbxproj settings that were overriding Base.xcconfig, so version and build now read correctly from the bundle.
- [x] **P21** ❌ **Desktop TCC prompt not appearing** — not fixable without sandboxing. TCC prompts appear for all apps (sandboxed or not) for hardware/system data (Camera, Mic, Photos Library, etc.), but file-system location prompts (Desktop, Documents, Downloads) are only enforced for sandboxed apps on macOS 13+. Silent access to Desktop for a non-sandboxed app is correct macOS behaviour. Will resolve automatically when sandboxed for App Store submission (R11).
- [x] **P22** ❌ **Search bar removed for v1.0** — name-only search is too limited for a metadata editor and the toolbar aesthetic was wrong. `searchQuery`/`filteredBrowserItems` infrastructure kept in AppModel (dormant); proper search deferred to post-v1.0 (see R14).
- [x] **P23** ❌ **Sidebar toggle right-aligned when expanded** — not achievable without a custom tracking view. Moving `.toggleSidebar` after `.sidebarTrackingSeparator` places it in the content section alongside the other toolbar buttons (flexibleSpace pushes it right into the cluster). No clean native solution; reverted to standard left-aligned placement.

---

## v1.0 — Outstanding native UI rewrites

Replace custom implementations with idiomatic SwiftUI / AppKit equivalents.

| ID | Item | Location | Target |
|----|------|----------|--------|
| N1 | Sort / Presets toolbar items | Toolbar | `NSMenuToolbarItem` — decide at implementation time |
| N2 | ~~`BrowserLoadingPlaceholderView`~~ | ~~line 1500~~ | ❌ No change — custom skeleton UI (shimmer rows + tile grid) is better than `ProgressView` (too generic) or `.redacted` (incompatible with `NSViewRepresentable`); existing implementation is correct SwiftUI. |
| N3 | ~~Sidebar count label~~ | ~~line 1294~~ | ✅ `.badge(model.sidebarImageCountText(for: item).map { Text($0) })` — custom `Spacer` + fixed-width `Text` + `Color.clear` placeholder removed; consistent with Mail and Reminders |
| N4 | Focus ring on scroll views (2 sites) | ~lines 1785, 2367 | `.focusRingType(.exterior)` |
| N5 | ~~Pending-edit dot (4 sites)~~ | ~~inspector label, inspector preview, list cell, gallery cell~~ | ✅ `Image(systemName: "circle.fill").foregroundStyle(.orange)` (SwiftUI sites); `NSImageView` + `NSImage(systemSymbolName:)` + `contentTintColor` (AppKit sites); `pendingDotCornerRadius` constants removed |
| N6 | ~~`toggleInspector` label (static "Hide Inspector")~~ | ~~line 1021~~ | ✅ Done — dynamic label via `updateInspectorToggle(with:)` |
| N7 | `InspectorLocationMapView` NSViewRepresentable | ~line 4554 | SwiftUI `Map(position:)` with `MapCameraPosition.region`, `Marker`, `.mapControls {}`, `.mapInteractionModes([.zoom])`; `InspectorPassthroughMapView` scroll-passthrough subclass may become unnecessary |
| N8 | `InspectorPreviewActionButtonStyle` + custom environment keys | InspectorView.swift ~lines 5–61 | Three-layer system (2 `EnvironmentKey` structs + `ButtonStyle` + label view) just to propagate hover/pressed state; collapse into a single self-contained button component using `.buttonStyle(.plain)` + `@State isHovered` + `.onHover` |
| N9 | ~~`editorPrimaryButtonTitle` dead computed property~~ | ~~PresetSheets.swift ~line 129~~ | ✅ Removed; preset editor primary button now uses direct `"Save"` label. |
| N10 | ~~Duplicate alert message branches~~ | ~~PresetSheets.swift ~lines 109–115~~ | ✅ Collapsed duplicate `.alert` message branches into a single `Text(...)` block. |
| N11 | ~~`NSMenuItem` 4-line-per-item boilerplate~~ | ~~BrowserListView.swift ~lines 520–556~~ | ✅ Replaced repeated per-item setup with a local `makeItem` helper (matching the gallery pattern). |

---

## v1.0 — Architecture

- [x] **A1** ✅ **Split MainContentView.swift** — 4,604 lines → 6 files: `NavigationSidebarView.swift` (206), `BrowserListView.swift` (758), `BrowserGalleryView.swift` (1,043), `InspectorView.swift` (681), `PresetSheets.swift` (438), `MainContentView.swift` residual (1,494). Clean build, no regressions.
- [x] **A2** ~~Sidebar count badge latency~~ — ✅ `warmSidebarImageCounts()` call sites removed in 0.6; counts no longer preloaded on launch, eliminating the flash.

---

## Post-v1.0 roadmap

### v1.0.1
- [ ] **R1** Full sidebar organiser — drag-and-drop group creation, import/export of favourite sets.
- [ ] **R2** Final branding consolidation — all user-facing labels, titles, and support paths consistent under the chosen app name.

### Branding rename (Ledger)
Full blueprint: `output/BRANDING_NAMING_REFRESH_IMPLEMENTATION.md`. User-facing name is **Ledger** — partially applied. Remaining work:

- [ ] **R3** **A — Identity + build settings** — verify `project.pbxproj`, `.xcscheme`, `Info.plist`, `Base.xcconfig` are all consistent for Ledger.
- [ ] **R4** **B — Runtime strings + UI labels** — audit `ExifEditMacApp.swift` and any remaining hardcoded app-name strings for consistency.
- [ ] **R5** **C — Persistent domains** — UserDefaults migration: read old `Logbook.*` keys as fallback; write sentinel `Ledger.Migration.v1Completed`.
- [ ] **R6** **D — App Support directory** — atomic move `~/Library/Application Support/Logbook` → `Ledger`; fallback read from old path if move fails.
- [ ] **R7** **E — Release + distribution artifacts** — verify `scripts/release/*.sh` and DMG name output as `Ledger.dmg`.

### Future features
- [ ] **R8** GPX import and conflict-resolution UI (in QA matrix; currently untested).
- [ ] **R9** Restore last-used folder on relaunch (consider privacy and removable-drive edge cases). (QA checklist #2)
- [ ] **R10** Large-folder performance pass (1,000+ RAW files — scrolling, thumbnail loading, apply speed).
- [ ] **R11** App Store submission track.
- [ ] **R12** Drag-and-drop metadata export / batch rename.
### AppKit migration (iPad target dropped — pure macOS)

- [ ] **R13** **NavigationSidebarView → AppKit** (`NSTableView` flat sidebar) — current SwiftUI `List` has scroll-position instability, unreliable selection binding, and requires notification hacks for focus routing. AppKit would give: stable scroll position, reliable first-responder routing, correct right-side section chevrons with proper collapse/expand animation (resolves P5), and native badge rendering. High value.
- [ ] **R16** **InspectorView → AppKit** (`NSViewController` + `NSScrollView` + stacked field controls) — the highest-friction SwiftUI component in the app. Current workarounds to eliminate: `inspectorRefreshRevision` UInt64 forced-refresh hack, `suppressNextFocusScrollAnimation` flag, manual edit-session `@State` snapshots (replace with `UndoManager`), per-tag `Binding` creation on every render, and `@FocusState` fighting the AppKit responder chain. High value.
- [ ] **R17** **PresetManagerSheet → AppKit** (`NSTableView` in `NSPanel`) — small SwiftUI `List` with same scroll/selection instability as the sidebar. Natural follow-on after R13; low implementation effort. Medium value.
- [ ] **R18** **PresetEditorSheet → AppKit** (optional) — modal sheet; scroll stability matters less here. Main benefit would be DatePicker style consistency with Inspector (`.stepperField`), and removing the per-tag `valueBinding(for:)` pattern. Low priority.
- [ ] **R14** **Search** — expand-to-field toolbar button (like Notes.app on macOS 26) with metadata-aware search: filename, date range, camera/lens, rating, keyword. `searchQuery`/`filteredBrowserItems` infrastructure already in place.
- [ ] **R15** **Configurable list columns** — show/hide and reorder columns; add EXIF-backed columns (date modified, camera make/model, lens, focal length, ISO, aperture, shutter speed, pixel dimensions). Each new column gets a `BrowserSort` case and `NSSortDescriptor` prototype; sort and header infrastructure from P7 carries forward directly.
- [ ] **R19** **Optional gallery UX reintroduction pack (post-v1.0)** — reintroduce non-baseline gallery polish one feature at a time: image-hugging selector ring, ring-anchored pending-dot positioning, ring geometry continuity during staged rotate/flip, tile/image transition polish beyond native defaults, and aggressive gallery prefetch heuristics.
