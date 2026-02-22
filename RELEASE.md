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
```

## Build, notarize, and package

```bash
./scripts/release/release.sh
```

The final artifact is produced at:

- `build/dmg/Lattice.dmg` (or `build/dmg/<AppName>.dmg` when `APP_NAME` is overridden)

## Script breakdown

- `scripts/release/archive.sh`: archives signed Release build (project/scheme configurable via env vars).
- `scripts/release/notarize.sh`: submits artifact to Apple notarization and staples ticket.
- `scripts/release/create_dmg.sh`: creates and signs DMG from archived app.
- `scripts/release/release.sh`: orchestrates zip notarization + DMG creation/notarization.

## GitHub Actions

A manual workflow is available at `.github/workflows/release.yml`.

Required repository secrets:

- `DEVELOPMENT_TEAM`
- `DEVELOPER_ID_APPLICATION`
- `BUILD_CERTIFICATE_BASE64`
- `P12_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`
