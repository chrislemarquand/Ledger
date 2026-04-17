# Release, Signing, Notarization, and DMG

This project includes an Xcode project and scripts for direct-download signed/notarized macOS releases.

## Prerequisites

- Xcode command line tools installed.
- A valid `Developer ID Application` certificate in your keychain.
- Apple team ID.
- A configured notarytool keychain profile.

Create notary profile once:

```bash
xcrun notarytool store-credentials "EXIFEDIT_NOTARY" \
  --apple-id "you@example.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password"
```

## Environment variables

```bash
export DEVELOPMENT_TEAM="YOUR_TEAM_ID"
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (YOUR_TEAM_ID)"
export NOTARY_PROFILE="EXIFEDIT_NOTARY"
export SPARKLE_PUBLIC_ED_KEY="YOUR_SPARKLE_PUBLIC_ED_KEY"
export SPARKLE_PRIVATE_KEY="YOUR_SPARKLE_PRIVATE_ED25519_KEY"
```

## Build, notarize, and package

```bash
./scripts/release/release.sh
```

To additionally generate Sparkle `appcast.xml` from the release ZIP:

```bash
GENERATE_APPCAST=1 ./scripts/release/release.sh
```

If Sparkle tools are not in the default checkout location, point to `generate_appcast`:

```bash
SPARKLE_GENERATE_APPCAST="/path/to/Sparkle/bin/generate_appcast" GENERATE_APPCAST=1 ./scripts/release/release.sh
```

Before final v1.2 release packaging, run through `docs/v1.2-performance-streamlining-plan.md` (especially payload-size and runtime sanity checks).

The final artifact is produced at:

- `build/dmg/Ledger.dmg` (or `build/dmg/<AppName>.dmg` when `APP_NAME` is overridden)

## Local Unsigned Release Build (No Developer ID / Notary)

For local validation without signing/notarization:

```bash
xcodebuild \
  -project Ledger.xcodeproj \
  -scheme Ledger \
  -configuration Release \
  -derivedDataPath /tmp/LedgerLocalRelease \
  CODE_SIGNING_ALLOWED=NO \
  build
```

App output:

- `/tmp/LedgerLocalRelease/Build/Products/Release/Ledger.app`

## Script breakdown

- `scripts/release/archive.sh`: archives signed Release build (project/scheme configurable via env vars).
- `scripts/release/notarize.sh`: submits artifact to Apple notarization and staples ticket.
- `scripts/release/create_dmg.sh`: creates and signs DMG from archived app.
- `scripts/release/generate_appcast.sh`: generates Sparkle `appcast.xml` from notarized ZIP artifacts.
- `scripts/release/release.sh`: orchestrates ZIP notarization + DMG creation/notarization, and optional appcast generation.
