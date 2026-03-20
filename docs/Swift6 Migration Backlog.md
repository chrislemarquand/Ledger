# Swift 6 Migration Backlog

## Policy

- App target stays on Swift 6.
- Keep migration incremental by module area.
- Treat release-blocking compile errors first, then warning cleanup.

## Current Status (2026-03-20)

- `SWIFT_VERSION = 6.0` is already set for Ledger targets.
- Core app builds under current baseline.

## Backlog

1. Clean remaining SwiftPM package warnings in local `swift test` runs.
- Current warning: unhandled non-source files under `Sources/Ledger` (`Assets.xcassets`, `AppIcon.icon`).
- Action: exclude non-source assets from Package target, or model them as resources if needed.

2. Audit concurrency annotations in app modules.
- Review `@MainActor` boundaries in `AppModel` extensions and background tasks.
- Add `Sendable` conformances/wrappers where data crosses task boundaries.

3. Tighten release gates after warning cleanup.
- Keep `release_check.sh` strict on Swift warnings.
- Enforce warning-free baseline before next release tag.

## Execution Order

1. Package warning cleanup.
2. UI layer concurrency audit (`AppModel+UI`/selection/preview paths).
3. Import/indexing/background task sendability pass.
