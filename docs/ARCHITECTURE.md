# Architecture

macOS-only photo metadata editor (EXIF / IPTC / XMP) built on exiftool.
**Target**: macOS 15+. **Swift**: 6.2 strict concurrency. **No iPad / iOS target.**

---

## Package structure

```
ExifEdit (Swift Package)
├── Sources/ExifEditCore      — library; no AppKit/SwiftUI dependency
│   ├── Domain.swift          — value types: MetadataField, FileMetadataSnapshot, MetadataPatch, EditOperation, OperationResult
│   ├── ExifEditEngine.swift  — public actor; orchestrates read/write/restore
│   ├── ExifToolService.swift — spawns the exiftool subprocess; protocol + impl
│   ├── ExifToolCommandBuilder.swift — builds exiftool CLI arguments
│   ├── BackupManager.swift   — copies originals before every write; protocol + impl
│   └── MetadataValidator.swift — validates patches before write
│
└── Sources/Ledger       — executable; AppKit + SwiftUI
    ├── LedgerApp.swift       — @main; pure AppKit entry (LedgerMain + AppDelegate)
    ├── AppModel.swift        — @MainActor ObservableObject; all UI state (~4,900 lines)
    ├── MainContentView.swift — NativeThreePaneSplitViewController + AppKit menus/toolbar + browser container
    ├── NavigationSidebarView.swift
    ├── BrowserListView.swift
    ├── BrowserGalleryView.swift
    ├── InspectorView.swift
    └── PresetSheets.swift

Tests/ExifEditCoreTests       — runnable via `swift test` and xcodebuild
Tests/LedgerTests        — compiles but NOT runnable (see Tests section below)
```

The Xcode project (`Ledger.xcodeproj`) wraps the SPM package. Build settings and version are in `Config/Base.xcconfig`.

---

## Layer architecture

```
┌─────────────────────────────────────────┐
│              ExifEditMac                │
│                                         │
│  LedgerMain (@main) ──▶ AppDelegate     │
│                        └──────────────▶  │
│                        NativeThreePaneSplitVC  ← AppKit window controller
│                    │                   │
│          ┌─────────┼──────────┐        │
│          ▼         ▼          ▼        │
│     Sidebar      Browser   Inspector     │
│     (SwiftUI)    (AppKit)   (SwiftUI)    │
│                                         │
│  AppModel (@MainActor ObservableObject) │  ← single source of truth
│        │                                │
│        ▼                                │
│  ExifEditEngine (actor)                 │  ← ExifEditCore
│        │                                │
│   ExifToolService  BackupManager        │
│        │                                │
│      exiftool binary (bundled)          │
└─────────────────────────────────────────┘
```

---

## Window layout

`NativeThreePaneSplitViewController` (`MainContentView.swift`) is an `NSSplitViewController` that owns the entire window. It creates:

```
NSSplitViewController
├── NSSplitViewItem (sidebar)   → NSHostingController<NavigationSidebarView>
└── NSSplitViewController (nested content)
    ├── NSSplitViewItem         → BrowserContainerViewController (pure AppKit)
    │   (hosts BrowserListViewController + BrowserGalleryViewController and switches visibility by mode)
    └── NSSplitViewItem         → NSHostingController<InspectorView>
```

All `NSHostingController` instances use `.sizingOptions = []` so SwiftUI does not drive pane sizing — the split view owns all geometry.

The toolbar is built entirely in AppKit (`NativeToolbarDelegate`). Top-level menus are also rebuilt/injected in AppKit (`MainContentView.swift`) and validated through `NSMenuItemValidation`. Actions route through the responder chain with `NSApp.sendAction(_:to:from:)`.

**Toolbar vs menu enabled-state pattern**: menu items *pull* state on demand via `menuWillOpen` (always fresh). Toolbar items must be *pushed* — `NativeToolbarDelegate.refreshFromModel()` sets `item.isEnabled` and is called from `installUIRefreshObservers()` in `NativeThreePaneSplitViewController`. If a toolbar button fails to reflect a state change, the relevant `@Published` property is missing from that observer list.

---

## AppModel

`AppModel` is a `@MainActor` `ObservableObject` that holds all application state. There is one instance, created by `AppDelegate` and passed into every view. Key state groups:

| Group | Key properties |
|-------|---------------|
| Sidebar | `selectedSidebarID`, `sidebarItems`, `favourites` |
| Browser | `browserItems`, `filteredBrowserItems` (@Published cached), `browserSort`, `browserViewMode` |
| Selection | `selectedFileURLs` (Set), `selectionAnchorURL`, `selectionFocusURL` |
| Metadata | `metadataByFile` ([URL: FileMetadataSnapshot]), `pendingEditsByFile`, `pendingCommitsByFile` |
| Inspector | `inspectorState`, `collapsedInspectorSections` |
| Status | `statusMessage`, `isLoadingFiles`, `isApplyingMetadata` |
| Presets | `presets` ([EditPreset]) |

