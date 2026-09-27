# Roadmap Archive

Historical detail for shipped work, moved out of the live `docs/ROADMAP.md`
to keep it focused on what's actually next. Two parts:

- **Pre-v1.0** (below) — the original bug/polish/native-rewrite/architecture
  backlog used to ship v1.0, preserved as originally written (its own ID
  system: `B#` bugs, `P#` polish, `N#` native rewrites, `A#` architecture,
  `R#` post-v1.0 items raised during that work).
- **Shipped v1.x releases** (`v1.0.1` through `v1.4`) — moved here from
  `docs/ROADMAP.md` once fully shipped and also captured in `CHANGELOG.md`.

---

Current version: **0.7.3** (build in `Config/Base.xcconfig`). Target: **v1.0**.

Reference items by ID: **B1–B23** bugs · **P1–P24** polish · **N1–N11** native rewrites · **A1–A10** architecture/stability · **R1–R21** post-v1.0 roadmap.

ID convention: `B#`/`P#`/`N#`/`A#`/`R#` are roadmap item IDs. Backlog severity labels use `S0`/`S1`/`S2` in `v1-bug-backlog.md` to avoid collision with roadmap `P#` polish IDs.

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
- [x] **B21** ✅ **Menu command ownership split (SwiftUI + AppKit) resolved** — all custom menu-bar commands now run under AppKit ownership (`NSMenu`/`NSMenuItem`) with dynamic submenu population (including `Open With`) and native enabled/disabled/checkmark/title state via `validateMenuItem(_:)`. SwiftUI custom menu-command ownership for these actions was removed.

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
- [x] **B22** ✅ **Intermittent "Publishing changes from within view updates is not allowed" still appears in Xcode debug output** — superseded, not reproduced as of the v1.4 Phase 0.4 baseline investigation (2026-08-31), after the AppKit sidebar migration. A sidebar-local selection refactor was attempted then reverted due to a click-selection regression; the safe change retained was: Inspector sheet bindings defer writes to `model.activePresetEditor` / `model.isManagePresetsPresented` through `Task { @MainActor ... }`. Smoke path used: a Debug build, rapid repeated sidebar switching between Desktop/Downloads/Pictures (3 cycles) via `XCUIApplication` clicks, while capturing `log stream --predicate 'eventMessage CONTAINS "Publishing changes" OR eventMessage CONTAINS "reentrantly"'` in parallel — zero matches. (The UI test that ran this was written, run once, then deliberately removed from the permanent suite — clicking those sidebar shortcuts triggers a macOS TCC privacy dialog that re-prompts on every build, an unsuppressible automation blocker; see `docs/v1.4-progress.md`.) Revisit only if this warning is observed again in real use.

### Resources
- [x] **B16** ❌ **Missing bundle resource "default.csv"** — investigated: no CSV code or references exist anywhere in the app sources. Message originates from a system framework (likely the image thumbnail pipeline or QuickLook generator) that looks for an optional `default.csv` in the app bundle and falls back gracefully when absent. No visible user impact; not actionable without a stack trace identifying the call site.
- [ ] **B23** `Nice` **CMPhoto/IOSurface debug-log spam during large thumbnail/preview decode bursts** — repeated `CMPhotoJFIFUtilities err=-17102` and `IOSurface creation failed: e00002c2` messages observed in Xcode logs (2026-03-01). Currently treated as non-blocking framework-level noise unless correlated with user-visible failures (blank thumbnails, persistent decode failure, hangs, or crashes). Keep under observation during performance QA.

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
- [x] **P26** `Should` **Image-menu command scope + macOS-convention menu placement** — ensure image-level commands operate only on the current selection; place folder-wide actions in the macOS-conventional location (either a distinct subsection or the Folder menu); ensure context-menu actions always apply only to the right-click target selection.
- [x] **P27** `Should` **Finalise menu structure** — lock the final top-level and context-menu command layout based on the agreed macOS-convention split from this conversation (including scope clarity between File/Image/Folder and consistent context-menu targeting).

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
| N1 | ~~Sort / Presets toolbar items~~ | Toolbar | ✅ Implemented with native `NSMenuToolbarItem` for Sort and Presets (replacing manual toolbar-menu popup wiring). |
| N2 | ~~`BrowserLoadingPlaceholderView`~~ | ~~line 1500~~ | ❌ No change — custom skeleton UI (shimmer rows + tile grid) is better than `ProgressView` (too generic) or `.redacted` (incompatible with `NSViewRepresentable`); existing implementation is correct SwiftUI. |
| N3 | ~~Sidebar count label~~ | ~~line 1294~~ | ✅ `.badge(model.sidebarImageCountText(for: item).map { Text($0) })` — custom `Spacer` + fixed-width `Text` + `Color.clear` placeholder removed; consistent with Mail and Reminders |
| N4 | ~~Focus ring on scroll views (2 sites)~~ | ~~~lines 1785, 2367~~ | ❌ Superseded by the AppKit list/gallery rewrite; focus-ring behavior is now controlled directly on `NSTableView`/`NSCollectionView` (`focusRingType = .none`) rather than legacy scroll-view sites. |
| N5 | ~~Pending-edit dot (4 sites)~~ | ~~inspector label, inspector preview, list cell, gallery cell~~ | ✅ `Image(systemName: "circle.fill").foregroundStyle(.orange)` (SwiftUI sites); `NSImageView` + `NSImage(systemSymbolName:)` + `contentTintColor` (AppKit sites); `pendingDotCornerRadius` constants removed |
| N6 | ~~`toggleInspector` label (static "Hide Inspector")~~ | ~~line 1021~~ | ✅ Done — dynamic label via `updateInspectorToggle(with:)` |
| N7 | ~~`InspectorLocationMapView` NSViewRepresentable~~ | ~~~line 4554~~ | ❌ Superseded by near-term `R16` (Inspector AppKit rewrite). |
| N8 | ~~`InspectorPreviewActionButtonStyle` + custom environment keys~~ | ~~~InspectorView.swift ~lines 5–61~~~ | ❌ Superseded by near-term `R16` (Inspector AppKit rewrite). |
| N9 | ~~`editorPrimaryButtonTitle` dead computed property~~ | ~~PresetSheets.swift ~line 129~~ | ✅ Removed; preset editor primary button now uses direct `"Save"` label. |
| N10 | ~~Duplicate alert message branches~~ | ~~PresetSheets.swift ~lines 109–115~~ | ✅ Collapsed duplicate `.alert` message branches into a single `Text(...)` block. |
| N11 | ~~`NSMenuItem` 4-line-per-item boilerplate~~ | ~~BrowserListView.swift ~lines 520–556~~ | ✅ Replaced repeated per-item setup with a local `makeItem` helper (matching the gallery pattern). |

