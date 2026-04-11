#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"

APP_PATH="$("$ROOT_DIR/scripts/release/archive.sh")"

DMG_PATH="$("$ROOT_DIR/scripts/release/create_dmg.sh" "$APP_PATH")"
"$ROOT_DIR/scripts/release/notarize.sh" "$DMG_PATH"

echo "Release artifact: $DMG_PATH"