`filteredBrowserItems` is a cached `@Published private(set)` var rebuilt by `rebuildFilteredBrowserItems()` whenever `browserItems`, `searchQuery`, or `browserSort` change — do not recompute it ad-hoc.

---

## Selection model

Multi-file selection works like Finder:

- **Plain click**: replaces `selectedFileURLs` with `{url}`; sets anchor + focus
- **Cmd-click**: toggles url in/out of set; updates anchor + focus
- **Shift-click**: range from `selectionAnchorURL` to target
- **Cmd+Shift-click**: additive range (union)

Entry point: `AppModel.selectFile(_:modifiers:in:)`. `selectionAnchorURL` and `selectionFocusURL` are both `private`.

The browser views (list and gallery) are AppKit `NSTableView` / `NSCollectionView`. They carry an `isApplyingProgrammaticSelection` flag that suppresses delegate callbacks during model→view syncs to prevent selection bouncing. Modified-click events are intercepted in custom `NSTableView`/`NSCollectionView` subclasses and routed to `selectFile(_:modifiers:in:)` before the view syncs back.

---

## Metadata read / write flow

**Read**
```
AppModel.loadMetadataForSelection(urls:)
  └── ExifEditEngine.readMetadata(files:)   [actor hop]
        └── ExifToolService.readMetadata()   [spawns exiftool process]
              returns [FileMetadataSnapshot]
  └── AppModel stores result in metadataByFile[url]
  └── AppModel.recalculateInspectorState()  [debounced 100ms]
```

**Write (Apply)**
```
AppModel.applyChanges(for:)
  └── builds metadata patches + staged image ops per file
  └── ExifEditEngine.apply(operation:) / writeMetadataWithoutBackup(operation:) [actor hop]
        └── MetadataValidator.validate()
        └── BackupManager.createBackup()    → ~/Library/Application Support/<Brand>/Backups/<UUID>/
        └── ExifToolService.writeMetadata() [spawns exiftool process]
              returns OperationResult (succeeded:, failed:)
  └── AppModel clears committed pending state, invalidates thumbnails/previews for succeeded files,
      then re-reads stale metadata for the current selection
```

**Restore**
```
AppModel.restoreFromBackup(urls:)
  └── ExifEditEngine.restore(operationID:)
        └── BackupManager.restoreBackup()  [copies backup files back to originals]
```

Backups are pruned on launch via `BackupManager.pruneOperations(keepLast:)` (called in a detached Task from AppModel.init).

---

## Thumbnail pipeline

`ThumbnailPipeline` (top of `AppModel.swift`) is a stateless enum of static wrappers over `ThumbnailService`, which owns the thumbnail cache and generation.

Generation order for likely-image files: ImageIO oriented thumbnail → QuickLook → `NSImage(contentsOf:)` → workspace icon fallback. For other file types: QuickLook first.

Both `BrowserListViewController` and `BrowserGalleryViewController` use a `SharedThumbnailRequestBroker` actor to deduplicate concurrent requests for the same URL. After Apply/Restore/Clear, `AppModel` invalidates browser thumbnail URLs so both views refresh from disk-consistent data.

---

## SwiftUI / AppKit hybrid notes

The browser views (`BrowserListView`, `BrowserGalleryView`) are `NSViewControllerRepresentable` wrappers around full AppKit implementations. The SwiftUI outer shell is ~10 lines each; all logic lives in the AppKit controllers.

The purely SwiftUI views (sidebar, inspector, preset sheets) are hosted in `NSHostingController` instances. They observe `AppModel` via `@ObservedObject`.

### Permanent design principle (post-v1.0)

Ledger follows an **AppKit shell + SwiftUI islands** architecture.

- AppKit remains the owner of:
  - window lifecycle/state restoration policy
  - split layout and pane geometry/collapse
  - menu and toolbar command lifecycle/validation
  - responder chain and keyboard focus routing
- SwiftUI is used selectively for contained feature surfaces (for example sidebar/inspector content), hosted inside AppKit.
- `AppModel` remains the single state authority across both layers.
- Cross-layer interactions must use explicit intent methods and targeted state observation, not broad invalidation or implicit ownership overlap.

### Hybrid contract (A4, pre-v1.0 source of truth)

This section is the authoritative contract for the v1.0 hybrid architecture (Roadmap A4–A10). New UI work must follow these rules.

#### Ownership

- AppKit owns:
  - window lifecycle and restoration policy
  - split-view geometry/collapse state
  - menu construction/injection/validation
  - first-responder routing and keyboard command dispatch