---

## v1.0 — Architecture

- [x] **A1** ✅ **Split MainContentView.swift** — 4,604 lines → 6 files: `NavigationSidebarView.swift` (206), `BrowserListView.swift` (758), `BrowserGalleryView.swift` (1,043), `InspectorView.swift` (681), `PresetSheets.swift` (438), `MainContentView.swift` residual (1,494). Clean build, no regressions.
- [x] **A2** ~~Sidebar count badge latency~~ — ✅ `warmSidebarImageCounts()` call sites removed in 0.6; counts no longer preloaded on launch, eliminating the flash.
- [x] **A3** ✅ **Browser center-pane container moved from SwiftUI wrapper to AppKit controller** — replaced `BrowserView` overlay-state wrapper with `BrowserContainerViewController` (`NSViewController`) that owns gallery/list child hosts and loading/empty/error overlays directly in AppKit, removing the SwiftUI structural-identity dependency in the center pane while preserving existing browser behavior.

### Pre-v1.0 SwiftUI/AppKit stabilization plan (authoritative)

Goal: keep SwiftUI sidebar + inspector for v1.0, but make the hybrid shell stable and predictable (no re-entrant update loops, no selection snap-back regressions).

- [x] **A4** ✅ **Boundary ownership contract**
  - AppKit owns: window/split views, menu validation/injection, pane sizing/collapse, first-responder routing.
  - SwiftUI owns: sidebar/inspector content rendering only.
  - AppModel is the sole mutable state authority.
  - **Acceptance:** contract documented in `Architecture.md` under **Hybrid contract (A4, pre-v1.0 source of truth)** and referenced by this roadmap section.

- [x] **A5** ✅ **One-way state flow at SwiftUI boundaries**
  - Replace remaining two-way direct bridges that can write back during render.
  - SwiftUI emits explicit user intent methods to `AppModel`; model pushes state down.
  - **Acceptance:** no sidebar click/selection snap-back; folder activation stable under rapid repeated clicks.
  - Implemented: `NavigationSidebarView` now uses local `sidebarSelection` state and forwards user changes through `handleExplicitSidebarSelectionChange(to:)`; legacy two-way sidebar suppression/revert path and stale event heuristics were removed from `AppModel`.

- [x] **A6** ✅ **No synchronous model mutation in SwiftUI update cycle**
  - Audit `onChange`, `DisclosureGroup` setters, focus callbacks, picker callbacks.
  - Defer boundary writes (`DispatchQueue.main.async` / `Task { @MainActor ... }`) where required.
  - **Acceptance:** must-fix warning `Publishing changes from within view updates is not allowed` no longer appears during normal smoke path.
  - Implemented: sidebar selection intent dispatch deferred from `NavigationSidebarView.onChange`; inspector `DisclosureGroup` section-toggle writes deferred; preset-sheet model presentation bindings (`activePresetEditor`, `isManagePresetsPresented`) deferred through main-actor tasks.

- [x] **A7** ✅ **Remove user-path auto-selection suppression**
  - Keep privacy/startup auto-selection guards only for non-user/background paths.
  - Explicit user selection paths must not be reverted by heuristics.
  - **Acceptance:** selecting Desktop/Downloads/favorites/recents behaves deterministically, including after folder switches.
  - Implemented: user-driven sidebar path now routes only through `handleExplicitSidebarSelectionChange(to:)`; legacy suppress/revert heuristics were removed from `AppModel`. Privacy-sensitive gating is retained only in startup/background flows (`reloadFilesIfBrowserEmpty`, sidebar count warm policy).

