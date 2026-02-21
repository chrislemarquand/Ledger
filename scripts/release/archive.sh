#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="$ROOT_DIR/ExifEditMac.xcodeproj"
SCHEME="ExifEditMac"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
ARCHIVE_PATH="$BUILD_DIR/archive/ExifEditMac.xcarchive"

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Team ID.}"
: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your Developer ID Application identity.}"

mkdir -p "$BUILD_DIR/archive"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'platform=macOS' \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/ExifEditMac.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Archive succeeded but app not found at $APP_PATH" >&2
  exit 1
fi

echo "$APP_PATH"
