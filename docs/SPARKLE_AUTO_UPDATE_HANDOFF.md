# Sparkle Auto-Update Handoff

Last updated: 2026-04-11

## Scope
This effort adds non-App-Store auto-update support for:
- `Ledger`
- `Librarian`
- shared menu wiring in `SharedUI`

Branch used in all three repos:
- `feature/sparkle-auto-update`

## Current Status
Implemented and building locally.

### Done
1. SharedUI menu hook
- Added optional `Check for Updates…` item in `makeStandardAppMenu(...)`.
- Kept SharedUI Sparkle-agnostic.
- Marked menu builders `@MainActor` to satisfy Swift concurrency isolation.

2. App-level updater integration (Ledger + Librarian)
- Added `UpdateService.swift` in each app.
- Sparkle path:
  - Uses `SPUStandardUpdaterController`
  - Launch-time silent background check
  - Manual menu action (`Check for Updates…`)
- Safety guard:
  - Sparkle starts only when `SUFeedURL` + `SUPublicEDKey` are valid.
  - If not configured, updater is disabled gracefully (no startup failure dialog).

3. App menu wiring
- Ledger `AppDelegate` wired `checkForUpdatesAction` to SharedUI menu builder.
- Librarian `AppDelegate` wired same.

4. Info/build config
- Added to both app plists:
  - `SUFeedURL`
  - `SUPublicEDKey = $(SPARKLE_PUBLIC_ED_KEY)`
- Added `SPARKLE_PUBLIC_ED_KEY` placeholder in both `Config/Base.xcconfig` files.

5. Sparkle dependency
- Added Sparkle package reference to both Xcode projects.
- `Package.resolved` updated in both repos.

6. Release automation
- Added `scripts/release/generate_appcast.sh` to both repos.
- Ledger `release.sh` now matches Librarian shape:
  - Build app
  - ZIP for Sparkle updates
  - Notarize ZIP
  - Build DMG
  - Notarize DMG
  - Optional appcast generation (`GENERATE_APPCAST=1`)
- Added/updated GitHub workflows (tag gated):
  - Trigger on `push` tags `v*` and manual dispatch.
  - Build/notarize/package
  - Generate appcast
  - Upload artifacts
  - Deploy appcast to GitHub Pages for tag builds

7. Docs
- Updated both `docs/RELEASE.md` files with Sparkle env vars and appcast instructions.

## Validation Performed
- `xcodebuild -showBuildSettings` succeeded for Ledger and Librarian projects.
- `swift build` succeeded for Ledger and Librarian package builds.
- `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` succeeded for both apps after updater-guard fix.
- Workflow YAML parse check passed for both workflow files.

## Why the earlier popup happened
The popup shown in app (“Unable to Check For Updates”) occurred when Sparkle tried to start without valid feed/key config in the running build.

Fix now in place:
- `UpdateService` checks config validity first.
- Sparkle does not start unless valid.

## Remaining Work (Required for Real Updates)
1. GitHub repo settings/secrets
- Ensure secrets exist in **both** repos:
  - `DEVELOPMENT_TEAM`
  - `DEVELOPER_ID_APPLICATION`
  - `APPLE_ID`
  - `APPLE_APP_SPECIFIC_PASSWORD`
  - `APPLE_TEAM_ID`
  - `BUILD_CERTIFICATE_BASE64`
  - `P12_PASSWORD`
  - `KEYCHAIN_PASSWORD`
  - `SPARKLE_PUBLIC_ED_KEY`
  - `SPARKLE_PRIVATE_KEY`

2. Sparkle key generation/rotation (if not already done)
- Generate EdDSA keys once and store public/private values securely.
- Public key goes to:
  - GitHub secret `SPARKLE_PUBLIC_ED_KEY`
  - runtime plist expansion via xcconfig
- Private key stays in CI secret only (`SPARKLE_PRIVATE_KEY`).

3. Appcast hosting confirmation
- Feed URLs currently set to:
  - `https://chrislemarquand.github.io/Ledger/appcast.xml`
  - `https://chrislemarquand.github.io/Librarian/appcast.xml`
- Confirm repo Pages are enabled and publishing correctly.

4. End-to-end release test (recommended before merge)
- Push branch
- Create test tag (e.g. `v1.2.1-rc1` style if your tag policy allows)
- Verify workflow completes:
  - ZIP + DMG produced
  - appcast.xml generated and deployed
- Install previous build, run app, verify update discovery + install flow.

## File Touchpoints
### SharedUI
- `Sources/SharedUI/Menu/MenuBuilders.swift`

### Ledger
- `.github/workflows/release.yml`
- `Config/Base.xcconfig`
- `Config/Ledger-Info.plist`
- `Ledger.xcodeproj/project.pbxproj`
- `Ledger.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `Sources/Ledger/LedgerApp.swift`
- `Sources/Ledger/UpdateService.swift`
- `scripts/release/release.sh`
- `scripts/release/generate_appcast.sh`
- `docs/RELEASE.md`

### Librarian
- `.github/workflows/release.yml`
- `Config/Base.xcconfig`
- `Config/Librarian-Info.plist`
- `Librarian.xcodeproj/project.pbxproj`
- `Librarian.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `Sources/Librarian/AppDelegate.swift`
- `Sources/Librarian/UpdateService.swift`
- `scripts/release/release.sh`
- `scripts/release/generate_appcast.sh`
- `docs/RELEASE.md`

## Notes / Caveats
- There is a pre-existing local change in Librarian user data file:
  - `Librarian.xcodeproj/xcuserdata/chrislemarquand.xcuserdatad/xcschemes/xcschememanagement.plist`
  - This was not introduced by updater work and was preserved.
- Workflow currently uploads artifacts to Actions and deploys appcast to Pages; if you want GitHub Release attachment automation, add a release upload step.
