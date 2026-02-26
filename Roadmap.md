# Roadmap

Current version: **0.6.2** (build 46). Target: **v1.0**.

Reference items by ID: **B1–B12** bugs · **P1–P23** polish · **N1–N6** native rewrites · **R1–R8** post-v1.0 roadmap.

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

---

## v1.0 — Outstanding polish

### Sidebar
- [x] **P1** ~~SF Symbol accentcolor in context menus~~ — ✅ `.tint(Color.primary)` applied to context menu content, overriding the inherited accent tint; per-item `symbolRenderingMode`/`foregroundStyle` overrides removed.
- [x] **P2** ❌ **Sidebar resize** — snap-to-collapse on drag is intentional macOS 26 Liquid Glass sidebar design (matches Finder and Xcode on 26.2); not an app bug. Three earlier attempts to override this behaviour reverted.
- [ ] **P3** `Should` **Sidebar toggle animation drops frames** — toggling sidebar causes dropped frames; should animate as smoothly as the inspector toggle.
- [ ] **P4** `Should` **Sidebar section collapse not instant under Reduce Motion** — sections should collapse/expand instantly with Reduce Motion enabled. (QA checklist #55)
- [ ] **P5** `Should` **Recents section does not animate on collapse/expand** — other sections animate; Recents does not. Possibly a SwiftUI bug with the bottommost section. (QA checklist #9)
- [ ] **P6** `Should` **Favourites flows after relaunch** — verify pin/unpin/reorder survives a relaunch; stale (deleted folder) favourites should be cleaned up.

### Browser list
- [ ] **P7** `Should` **Column headers don't sort** — clicking a column header has no effect. Should sort by that column, matching Finder and other native apps. (QA log #3)
- [ ] **P8** `Should` **Selection out of view when switching gallery ↔ list** — should scroll-to-selection on mode switch so the selected item is always visible. (QA log #4)

### Browser gallery
- [x] **P9** ✅ Gallery selection ring outset tuned to 5 pt; overlay anchored directly to image view (definitionally concentric, no independent size calculation); `selectionCornerRadius` removed — overlay radius derived as `thumbnailCornerRadius + selectionOutset`.

### QuickLook
- [ ] **P10** `Should` **QuickLook position inconsistent** — window position changes per file. Should always open centred on screen, matching Finder. (QA log #5)

### Inspector
- [x] **P11** ~~Inspector toggle label static~~ — ✅ toolbar label and tooltip now dynamic via `updateInspectorToggle(with:)`. (QA log #6 was stale)
- [ ] **P12** `Should` **Inspector toggle location in toolbar** — should be the last item before the search field so it sits adjacent to what it controls. Currently the Apply button sits between them. (QA log #17)
- [ ] **P13** `Should` **Inspector section collapse not instant under Reduce Motion** — same as P4 but for inspector sections. (QA checklist #56)
- [ ] **P14** `Should` **Inspector dropdown widths inconsistent** — Exposure Program, Flash, and Metering Mode pickers are three different widths. Should all be full-width like the text fields. (QA log #20)
- [ ] **P15** `Should` **Date / time picker layout** — when a date is set, the picker fills only half the inspector width with a clear button to the right. Needs a more elegant full-width layout. (QA log #21)

### Menus
- [x] **P16** ~~"Folder" menu item should say "Image"~~ — ✅ `CommandMenu("Folder")` renamed to `CommandMenu("Image")`.
- [ ] **P17** `Should` **Apply metadata: split into two actions** — replace the single Apply item with: "Apply Metadata Changes to [N Image(s)]" (current selection, dynamic label) and "Apply Metadata Changes to Folder" (mirrors toolbar Apply). (QA log #13)

### Status / toolbar
- [ ] **P18** `Should` **Subtitle / status area** — window subtitle and status bar should always show the most useful context: loading progress, selection count, apply progress, partial failure count, error, or "Ready" at idle.
- [ ] **P19** `Should` **Apply button partial failure count** — status should read e.g. "Applied 47/50 — 3 failed" rather than a generic message.

### Other
- [x] **P20** ✅ Credits now use `smallSystemFontSize` matching the About panel's native credits area. Also fixed B13: `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` removed from target-level project.pbxproj settings that were overriding Base.xcconfig, so version and build now read correctly from the bundle.
- [ ] **P21** `Nice` **Desktop TCC prompt not appearing** — clicking Desktop in the sidebar grants access silently without a TCC privacy prompt. Expected: prompt on first access. (QA checklist #8)
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