- [x] **A8** ✅ **Targeted observation only in AppKit hosts**
  - No broad `objectWillChange` observers in split/container hosts.
  - Use explicit `@Published` subscriptions for toolbar/title/render triggers.
  - **Acceptance:** no host-wide render storms attributable to broad observation.
  - Implemented: `NativeThreePaneSplitViewController` now uses explicit `uiRefreshObservers`; `BrowserContainerViewController` now uses explicit `renderObservers`; both pipelines use targeted publishers with `removeDuplicates`.

- [x] **A9** ✅ **No layout-time publish from AppKit callbacks**
  - Split resize/layout notifications must not synchronously mutate SwiftUI-bound `@Published` state.
  - Use deferred/coalesced pane-state sync.
  - **Acceptance:** must-fix warning `NSHostingView is being laid out reentrantly while rendering its SwiftUI content` no longer appears on normal pane resize/toggle flows.
  - Implemented: all AppKit pane-collapse state publication now routes through deferred/coalesced `schedulePaneStateSync()` (including startup and window-configuration paths); direct `syncSidebarCollapsedState()` / `syncInspectorCollapsedState()` calls were removed from `viewDidLoad`, initial inspector setup, and `configureWindowIfNeeded`, leaving split-resize/toggle flows on the same deferred path.

- [x] **A10** ✅ **Warning gate + smoke checklist freeze**
  - Add a compact smoke checklist and classify logs:
    - Must-fix before v1.0:
      `Publishing changes from within view updates is not allowed`
      `NSHostingView is being laid out reentrantly while rendering its SwiftUI content`
    - Observe only / framework noise unless user-visible breakage:
      ICC/profile decode warnings, `CMPhotoJFIFUtilities`, `IOSurface` decode spam.
  - Add and enforce the **PR architecture checklist** + **Hybrid release smoke checklist** in `Architecture.md`.
  - **Acceptance:** checklist committed and used as release gate for v1.0 candidates.
  - Implemented: `Architecture.md` now contains the frozen **Hybrid contract**, explicit **Warning gate**, required **PR architecture checklist**, and **Hybrid release smoke checklist** with must-fail conditions matching the two must-fix warnings above.

Execution rule: complete A4→A10 in order; no sidebar/inspector visual rewrites during this track unless required to satisfy a must-fix warning or broken interaction.

Pre-v1.0 scope guard: **do not** perform large AppKit rewrites of `NavigationSidebarView` or `InspectorView` before v1.0. Priority is hybrid stability (SwiftUI content + AppKit shell working correctly together).

---

## Post-v1.0 roadmap

### v1.0.1
- [ ] **R1** Full sidebar organiser — drag-and-drop group creation, import/export of favourite sets.
- [x] **R2** Final branding consolidation — all user-facing labels, titles, and support paths consistent under the chosen app name. ✅ Completed via R3–R7 (Ledger project identity, runtime labels, defaults/app-support migration, and release artifact naming).

### Branding rename (Ledger)
Full blueprint: `output/BRANDING_NAMING_REFRESH_IMPLEMENTATION.md`. User-facing name is **Ledger** — partially applied. Remaining work:

Current status: repo/project folder rename to `Ledger` is complete, display/bundle identifiers are `Ledger`, and Xcode target/scheme/plist/entitlements are now aligned to `Ledger`. Remaining `ExifEditMac` references are limited to SwiftPM module naming and explicit legacy migration compatibility paths.

- [x] **R3** **A — Identity + build settings** — verify `project.pbxproj`, `.xcscheme`, `Info.plist`, `Base.xcconfig` are all consistent for Ledger. ✅ Done: target/scheme renamed to Ledger; Info.plist/entitlements renamed to `Config/Ledger-*`; release scripts default to `SCHEME_NAME=Ledger`.
- [x] **R4** **B — Runtime strings + UI labels** — audit app runtime labels and any remaining hardcoded app-name strings for consistency. ✅ Runtime/user-facing labels now resolve via `AppBrand.displayName` (`Ledger`), with no stale user-visible app name strings found.
- [x] **R5** **C — Persistent domains** — UserDefaults migration: read old `Logbook.*` keys as fallback; write sentinel `Ledger.Migration.v1Completed`. ✅ Sentinel + migration already in place; defaults reads now check current keys first, then `Logbook.*` fallback keys.
- [x] **R6** **D — App Support directory** — atomic move `~/Library/Application Support/Logbook` → `Ledger`; fallback read from old path if move fails. ✅ `performBrandMigrationsIfNeeded()` + `migrateLegacySupportDirectoryIfNeeded()` implemented; stores read current path with legacy fallback candidates.
- [x] **R7** **E — Release + distribution artifacts** — verify `scripts/release/*.sh` and DMG name output as `Ledger.dmg`. ✅ Release scripts use `Ledger.xcodeproj` and `APP_DISPLAY_NAME`; DMG name is derived from app bundle name (`$APP_NAME.dmg`), which resolves to `Ledger.dmg`.

