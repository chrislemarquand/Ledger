# Engineering Baseline

This document defines the required engineering baseline for Librarian and Ledger.

## Platform and Language

- Deployment target: `macOS 26`.
- Swift language mode: `Swift 6`.
- Release branches must build without Swift compiler warnings.

## Project Configuration

- Use explicit `Config/Base.xcconfig`, `Config/Debug.xcconfig`, and `Config/Release.xcconfig`.
- Keep policy settings in xcconfig files instead of duplicating them in `project.pbxproj`.
- Use explicit `Info.plist` and entitlements file paths.

## Dependencies

- `SharedUI` is a local path package dependency (`.package(path: "../SharedUI")`),
  not a remote pinned tag — a deliberate, enforced policy (see
  `scripts/deps/verify_shared_ui_pin.sh`, which errors if a remote pin is
  detected instead). Other remote dependencies (e.g. `WhatsNewKit`, `Sparkle`)
  remain normal pinned Swift package references.
- Commit `Package.resolved` for reproducible builds of the pinned remote dependencies.

## Release and Quality Gates

- Provide scripted release checks in `scripts/release/`.
- Minimum checks: app build + tests.
- Release tags should only be created from a warning-free release branch.

## SharedUI Release Order

`SharedUI` is a local path dependency (see Dependencies above), so there is
no separate SharedUI tag/release step — the app repo always builds against
whatever is currently checked out at `../SharedUI`. Verify with
`scripts/deps/verify_shared_ui_pin.sh` before releasing.
