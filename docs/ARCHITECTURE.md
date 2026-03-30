# Architecture

Ledger is a macOS-only photo metadata editor.

- Deployment target: `macOS 26`
- Swift language mode: `Swift 6`
- UI model: AppKit shell with SwiftUI feature surfaces
- Shared dependency: `SharedUI` (pinned tag)

## Repo and targets

Ledger is a Swift Package with an Xcode project wrapper.

```text
Sources/
  ExifEditCore/        # metadata engine + exiftool integration (no app UI)
  Ledger/              # app target (AppKit + SwiftUI + SharedUI)
Tests/
  ExifEditCoreTests/
  LedgerTests/
Config/
  Base.xcconfig
  Debug.xcconfig
  Release.xcconfig
```

`Package.swift` defines:
- library target: `ExifEditCore`
- executable target: `ExifEditMac` (path: `Sources/Ledger`)

`Ledger.xcodeproj` builds the macOS app and uses explicit Info.plist/entitlements from `Config/`.

## Runtime architecture

```text
NSApplication + AppDelegate
  -> NSWindow
    -> NativeThreePaneSplitViewController (AppKit shell)
       -> Sidebar (SwiftUI hosted in AppKit)
       -> Browser area (AppKit list/gallery controllers)
       -> Inspector (SwiftUI hosted in AppKit)

AppModel (@MainActor, single source of truth)
  -> ExifEditCore actor/services
  -> filesystem/exiftool side effects
```

Main ownership:
- `AppModel` owns state, selection, pending edits, apply/restore/import orchestration.
- AppKit shell owns split layout, toolbar/menu wiring, responder-chain actions.
- SwiftUI views render model state and send explicit intents back to `AppModel`.

## SharedUI integration (current)

Ledger now consumes core shared desktop UI pieces from `SharedUI`:

- `ThreePaneSplitViewController` for canonical window split behavior and metrics.
- `AppKitSidebarController` for the sidebar shell behavior.
- `SharedGalleryCollectionView` + `SharedGalleryLayout` for gallery interaction/layout.
- `PinchZoomAccumulator` for consistent pinch-zoom semantics.
- `ToolbarAppearanceAdapter` for toolbar appearance refresh behavior.
- `NSAlert.runSheetOrModal(...)` helper for consistent sheet/modal alert handling.

These are intentionally generic and reusable across apps.

## What stays Ledger-specific

Ledger-specific logic remains in Ledger and is not moved into SharedUI:

- Metadata domain model and write pipeline (`ExifEditCore` + `AppModel` extensions).
- ExifTool command construction/execution and backup/restore behavior.
- Import/export workflows and file-format specific handling.
- Ledger-specific sidebar semantics, inspector field catalog, and editing policies.
- Thumbnail engine details that are coupled to Ledger file-backed browsing.

## UI composition notes

- Browser list and gallery are AppKit-driven for high-volume interaction and keyboard control.
- Sidebar/inspector are SwiftUI views hosted in AppKit panes.
- Menu + toolbar commands route through AppKit selectors into model intents.
- SharedUI primitives are used to keep shell behavior consistent with Librarian.

## Concurrency and safety

- App state coordination remains `@MainActor` in `AppModel`.
- Background work is isolated to explicit tasks/services (metadata reads/writes, thumbnailing, imports).
- Swift 6 migration and backlog are tracked in `docs/Swift6 Migration Backlog.md`.

## Key docs

- `docs/Engineering Baseline.md`
- `docs/RELEASE_CHECKLIST.md`
- `docs/Swift6 Migration Backlog.md`
- `docs/Roadmap.md`