### Future features
- [ ] **R8** GPX import and conflict-resolution UI (in QA matrix; currently untested).
- [ ] **R9** Restore last-used folder on relaunch (consider privacy and removable-drive edge cases). (QA checklist #2)
- [ ] **R10** Large-folder performance pass (1,000+ RAW files — scrolling, thumbnail loading, apply speed).
- [ ] **R11** App Store submission track.
- [ ] **R12** Drag-and-drop metadata export / batch rename.
### AppKit migration (iPad target dropped — pure macOS)

- [ ] **R13** **NavigationSidebarView → AppKit** (`NSTableView` flat sidebar) — explicitly deferred to post-v1.0 by pre-v1.0 scope guard; keep current SwiftUI sidebar and stabilize hybrid boundary first (A4–A10).
- [ ] **R16** **InspectorView → AppKit** (`NSViewController` + `NSScrollView` + stacked field controls) — explicitly deferred to post-v1.0 by pre-v1.0 scope guard; keep current SwiftUI inspector and stabilize hybrid boundary first (A4–A10).
- [ ] **R17** **PresetManagerSheet → AppKit** (`NSTableView` in `NSPanel`) — small SwiftUI `List` with same scroll/selection instability as the sidebar. Natural follow-on after R13; low implementation effort. Medium value.
- [ ] **R18** **PresetEditorSheet → AppKit** (optional) — modal sheet; scroll stability matters less here. Main benefit would be DatePicker style consistency with Inspector (`.stepperField`), and removing the per-tag `valueBinding(for:)` pattern. Low priority.
- [ ] **R14** **Search** — expand-to-field toolbar button (like Notes.app on macOS 26) with metadata-aware search: filename, date range, camera/lens, rating, keyword. `searchQuery`/`filteredBrowserItems` infrastructure already in place.
- [ ] **R15** **Configurable list columns** — show/hide and reorder columns; add EXIF-backed columns (date modified, camera make/model, lens, focal length, ISO, aperture, shutter speed, pixel dimensions). Each new column gets a `BrowserSort` case and `NSSortDescriptor` prototype; sort and header infrastructure from P7 carries forward directly.
- [ ] **R19** **Optional gallery UX reintroduction pack (post-v1.0)** — reintroduce non-baseline gallery polish one feature at a time: image-hugging selector ring, ring-anchored pending-dot positioning, ring geometry continuity during staged rotate/flip, tile/image transition polish beyond native defaults, and aggressive gallery prefetch heuristics.
- [ ] **R20** **Toolbar customization/editing support** — support user-configurable toolbar composition/reordering in a future pass (while preserving native AppKit toolbar behavior and validation).
- [ ] **R21** **Permanent architecture principle: AppKit shell + SwiftUI islands** — keep AppKit as the long-term owner of window/split/menu/focus lifecycle, with SwiftUI used selectively for contained content surfaces. Require explicit model-driven bridges and clear ownership boundaries for any new UI work.

---

## v1.0.1 (Patch) — Stability + Trust

Released: **2026-03-04**.

- [x] **Inspector map sustained CPU** (~10% at idle): live `MKMapView` display link ran unconditionally; replaced with `MKMapSnapshotter` static snapshot. Fixed post-1.0.0.
- [x] Folder-switch render parity across sort modes (`B43`): fixed mismatch where `Date/Size/Kind` transitions could flash/reorder differently from `Name`. Browser switch is now atomic and preserves visible content until replacement is ready.
- [x] Locked-file preflight/reporting (`B42` / `R22`): preflight check on `FileAttributeKey.immutable` and `.isWritableKey` before apply; locked files reported with targeted message rather than silently written through.
- [x] `pendingCommitsByFile` cleared on metadata reload success (inspector can show stale applied values if a subsequent apply partially fails).
- [x] `Task.isCancelled` checks after `Task.sleep` in deferred async tasks (metadata prefetch, preview preload — cancellation is currently swallowed by `try?`, body runs regardless).
- [x] `NumberFormatter`/`DateFormatter` instances promoted to static properties where currently allocated per-call.
- [x] Sidebar context menu improvements: label polish (Unpin, Move Up/Down) and Remove action for recents and pinned folders; removing the selected folder reverts to no-selection state.

---

## v1.1 — Import System Completion + Settings

Released: **2026-03-10**.

### General UX
- [x] Status bar message audit: review all status messages for necessity; promote any that warrant it to modal dialogs.
- [x] UI/UX polish: settings pane layout and sizes.

### Inspector Groundwork (prerequisite for Settings)
- [x] `inspectorRefreshRevision`: eliminate the duplicate `@State` copy in `InspectorView`; model's `@Published` value is now the single source of truth.
- [x] Edit-session snapshots: moved `editSessionSnapshots` out of `InspectorView` `@State` and into `AppModel` so edit-in-progress state is model-owned.
- [x] `groupedEditableTags`: migrated from tuple-array to dictionary-based grouping (with stable ordered section projection for UI consumers).

### Import
- [x] Unified import framework and shared UI flow for:
  - [x] CSV
  - [x] GPX
  - [x] Reference Folder
  - [x] EOS-1V CSV
- [x] Single import flow: load source -> match/preview/conflicts -> target scope (selection/folder) -> apply.
- [x] EOS-1V ingest parity in Swift (mapping/normalization/matching semantics from existing EOS-1V tool).
- [x] EOS-1V lens-tag resolver architecture: remove hardcoded lens inference and route through a policy layer that can read future Settings defaults plus per-import overrides.
- [x] Import sheet preview/stage parity hardening + structured import report output.
- [x] **Reference-based metadata apply**: select one image as reference, apply chosen metadata fields to a selection. Uses ExifTool `-tagsFromFile`. Sheet UI: select reference file → choose field groups → preview diff → confirm.

### Settings
- [x] Inspector field visibility controls.
- [x] Backup enable/disable controls with menu/context behavior alignment.
- [x] Clear recent folders action (handled via existing context-menu remove flow).

### Export
- [x] ExifTool CSV export feature.
- [x] Send to Photos handoff workflow.
- [x] Send to Lightroom Classic handoff workflow.

---

## v1.2

- [x] Welcome/version screen using `AppWelcomeViewController` from SharedUI (WhatsNewKit-backed). Show on first run; reuse for "What's New" on major version updates.
- [x] Batch Rename first release: preview, token rendering, selection/folder scope, deterministic ordering, collision disambiguation, backup-aware execution, and rename restore support.
- [x] Expanded inspector metadata coverage across EXIF / IPTC / XMP, including rating, pick flag, colour label, and field visibility controls.
- [x] Finder-style breadcrumb bar.
- [x] Dock icon badge and Dock menu shortcuts for favourites, recents, and Open Folder.
- [x] List column customisation (including Exif-backed columns).
- [x] Drag to reorder sidebar favourites.
- [x] Click-to-drag rubber-band selection in gallery view.
- [x] **Metadata export CSV/JSON**: select fields, export to CSV or JSON for spreadsheet editing or audit reporting.
- [x] **Backup retention policy**: keep-last-N model, persistence, prune path wiring, and Settings UI controls. Infrastructure (`BackupManager.pruneOperations`) already exists; this is the Settings surface and wiring.
- [x] Sidebar rewritten in AppKit.
- [x] SharedUI/AppKit browser parity hardening for focus, keyboard, and selection behaviour in list/gallery/inspector flows.
- [x] Browser context-menu handoff to Photos, Lightroom, and Lightroom Classic.
- [x] Thumbnail pipeline rewrite with shared cache / broker hardening.
- [x] **Full native QuickLook rewrite**: replace the previous preview implementation with a fully native QuickLook integration (`QuickLookPanelCoordinator` in SharedUI, added 2026-03-21, between the v1.1 and v1.2 release windows).
- [x] Inspector preview cache size cap (currently trimmed by URL list only; large folders cache all previews with no memory ceiling).
- [x] Date/Time adjust workflow in Inspector + Image menu: AppKit-backed date controls, `Set…` launch flow, Shift/Time Zone/Specific/File modes, Apply-to (`Original` / `Digitised` / `Modified`) targeting, and effective-change preview/apply gating.
- [x] Workflow sheet parity pass across Import / Batch Rename / Date-Time: shared `WorkflowSheetContainer` rhythm, `WorkflowFormRow` adoption, and aligned section/footer spacing.
- [x] Location adjust workflow (MapKit): workflow sheet + Inspector/Image-menu entry points, search + map interaction, latitude/longitude preview line, preview popover, and staged GPS lat/lon writes.
- [x] Performance streamlining pass, Phases 1-3 (no feature cuts): payload/runtime/CPU reductions tracked in `docs/v1.2-performance-streamlining-plan.md`. Phase 4 (architecture guardrails) carried forward to v1.3.

---

## v1.2.3 (Patch) — macOS Golden Gate Readiness

Compatibility and modernisation pass for macOS 27 on Xcode 27. Full build against SDK 27 is clean (2026-08-15): no `@State` macro or `@ContentBuilder` source breakage, so no forced SwiftUI fixes. UI/Liquid Glass adoption deliberately deferred.

- [x] **Geocoder migration**: `CLGeocoder` / `reverseGeocodeLocation` / `placemark` in `DateTimeAdjustSheetView.swift` are deprecated as of macOS 26. Migrated to MapKit `MKReverseGeocodingRequest` + `addressRepresentations` (both reverse-geocode and search paths share `applyResolvedPlace(from:)`). Known behaviour change: the new API exposes no structured administrative area, so **State/Province is removed from the Set Location sheet entirely** (no checkbox, no "no resolved value" warning; `LocationAdvancedField.geocodableCases` is the single source). Manual entry remains via the inspector's IPTC State field — verified against MKAddressRepresentations' runtime surface, decision 2026-08-15.
- [x] Fix SharedUI concurrency warning: capture of non-Sendable `SourceID.Type` in an isolated closure (`QuickLookPanelCoordinator.swift`). Fixed by constraining `SourceID: Hashable & Sendable` — correct semantics for an ID that crosses the KVO/main-actor boundary; both consumers (Ledger `URL`, Librarian `String`) already satisfy it.
- [x] Fix capture-semantics warning in apply/restore path (`AppModel+ApplyRestore.swift`): inner post-apply task used `[weak self]` while the enclosing apply closure held `self` strongly. Dropped the weak capture to match the sibling alert task — `AppModel` is app-lifetime and the task is short and unstored, so no cycle risk; state reset (`isApplyingMetadata`) now reliably runs.

---

## v1.3 — Import Maturity + Polish

Released: **2026-08-31**. User-facing summary in `CHANGELOG.md`.

### Import

- [x] **EOS-1V lens-tag policy system**: originally scoped as policy modes + unknown-focal-length handling + named lens profiles + override selector. Decision 2026-08-29: the `Do not write lens`/`Single lens for import` policy modes are **not being pursued** — the EOS-1V CSV is a source of truth and this feature is just interpreting it into accurate EXIF values; if a resolved lens is wrong for a given frame, editing it after import is trivial, so a dedicated policy switch isn't worth the complexity. Scope narrowed to just the registry and the picker UI:
  - [x] **Named lens profiles**: `LensProfile` registry (`LensProfiles.swift`) replacing the hardcoded embedded CSV (`EOSLensMappingEmbedded.swift`, deleted in v1.4 Phase 3.4 once confirmed unused at runtime). Editable via Settings → General → "Manage Lenses…" (bridging to SwiftUI via `NSHostingController` + `presentAsSheet`), Prime/Zoom radio toggle, per-lens focal range + aperture(s). `applyEOSLensPolicy`'s matching sources from `AppModel.lensProfiles` instead of the embedded table.
  - [x] **Ambiguous-lens picker → one sheet**: `EOSLensChoiceSheetView` replaces the old loop of blocking `NSAlert`s (`ImportSession.chooseLens`, removed). One sheet lists every ambiguous frame at once (filename, focal length, frame aperture, a native grey `InspectorPopupField` dropdown per row), grouped by focal length with a live-linked "Apply to all at this focal length" checkbox per group. A frame left on "Leave Blank" now just skips that one field — the rest of the batch still stages, unlike the old alert's full-abort cancel.
  - [x] **Unknown focal length behaviour** (no registered lens covers a row's focal length): one aggregated "No Registered Lens Matches" alert per import, listing every affected focal length and total frame count. "Manage Lenses…" (default) opens the lens registry sheet and automatically retries matching on close; "Continue Without Lens Tags" skips the `exif-lens` field for just those focal lengths for the current import only; "Cancel Import" aborts.

### EOS-1V Direct Connection

- [x] **Direct EOS-1V connection over the ES-E1 cable** (unplanned addition, built 2026-08-29–31): a new sidebar device entry with Connect / Shooting Data / Date and Time tabs, backed by `eos1v-serial`'s versioned `machine` JSON subprocess interface (`EOS1VSessionController`, `EOS1VToolClient`).
  - [x] Connect: wake/search/download flow with live status.
  - [x] Shooting Data: flat multi-select roll table, roll detail sheet (SwiftUI `Table`, one column per frame field), local-only delete/restore (tombstone — never touches the camera or downloaded files, see `EOS1VDeletedRollsStore`).
  - [x] Canon-format CSV export verified byte-for-byte against real Windows XP ES-E1 exports (`EOS1VRollCSVExporter`).
  - [x] Date and Time tab: frozen camera-clock-vs-macOS-clock comparison snapshot (not live-ticking).
  - Personal/Custom Functions screens were built but hidden — not part of this release's scope; code and data plumbing stay intact for future reactivation.
  - Camera clock **write** capability exists end-to-end but is disabled pending a real-hardware wake-failure diagnosis — see `docs/eos1v-set-clock-review-2026-08.md`.
  - Future editable roll-metadata layer parked — see the v2.0+ entry in `docs/ROADMAP.md` and `docs/eos1v-roll-metadata-plan-2026-08.md`.

### Browse

- [x] **iCloud Drive file-state UI**: badge undownloaded/cloud-placeholder files with an iCloud symbol (SharedUI's `Gallery/GalleryOverlay.swift`), detected via `URLResourceValues` (`isUbiquitousItem` / `ubiquitousItemDownloadingStatus`) — previously looked like a broken thumbnail or metadata-read failure.
- [x] **Finder-style gallery view**: filmstrip along bottom, large preview at top — third browser mode alongside list and grid.
- [x] Gallery metadata lines/subtitle customisation.

### Metadata

- [x] Metadata copy/paste: field-level and metadata-set copy/paste.
- [x] ExifTool console: live readout of ExifTool commands and output as operations run, mirroring what would appear if running ExifTool directly in the terminal.

### Maintenance

- [x] Bump bundled ExifTool from 13.50 to 13.55 (2026-08-31), including the 13.53/13.54 security updates. Homebrew's formula tops out at 13.55 as of this date; exiftool.org's own latest (13.59) would mean vendoring outside the package manager — revisit once Homebrew catches up.
- [x] No-op batch rename: suppress the staged/applied state when a rename pattern produces no changes; keep the sheet open and explain why.

---

## v1.4 — Performance + Native Foundations (Pre-2.0)

Released: **2026-09-26**. No new user-facing features by design — a measured
performance, efficiency, and native-macOS-quality pass before the v2.0 browser
rewrite. Full sequence, benchmark method, and acceptance gates in
`docs/v1.4-performance-audit-plan.md`; the complete phase-by-phase evidence
trail is in `docs/v1.4-progress.md` (2800+ lines — every hypothesis, including
rejected ones, recorded there). User-facing summary in `CHANGELOG.md`. Closed
out by an external architecture-outcome review (2026-09-27,
`docs/v1.4-architecture-outcome-review-2026-09-27.md`) which found two real
remaining defects (observer-lifecycle mismatches, incomplete task
cancellation) fixed the same day, and confirmed the rest of its findings as
either already resolved or deliberately, evidence-backed deferred to v1.4.1/v1.5.

### Responsiveness

- [x] **Established the performance baseline** (Phase 0): proportionate Release-build benchmark harness, stable OSSignposter signposts, focused UI automation (`LedgerUITests`, 4 deterministic journeys), repeatable cold/warm browser scenarios against a bounded 1,000+ file corpus.
- [x] **Kept interaction paths non-blocking** (Phase 1.1, 1.3): `ThumbnailService.cachedImage` made memory-only (no synchronous disk I/O on the browser path); hangs/hitches captured and fixed across launch, scrolling, selection, view switching, menus, live resize.
- [x] **Narrowed browser rendering** (Phase 1.2, 1.4): browser render updates routed only to the active controller; EOS-1V Combine subscription teardown/lifecycle gap fixed.

### Data + Resource Efficiency

- [x] **Made metadata and preview loading demand-driven** (Phase 2.1–2.3): demand-gated metadata prefetch with benchmark-isolation fix; old-folder speculative preview/metadata warm work bounded; a unified quiescence signal surfaced and correctly attributed a real ~34s idle delay to preference-driven demand (not a bug) rather than to the harness.
- [x] **Bounded retained state and caches** (Phase 3.1, 3.3): `metadataByFile` bounded by a protected LRU cap; thumbnail disk cache bounded to a measured 1GB budget.
- [x] **Reduce ExifTool process cost** (Phase 3.2) — **investigated, rejected**: correct batching needs ExifTool's `-stay_open` persistent-process protocol (a later external review, R7, corrected the premise that this is strictly *required* — multiple command groups per invocation via `-execute` are also possible — but backup interleaving and per-file result attribution still make batching genuinely nontrivial), for a benefit that doesn't help the common single/few-file case. User confirmed current write performance already acceptable; no code changed.
- [x] **Reduced shipping payload** (Phase 3.4): confirmed redundancy removed (including the now-dead `EOSLensMappingEmbedded.swift`), EOS-1V Python tool bundled like ExifTool.

### Native macOS Foundations

- [x] **Owned the menu bar from launch** (Phase 4.0–4.1): static AppKit menu hierarchy (`MainMenu.xib`, `NSApplicationMain`) built before hosted UI or the first window; menu-wiring extracted out of `MainContentView.swift`; responder-chain validation retained for dynamic state; timing/reinjection workarounds removed. Detailed diagnosis: `docs/menu-bar-architecture-audit-2026-08.md`.
- [x] **Unified window and list persistence** (Phase 4.2): AppKit-native window/split-view/table-column autosave adopted; competing persistence and layout feedback loops removed, including the long-standing List view column-width-doesn't-persist bug. Detailed diagnosis: `docs/window-list-resize-diagnosis-2026-07.md`.
- [x] **Selection-highlight consistency across Icon/List/Gallery** (Phase 4.3) — resolved opposite to the item's original framing: List's grey-dim-on-focus-loss was confirmed genuine native AppKit behaviour (matches Photos.app), not a bug. The real fix was removing List's focus-stealing accent-flash-on-click glitch, then making Icon/Gallery's `GallerySelectionAppearanceObserver` first-responder-aware to match List's correct behaviour (it previously only checked window-key/app-active state).
- [x] **Completed the coordinated SharedUI audit** (Phase 4.3): every macOS 26 chrome workaround re-verified live on macOS 27 — most confirmed moot and deleted (`ToolbarAppearanceAdapter`, `ScrollContentInsetMode.manual(top:)`, `SidebarCellView.backgroundStyle` override), one root-caused instead of just re-confirmed (sidebar launch-time scroll snap — traced to toolbar-after-content window construction order, fixed at the root in both Ledger and Librarian). Full detail in SharedUI's `docs/Roadmap.md`.

### Native UI Consistency & Polish

(Added 2026-09-03, in the same "strip out hacks, prefer native" spirit as the
SharedUI chrome-workaround audit above. Full root-cause detail, exact code
patterns, and a "how to repeat this on Librarian" section for every item live
in `docs/ui-consistency-polish-2026-09.md`.)

- [x] Accent colour consistency: confirmed only one accent colour is specified anywhere; the perceived sidebar-vs-list difference is entirely explained by AppKit's own two built-in selection-highlight styles (`.sourceList` vs `.regular`) — nothing to change.
- [x] User-facing text pass against HIG + `docs/USER_FACING_COPY_GUIDELINES.md`: empty-state subtitle punctuation fixed; 9 concrete issues found and fixed across alerts/buttons/sheet titles (3 alerts converted to inline/status text, wording normalized to sentence-case, "ExifTool" capitalization fixed, "Clear Changes"/"Clear Backups…" renamed to "Discard Changes"/"Delete Backups…").
- [x] Sheet layout/consistency audit: found and migrated 2 outliers (`PresetEditorSheet`/`PresetManagerSheet`) to the shared `WorkflowSheetContainer` rhythm already used by the other 8 sheets; fixed a real sizing divergence and a stray title-font mismatch along the way.
- [x] Button colour consistency (grey vs accent) — live-verified with real screenshots, not just code review: destructive buttons needed an explicit `.tint(.red)` (role alone doesn't render red); an ambient `.tint()` on two parent views was bleeding teal into plain `.bordered` buttons that should have been neutral grey, removed.
- [x] Ellipsis usage audit against HIG (ellipsis = "needs new information before completing"): fixed 2 ("Delete Backups…" and "What's New in Ledger…" both removed — neither actually gathers input).
- [x] Polish animations: `.symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value:)` added to Inspector star rating, flag, Rotate, Flip, and Open buttons, keyed on real state-change signals so only the cell that actually changed bounces.
- [x] **Reopened last folder and selection on launch** (2026-09-25): previously the app always launched with no folder selected even though window frame/split/column-width state already survived quit-and-relaunch via Secure State Restoration. Matches the HIG's "Launching" guidance and the app's own existing persistence stance. Full plan: `docs/last-folder-selection-restore-plan-2026-09.md`.
- Inspector field copy/clear icon visual-height mismatch — investigated twice (2026-09-03/04), no confirmed root cause either time, fully reverted both times. Dropped from the roadmap entirely (2026-09-27) rather than carried forward — cosmetic-only, two failed diagnosis attempts already invested.

### Evidence-Gated Maintenance

- [x] **Decompose only where the work requires it**: menu-wiring extraction (Phase 4.0) and confirmed dead-code removal (`EOSLensMappingEmbedded.swift`, Phase 3.4) both landed; broader `MainContentView.swift`/`AppModel` splitting was deliberately not pursued further — the 2026-09-27 external architecture review confirmed this as "deliberate, reasonable narrowing... further splitting alone would not improve ownership or performance," not unexplained drift.
- [x] **Optimise browser reloads only when measured** (Phase 5.1): measured via real signpost instrumentation and a driven XCUITest session — full reloads only fire on genuine list-identity changes (folder switch, real sort reorder, view-mode first-activation); per-selection-change work is already bounded to visible cells. No material problem found; no code changed.
- [x] **Treat Observation as optional** (Phase 5.2): deliberately not opened — no evidence of a residual hosted-SwiftUI problem after Phase 5.1's measurement, matching the plan's own "may be skipped" framing. Combine retained throughout.
- [x] **Closed with like-for-like verification** (Phase 6, completed 2026-09-27): baseline repeated on the same machine/corpora/toolchain (quiescence's +124ms root-caused to Phase 4.2's `sizeToFit()`, accepted as a deliberate one-time cost, reconfirmed stable twice); automated gate green (49 LedgerCore + 221+ app-side tests); manual gate fully walked and signed off, all 10 sections PASS (§7 macOS 26 chrome explicitly skipped — no machine/VM available).

### Closing architecture-outcome review (2026-09-27)

External frontier-model review of the actual v1.4 outcome against these original criteria (`docs/v1.4-architecture-outcome-review-2026-09-27.md`). Verdict: "a successful native-shell cleanup with unfinished pipeline and lifecycle hardening" — not a full unqualified pass, but a materially clean result. Two concrete findings (R1: observer-lifecycle mismatches in `EOS1VConnectViewController`/`SharedBrowserListViewController`; R3: incomplete `Task` cancellation beneath `ExifToolService`/the metadata pipeline) were real, fixed the same day, and full-suite verified. The remaining six findings (menu-validation synchronous filesystem discovery, hidden-mode metadata demand, an overstated structural-isolation claim, unresolved macOS 26/map-drag verification, a batching-rationale correction, and a since-redundant sidebar scroll-repair) were explicitly deferred to v1.4.1/v1.5 rather than fixed under release pressure — logged in `docs/v1.4-progress.md`'s Decision log, not dropped.

Deferred: HDR-aware previews (moved to v2.0 — belongs with the in-app viewer and gallery-pipeline rewrite; benefit today is limited since film-scan TIFFs are SDR).
