#!/usr/bin/env bash
set -euo pipefail

# Validates the FINISHED artifacts a release will actually ship — after notarization/stapling,
# not before — since that's the state a real user's Mac will see. Never publishes anything;
# read-only checks against files already on disk.
#
# Usage: scripts/release/validate_artifacts.sh <app-path> <zip-path> <dmg-path>

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <app-path> <zip-path> <dmg-path>" >&2
  exit 1
fi

APP_PATH="$1"
ZIP_PATH="$2"
DMG_PATH="$3"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "Artifact validation FAILED: $1" >&2
  exit 1
}

for p in "$APP_PATH" "$ZIP_PATH" "$DMG_PATH"; do
  [[ -e "$p" ]] || fail "missing: $p"
done

echo "[1/6] Gatekeeper assessment (spctl)"
if ! spctl -a -vvv -t install "$APP_PATH" 2>&1 | tee /dev/stderr | grep -q "accepted"; then
  fail "spctl did not accept $APP_PATH"
fi

echo "[2/6] Notarization tickets are actually stapled"
if ! xcrun stapler validate "$APP_PATH" 2>&1; then
  fail "$APP_PATH has no valid stapled ticket"
fi
if ! xcrun stapler validate "$DMG_PATH" 2>&1; then
  fail "$DMG_PATH has no valid stapled ticket"
fi

echo "[3/6] Architecture is arm64 only"
MAIN_BINARY="$APP_PATH/Contents/MacOS/$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP_PATH/Contents/Info.plist")"
ARCHS="$(lipo -archs "$MAIN_BINARY" 2>&1)"
if [[ "$ARCHS" != "arm64" ]]; then
  fail "main executable architectures are '$ARCHS', expected exactly 'arm64'"
fi

echo "[4/6] Bundled ExifTool present and matches required version"
EXIFTOOL_BIN="$APP_PATH/Contents/Resources/exiftool/bin/exiftool"
REQUIRED_VERSION="$(grep -m1 '^EXIFTOOL_REQUIRED_VERSION' "$ROOT_DIR/Config/Base.xcconfig" | sed -E 's/^EXIFTOOL_REQUIRED_VERSION = //')"
[[ -x "$EXIFTOOL_BIN" ]] || fail "exiftool binary missing at $EXIFTOOL_BIN"
FOUND_VERSION="$(PERL5LIB="$(dirname "$EXIFTOOL_BIN")/lib" "$EXIFTOOL_BIN" -ver 2>/dev/null || true)"
[[ "$FOUND_VERSION" == "$REQUIRED_VERSION" ]] || fail "bundled exiftool is $FOUND_VERSION, required $REQUIRED_VERSION"

echo "[5/6] Checksums"
ZIP_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
ZIP_SIZE="$(stat -f%z "$ZIP_PATH")"
DMG_SIZE="$(stat -f%z "$DMG_PATH")"
echo "  ZIP: $ZIP_SHA256  (${ZIP_SIZE} bytes)  $ZIP_PATH"
echo "  DMG: $DMG_SHA256  (${DMG_SIZE} bytes)  $DMG_PATH"

echo "[6/6] Marketing/build version embedded correctly"
BUNDLE_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")"
echo "  CFBundleShortVersionString: $BUNDLE_SHORT_VERSION"
echo "  CFBundleVersion: $BUNDLE_VERSION"

echo
echo "Artifact validation passed."
echo "zip_sha256=$ZIP_SHA256"
echo "dmg_sha256=$DMG_SHA256"
echo "zip_size=$ZIP_SIZE"
echo "dmg_size=$DMG_SIZE"
