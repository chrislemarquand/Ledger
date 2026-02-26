# Roadmap

Current version: **0.6.2** (build 46). Target: **v1.0**.

Reference items by ID: **B1–B16** bugs · **P1–P24** polish · **N1–N6** native rewrites · **A1–A2** architecture · **R1–R13** post-v1.0 roadmap.

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
- [ ] **B4** `Must` **Restore from backup partially failing** — restoring does not succeed for all files in a folder; some retain edited metadata after restore. (QA checklist #46)
- [x] **B5** ~~View → As Gallery / As List broken~~ — ✅ SwiftUI Buttons removed; AppKit NSMenuItems injected with `validateMenuItem` setting checkmarks; Cmd+1 / Cmd+2 key equivalents preserved.
- [x] **B6** ~~View → Sort By checkmark stuck on Name~~ — ✅ SwiftUI Picker removed; AppKit NSMenu injected with `validateMenuItem` setting checkmarks on every menu open.
- [x] **B7** ~~View → Zoom In / Zoom Out not disabled in list mode~~ — ✅ SwiftUI Buttons removed; AppKit NSMenuItems injected; `validateMenuItem` disables both in list mode and at min/max zoom.
- [x] **B8** ~~Inspector / sidebar menu labels always say "Hide"~~ — ✅ Static "Toggle Sidebar" / "Toggle Inspector" labels; always correct regardless of state.

### Inspector
- [ ] **B9** `Must` **Stale metadata shown after Apply** — inspector briefly shows old values before updating after an apply. Should show current values immediately. (QA checklist #8)

### Browser gallery
- [x] **B10** ~~Gallery selector changes colour on rotate~~ — ✅ Fixed in 0.6 via `stagedOpsDisplayToken`; cell no longer fully redraws on rotate.
- [x] **B11** ~~Thumbnail flicker on rotate / flip~~ — ✅ Fixed in 0.6 via `stagedOpsDisplayToken`; display transform updated without clearing thumbnail cache.

### Sidebar
- [x] **B12** ✅ Implementation is correct; residual patchy shadow rendering matches Xcode's sidebar on macOS 26.2 — confirmed system compositor bug, not an app issue. Removed custom layer code; moved window config to `viewWillAppear`.

### About panel
- [x] **B13** ✅ About panel showed version 0.5 (1) instead of current version; `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` were hardcoded in target build settings, silently overriding Base.xcconfig. Removed from project.pbxproj — xcconfig is now sole source of truth.

### SwiftUI rendering
- [ ] **B14** `Must` **`@Published` mutated during view update** — two occurrences of "Publishing changes from within view updates is not allowed" at startup. A `@Published` property is being set inside a SwiftUI view update cycle (likely inspector state recalculation or selection sync). Causes undefined behaviour; fix requires deferring the mutation via `Task { @MainActor in … }` or `DispatchQueue.main.async`. (Debug console, lines 1–2)
- [ ] **B15** `Should` **NSHostingView reentrant layout** — six occurrences of "NSHostingView is being laid out reentrantly while rendering its SwiftUI content. This is not supported and the current layout pass will be skipped." Causes skipped layout passes and visible glitches; likely triggered by the same in-update state mutation as B14. Also produces "CAMetalLayer ignoring invalid setDrawableSize width=0.000000 height=0.000000" from the zero-sized view during the skipped pass. (Debug console)

### Resources
- [ ] **B16** `Should` **Missing bundle resource "default.csv"** — "Failed to locate resource named 'default.csv'" logged at runtime. Something (possibly a preset or export path) looks up a CSV in the app bundle that does not exist. Investigate the call site and either bundle the resource or guard the lookup. (Debug console, line 343)

---

## v1.0 — Outstanding polish

### Sidebar
- [x] **P1** ~~SF Symbol accentcolor in context menus~~ — ✅ `.tint(Color.primary)` applied to context menu content, overriding the inherited accent tint; per-item `symbolRenderingMode`/`foregroundStyle` overrides removed.
- [x] **P2** ❌ **Sidebar resize** — snap-to-collapse on drag is intentional macOS 26 Liquid Glass sidebar design (matches Finder and Xcode on 26.2); not an app bug. Three earlier attempts to override this behaviour reverted.
- [ ] **P3** `Should` **Sidebar toggle animation drops frames** — toggling sidebar causes dropped frames; should animate as smoothly as the inspector toggle.
- [ ] **P4** `Should` **Sidebar section collapse not instant under Reduce Motion** — sections should collapse/expand instantly with Reduce Motion enabled. (QA checklist #55)
- [ ] **P5** `Should` **Recents section does not animate on collapse/expand** ❌ `DisclosureGroup` approach tried and reverted: SwiftUI renders `DisclosureGroup` in a `.listStyle(.sidebar)` List with a left-side chevron (tree-view style), not the right-side chevron used by native macOS sidebar section headers. No SwiftUI API to move the indicator without a fully custom `DisclosureGroupStyle`. Reverting preserves correct right-side chevron on all sections; Recents animation remains broken.
- [ ] **P6** `Should` **Favourites flows after relaunch** — verify pin/unpin/reorder survives a relaunch; stale (deleted folder) favourites should be cleaned up.

### Browser list
- [ ] **P7** `Should` **Column headers don't sort** — clicking a column header has no effect. Should sort by that column, matching Finder and other native apps. (QA log #3)
- [ ] **P8** `Should` **Selection out of view when switching gallery ↔ list** — should scroll-to-selection on mode switch so the selected item is always visible. (QA log #4)

### Browser gallery
- [x] **P9** ✅ Gallery selection ring outset tuned to 5 pt; overlay anchored directly to image view (definitionally concentric, no independent size calculation); `selectionCornerRadius` removed — overlay radius derived as `thumbnailCornerRadius + selectionOutset`.

### QuickLook
- [x] **P10** ✅ **QuickLook position inconsistent** — `QLPreviewPanel.center()` called before `makeKeyAndOrderFront` for first open; `NSWindow.didResizeNotification` observer locks panel height to QL's natural choice for the first image and derives width from QL's own aspect ratio for each subsequent image (mirrors Finder's behaviour); panel stays centred on screen across all navigation; if the panel is already open and the user has dragged it, size/position are still corrected on image change.

### Inspector
- [x] **P11** ~~Inspector toggle label static~~ — ✅ toolbar label and tooltip now dynamic via `updateInspectorToggle(with:)`. (QA log #6 was stale)
- [x] **P12** ✅ Inspector toggle moved to immediately before the search field; Apply button now precedes it.
- [ ] **P13** `Should` **Inspector section collapse not instant under Reduce Motion** — same as P4 but for inspector sections. (QA checklist #56)
- [ ] **P14** `Should` **Inspector dropdown widths inconsistent** — Exposure Program, Flash, and Metering Mode pickers are three different widths. Should all be full-width like the text fields. (QA log #20)
- [ ] **P15** `Should` **Date / time picker layout** — when a date is set, the picker fills only half the inspector width with a clear button to the right. Needs a more elegant full-width layout. (QA log #21)
- [ ] **P24** `Should` **Inspector picker sends invalid tag `""`** — three occurrences of "Picker: the selection `""` is invalid and does not have an associated tag, this will give undefined results." Likely a multi-selection or empty-field picker using `""` as a placeholder instead of an `Optional` binding or nil-coalescing sentinel. Check Exposure Program, Flash, Metering Mode, and any other `String`-bound pickers. (Debug console, lines 891–893)

### Menus
- [x] **P16** ~~"Folder" menu item should say "Image"~~ — ✅ `CommandMenu("Folder")` renamed to `CommandMenu("Image")`.
- [ ] **P17** `Should` **Apply metadata: split into two actions** — replace the single Apply item with: "Apply Metadata Changes to [N Image(s)]" (current selection, dynamic label) and "Apply Metadata Changes to Folder" (mirrors toolbar Apply). (QA log #13)

### Status / toolbar
- [ ] **P18** `Should` **Subtitle / status area** — window subtitle and status bar should always show the most useful context: loading progress, selection count, apply progress, partial failure count, error, or "Ready" at idle.
- [ ] **P19** `Should` **Apply button partial failure count** — status should read e.g. "Applied 47/50 — 3 failed" rather than a generic message.

### Other
- [x] **P20** ✅ Credits now use `smallSystemFontSize` matching the About panel's native credits area. Also fixed B13: `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` removed from target-level project.pbxproj settings that were overriding Base.xcconfig, so version and build now read correctly from the bundle.
- [x] **P21** ❌ **Desktop TCC prompt not appearing** — not fixable without sandboxing. TCC prompts appear for all apps (sandboxed or not) for hardware/system data (Camera, Mic, Photos Library, etc.), but file-system location prompts (Desktop, Documents, Downloads) are only enforced for sandboxed apps on macOS 13+. Silent access to Desktop for a non-sandboxed app is correct macOS behaviour. Will resolve automatically when sandboxed for App Store submission (R11).
- [ ] **P22** `Nice` **Search button should expand to field** — like Liquid Glass apps (Notes.app), the search control should be a button that expands into a text field on click. (QA log #22)
- [ ] **P23** `Nice` **Sidebar toggle right-aligned when expanded** — sidebar toggle should be right-aligned within the sidebar panel when expanded, consistent with Liquid Glass apps. (QA log #23)

---

## v1.0 — Outstanding native UI rewrites

Replace custom implementations with idiomatic SwiftUI / AppKit equivalents.

| ID | Item | Location | Target |
|----|------|----------|--------|
| N1 | Sort / Presets toolbar items | Toolbar | `NSMenuToolbarItem` — decide at implementation time |
| N2 | `BrowserLoadingPlaceholderView` | ~line 1500 | `ProgressView` or `.redacted(reason: .placeholder)` |
| N3 | Sidebar count label | ~line 1294 | `.badge(_:)` modifier |
| N4 | Focus ring on scroll views (2 sites) | ~lines 1785, 2367 | `.focusRingType(.exterior)` |
| N5 | Pending-edit dot (3 sites) | ~lines 1902, 3085, 3410 | SF Symbol `circle.fill` with semantic colour |
| N6 | ~~`toggleInspector` label (static "Hide Inspector")~~ | ~~line 1021~~ | ✅ Done — dynamic label via `updateInspectorToggle(with:)` |

---

## v1.0 — Architecture

- [ ] **A1** **Split MainContentView.swift** — currently 4,367 lines. Target: `NavigationSidebarView`, `BrowserListView`, `BrowserGalleryView`, `InspectorView`, `PresetSheets`. Main file target ~800 lines.
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
- [ ] **R13** AppKit `NSOutlineView`-based sidebar rewrite — would give correct right-side section chevrons with proper collapse/expand animation for all sections (resolves P5), native drag-to-resize, and full macOS sidebar behaviour for free from the API.