- SwiftUI owns:
  - sidebar and inspector content rendering only
  - local view interaction state that does not define app truth
- `AppModel` owns:
  - all mutable app state (`@Published`) and side-effecting operations

#### State-flow rules

- Boundary direction is one-way by default: `AppModel` -> SwiftUI/AppKit render state.
- User intents from SwiftUI/AppKit call explicit `AppModel` methods.
- Do not rely on implicit two-way bindings for cross-boundary app state when a direct intent method exists.

#### Update-cycle safety rules

- Never synchronously mutate `@Published` from SwiftUI update callbacks that can run inside render/layout (`onChange`, `DisclosureGroup` setters, focus callbacks, picker callbacks).
- When a boundary callback must update model state, defer to next runloop (`DispatchQueue.main.async` or `Task { @MainActor ... }`).
- AppKit layout/resize notifications must not synchronously write SwiftUI-observed model state; use deferred/coalesced sync.

#### Observation rules

- AppKit host/controllers must not subscribe to broad `model.objectWillChange`.
- Observe only specific `@Published` properties required by that controller.
- Coalesce redundant updates (`removeDuplicates`) before triggering render/title/toolbar refresh work.

#### Warning gate (must-fix pre-v1.0)

- Must not occur on normal smoke path:
  - `Publishing changes from within view updates is not allowed`
  - `NSHostingView is being laid out reentrantly while rendering its SwiftUI content`
- Framework-noise warnings (ICC/CMPhoto/IOSurface) are tracked separately unless tied to user-visible breakage.

#### PR architecture checklist (required for UI changes)

Before merging any UI-facing change, verify and record:

- Shell ownership unchanged:
  - no new SwiftUI ownership of window/split/menu/focus concerns
- Boundary flow is explicit:
  - user action -> explicit `AppModel` intent method
  - no new implicit two-way cross-layer binding loops
- Update-cycle safety:
  - no synchronous `@Published` writes from SwiftUI update/layout callbacks
  - layout/resize notifications do not synchronously publish SwiftUI-observed state
- Observation scope:
  - no new broad `objectWillChange` subscriptions in AppKit hosts
  - targeted publishers with `removeDuplicates` where appropriate
- Warning gate check:
  - normal smoke path does not emit must-fix warnings listed above

#### Hybrid release smoke checklist (run on each release candidate)

Run this path on release candidates:

1. Launch app to default window.
2. Click sidebar folder/source (including privacy-sensitive entries where applicable).
3. Click between thumbnails/list rows rapidly; verify selection remains stable.
4. Switch to a different folder; verify browser repopulates and selection state is valid.
5. Toggle inspector and sidebar; resize panes; verify no re-entrant warning.
6. Edit metadata field in inspector and Apply; verify browser + inspector refresh coherently.
7. Repeat steps 2–6 once more after view-mode switch (gallery <-> list).

Must-fail conditions:
- `Publishing changes from within view updates is not allowed`
- `NSHostingView is being laid out reentrantly while rendering its SwiftUI content`

Known friction areas (candidates for future AppKit rewrite — see ROADMAP R13, R16–R18):
- `InspectorView`: `inspectorRefreshRevision` UInt64 hack forces refreshes; `suppressNextFocusScrollAnimation` flag; manual edit-session `@State` snapshots instead of `UndoManager`
- `NavigationSidebarView`: SwiftUI `List` scroll-position instability; notification-based focus routing
- `PresetManagerSheet`: same List instability

---

## Build

```bash
# Debug build
xcodebuild -project Ledger.xcodeproj \
           -scheme Ledger \
           -configuration Debug \
           -destination 'platform=macOS' \
           build
```

App binary lands at:
`~/Library/Developer/Xcode/DerivedData/Ledger-*/Build/Products/Debug/Ledger.app`

The only expected build warning is:
> `appintentsmetadataprocessor: Metadata extraction skipped. No AppIntents.framework dependency found.`

This is harmless — ignore it.

**Marketing version / build number**: both live in `Config/Base.xcconfig`. Build number is auto-set by `.git/hooks/pre-commit` (`git rev-list --count HEAD + 1`). Do not edit `CURRENT_PROJECT_VERSION` manually.

**exiftool binary**: bundled under `Vendor/`. Not a system dependency.

---

## Tests

| Target | Run with | Status |
|--------|----------|--------|
| `ExifEditCoreTests` | `swift test` or xcodebuild | Runnable |
| `ExifEditMacTests` (in `Tests/LedgerTests`) | — | Compiles but **not runnable**: `AppModel` depends on AppKit and the full app environment; the executable target limitation prevents running these tests in isolation |

Run `swift test` or `xcodebuild test` to execute `ExifEditCoreTests` only.
