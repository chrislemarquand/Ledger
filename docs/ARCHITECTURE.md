# Architecture

Ledger is a macOS-only photo metadata editor.

- Deployment target: `macOS 26`
- Swift language mode: `Swift 6`
- UI model: AppKit shell with SwiftUI feature surfaces
- Shared dependency: `SharedUI` — local path dependency (`.package(path: "../SharedUI")`
  in `Package.swift`), not a remote pinned tag. This is a deliberate, enforced
  policy (`scripts/deps/verify_shared_ui_pin.sh` errors if a remote pin is
  detected instead), not a stale/WIP state.
- External dependency: `External/eos1v-serial` (git submodule) — a third-party
  Python tool the EOS-1V feature drives as a subprocess; see below.

## Repo and targets

Ledger is a Swift Package with an Xcode project wrapper.

```text
Sources/
  ExifEditCore/        # metadata engine + exiftool integration (no app UI)
  Ledger/              # app target (AppKit + SwiftUI + SharedUI)
    EOS1V/             # EOS-1V device connection feature (see below)
    Import/ ImportUI/  # import pipeline + sheets
Tests/
  ExifEditCoreTests/
  LedgerTests/
Config/
  Base.xcconfig
  Debug.xcconfig
  Release.xcconfig
External/
  eos1v-serial/        # git submodule — third-party Python tool, see below
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

## EOS-1V device connection

Ledger connects to a Canon EOS-1V film camera over the ES-E1 cable (Connect /
Shooting Data / Date and Time tabs, `Sources/Ledger/EOS1V/`). It's a pure
AppKit device screen (matching the AppKit-shell convention above) with
SwiftUI used for self-contained leaf sheets (the roll detail view, the
camera-clock-write sheet) — the same "isolated leaf island" pattern already
used elsewhere in the app, not a departure from it.

The camera itself is never talked to directly. Ledger shells out to
`eos1v_tool.py`, a third-party tool vendored as a git submodule at
`External/eos1v-serial` (private copy, not a live link to the original
upstream project — see `NOTICE.md`), via a versioned JSON-lines `machine`
subprocess interface. Access is policy-gated (`EOS1VToolAccessPolicy`):
read-only by default (`inspect`/`settings`/`download`), plus exactly one
narrowly-scoped write operation (`set-clock`, for correcting the camera's
clock) that's implemented end-to-end but currently disabled pending a
real-hardware diagnosis — see `docs/eos1v-set-clock-review-2026-08.md`.

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
- `docs/ROADMAP.md`
