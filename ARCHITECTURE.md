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
    ├── ExifEditMacApp.swift  — @main; SwiftUI App stub + AppDelegate + menu routing
    ├── AppModel.swift        — @MainActor ObservableObject; all UI state (~4,900 lines)
    ├── MainContentView.swift — NativeThreePaneSplitViewController + BrowserView + utilities
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
│  ExifEditMacApp  ──▶  AppDelegate       │
│        │                                │
│        └──▶  NativeThreePaneSplitVC     │  ← AppKit window controller
│                    │                   │
│          ┌─────────┼──────────┐        │
│          ▼         ▼          ▼        │
│     Sidebar      Browser   Inspector   │  ← NSHostingController → SwiftUI
│       (SwiftUI) (AppKit+SwiftUI)(SwiftUI)│
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

`NativeThreePaneSplitViewController` (`MainContentView.swift`) is an `NSSplitViewController` that owns the entire window. It creates three panes using `NSHostingController` wrappers:

```
NSSplitViewController
├── NSSplitViewItem (sidebar)   → NSHostingController<NavigationSidebarView>
└── NSSplitViewController (nested content)
    ├── NSSplitViewItem         → NSHostingController<BrowserView>
    │   (BrowserView contains BrowserListView + BrowserGalleryView side-by-side)
    └── NSSplitViewItem         → NSHostingController<InspectorView>
```

All `NSHostingController` instances use `.sizingOptions = []` so SwiftUI does not drive pane sizing — the split view owns all geometry.

The toolbar is built entirely in AppKit (`NativeToolbarDelegate`). Menu routing uses `NSApp.sendAction(_:to:from:)` targeting the split view controller via the responder chain; SwiftUI `CommandMenu` is used only for static menu structure.

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
| Status | `statusMessage`, `isLoadingFiles`, `isApplyingChanges` |
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
AppModel.applyPendingEdits(to:)
  └── builds EditOperation from pendingEditsByFile
  └── ExifEditEngine.apply(operation:)      [actor hop]
        └── MetadataValidator.validate()
        └── BackupManager.createBackup()    → ~/Library/Application Support/ExifEdit/Backups/<UUID>/
        └── ExifToolService.writeMetadata() [spawns exiftool process]
              returns OperationResult (succeeded:, failed:)
  └── AppModel updates statusMessage, triggers re-read of affected files
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

`ThumbnailPipeline` (top of `AppModel.swift`) is a stateless enum of static methods backed by `SharedBrowserThumbnailCache` (LRU, max 3,000 entries, thread-safe via `NSLock`).

Generation order for likely-image files: ImageIO oriented thumbnail → QuickLook → `NSImage(contentsOf:)` → workspace icon fallback. For other file types: QuickLook first.

Both `BrowserListViewController` and `BrowserGalleryViewController` use a `SharedThumbnailRequestBroker` actor to deduplicate concurrent requests for the same URL and limit in-flight concurrent thumbnail tasks.

---

## SwiftUI / AppKit hybrid notes

The browser views (`BrowserListView`, `BrowserGalleryView`) are `NSViewControllerRepresentable` wrappers around full AppKit implementations. The SwiftUI outer shell is ~10 lines each; all logic lives in the AppKit controllers.

The purely SwiftUI views (sidebar, inspector, preset sheets) are hosted in `NSHostingController` instances. They observe `AppModel` via `@ObservedObject`.

Known friction areas (candidates for future AppKit rewrite — see ROADMAP R13, R16–R18):
- `InspectorView`: `inspectorRefreshRevision` UInt64 hack forces refreshes; `suppressNextFocusScrollAnimation` flag; manual edit-session `@State` snapshots instead of `UndoManager`
- `NavigationSidebarView`: SwiftUI `List` scroll-position instability; notification-based focus routing
- `PresetManagerSheet`: same List instability

---

## Build

```bash
# Debug build
xcodebuild -project Ledger.xcodeproj \
           -scheme ExifEditMac \
           -configuration Debug \
           -destination 'platform=macOS' \
           build
```

App binary lands at:
`~/Library/Developer/Xcode/DerivedData/ExifEditMac-*/Build/Products/Debug/Lattice.app`

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
| `ExifEditMacTests` | — | **Not runnable** |

`ExifEditMacTests` (`AppModelTests.swift`) depends on `ExifEditMac`, which is an `.executableTarget`. SPM cannot run tests against executables so `swift test` reports 0 tests. It is also not included in the Xcode scheme's test action. It does compile cleanly (`swift build --target ExifEditMacTests`). To make it runnable the target needs to either be added to the scheme with a test host, or AppModel needs to be extracted into a library target.
