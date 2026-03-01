#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PROJECT_PATH="${PROJECT_PATH:-Ledger.xcodeproj}"
SCHEME_NAME="${SCHEME_NAME:-Ledger}"
LOG_DIR="${LOG_DIR:-/tmp}"
BUILD_LOG="$LOG_DIR/exifedit_release_check_build.log"
TEST_LOG="$LOG_DIR/exifedit_release_check_test.log"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/exifedit_release_check_derived}"
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"

mkdir -p "$CLANG_MODULE_CACHE_PATH"
export CLANG_MODULE_CACHE_PATH

echo "[1/4] Running swift test"
swift test | tee "$TEST_LOG"

echo "[2/4] Building app target"
xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME_NAME" -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA_PATH" build > "$BUILD_LOG" 2>&1

echo "[3/4] Running smoke app test pass"
xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME_NAME" -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA_PATH" test >> "$BUILD_LOG" 2>&1

echo "[4/4] Validating warning and bug gates"
if rg -n "warning: .*\\.swift" "$BUILD_LOG" > /dev/null; then
  echo "Build produced warnings. See: $BUILD_LOG"
  rg -n "warning: .*\\.swift" "$BUILD_LOG"
  exit 1
fi

if rg -n "^- \[ \] `P0`|^- \[ \] `P1`" v1-bug-backlog.md > /dev/null; then
  echo "Open P0/P1 issues remain in v1-bug-backlog.md"
  rg -n "^- \[ \] `P0`|^- \[ \] `P1`" v1-bug-backlog.md
  exit 1
fi

echo "Release checks passed."
