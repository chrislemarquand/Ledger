#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PROJECT_PATH="${PROJECT_PATH:-Ledger.xcodeproj}"
SCHEME_NAME="${SCHEME_NAME:-Ledger}"
LOG_DIR="${LOG_DIR:-/tmp}"
BUILD_LOG="$LOG_DIR/$(basename "$SCHEME_NAME" | tr '[:upper:]' '[:lower:]')_release_check_build.log"
TEST_LOG="$LOG_DIR/$(basename "$SCHEME_NAME" | tr '[:upper:]' '[:lower:]')_release_check_test.log"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/$(basename "$SCHEME_NAME" | tr '[:upper:]' '[:lower:]')_release_check_derived}"
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
BUG_BACKLOG_FILE="${BUG_BACKLOG_FILE:-v1-bug-backlog.md}"
SWIFTPM_SCRATCH_PATH="${SWIFTPM_SCRATCH_PATH:-/tmp/$(basename "$SCHEME_NAME" | tr '[:upper:]' '[:lower:]')_release_check_swiftpm}"
SWIFT_TEST_TIMEOUT_SECONDS="${SWIFT_TEST_TIMEOUT_SECONDS:-900}"

mkdir -p "$CLANG_MODULE_CACHE_PATH"
mkdir -p "$SWIFTPM_SCRATCH_PATH"
export CLANG_MODULE_CACHE_PATH

rm -f "$BUILD_LOG" "$TEST_LOG"

script_id="$(basename "$SCHEME_NAME" | tr '[:upper:]' '[:lower:]')_release_check"
script_lock_file="/tmp/${script_id}.lock"
if [[ -f "$script_lock_file" ]]; then
  existing_pid="$(cat "$script_lock_file" 2>/dev/null || true)"
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && /bin/ps -p "$existing_pid" > /dev/null 2>&1; then
    echo "Another ${script_id} run is active (PID $existing_pid)."
    exit 1
  fi
  rm -f "$script_lock_file"
fi
echo "$$" > "$script_lock_file"
trap 'rm -f "$script_lock_file"' EXIT

cleanup_stale_swiftpm_lock() {
  local lock_file="$1"
  [[ -f "$lock_file" ]] || return 0

  local lock_pid
  lock_pid="$(cat "$lock_file" 2>/dev/null || true)"
  if [[ ! "$lock_pid" =~ ^[0-9]+$ ]]; then
    rm -f "$lock_file"
    return 0
  fi

  if ! /bin/ps -p "$lock_pid" > /dev/null 2>&1; then
    echo "Removing stale SwiftPM lock at $lock_file (dead PID $lock_pid)."
    rm -f "$lock_file"
  fi
}

fail_on_active_swiftpm_process_for_path() {
  local path_fragment="$1"
  local found
  found="$(/bin/ps -ax -o pid= -o command= | /usr/bin/awk -v frag="$path_fragment" '
    index($0, frag) && ($0 ~ /swift-test|swift test|swift-build|swift package/) { print; exit 0 }
  ' || true)"
  if [[ -n "$found" ]]; then
    echo "Active SwiftPM process already using ${path_fragment}:"
    echo "$found"
    echo "Stop it and re-run release_check.sh."
    exit 1
  fi
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  local label="$1"
  shift

  "$@" &
  local cmd_pid=$!
  local elapsed=0

  while kill -0 "$cmd_pid" > /dev/null 2>&1; do
    if (( elapsed >= timeout_seconds )); then
      echo "${label} timed out after ${timeout_seconds}s; terminating PID ${cmd_pid}."
      kill -TERM "$cmd_pid" > /dev/null 2>&1 || true
      sleep 2
      kill -KILL "$cmd_pid" > /dev/null 2>&1 || true
      wait "$cmd_pid" > /dev/null 2>&1 || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$cmd_pid"
}

cleanup_stale_swiftpm_lock "$ROOT_DIR/.build/.lock"
cleanup_stale_swiftpm_lock "$SWIFTPM_SCRATCH_PATH/.lock"
fail_on_active_swiftpm_process_for_path "$SWIFTPM_SCRATCH_PATH"

echo "[1/5] Resolving package dependencies"
xcodebuild -resolvePackageDependencies -project "$PROJECT_PATH" -scheme "$SCHEME_NAME" > /dev/null

if [[ -f "$ROOT_DIR/Package.swift" ]]; then
  echo "[2/5] Running swift test"
  if ! run_with_timeout "$SWIFT_TEST_TIMEOUT_SECONDS" "swift test" ./scripts/test/run_all.sh --scratch-path "$SWIFTPM_SCRATCH_PATH" 2>&1 | tee "$TEST_LOG"; then
    status=${PIPESTATUS[0]}
    if [[ "$status" -eq 124 ]]; then
      echo "swift test hit timeout. See: $TEST_LOG"
    else
      echo "swift test failed. See: $TEST_LOG"
    fi
    exit "$status"
  fi
else
  echo "[2/5] Skipping swift test (no Package.swift at repo root)"
fi

echo "[3/5] Building app target"
xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME_NAME" -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA_PATH" build > "$BUILD_LOG" 2>&1

echo "[4/5] Running app test pass"
if ! xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME_NAME" -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA_PATH" test >> "$BUILD_LOG" 2>&1; then
  if rg -n "not currently configured for the test action|There are no test bundles available to test" "$BUILD_LOG" > /dev/null; then
    echo "No configured tests for scheme $SCHEME_NAME; continuing."
  else
    echo "App test pass failed. See: $BUILD_LOG"
    tail -n 80 "$BUILD_LOG"
    exit 1
  fi
fi

echo "[5/5] Validating warning and bug gates"
if rg -n "warning: .*\\.swift" "$BUILD_LOG" > /dev/null; then
  echo "Build produced warnings. See: $BUILD_LOG"
  rg -n "warning: .*\\.swift" "$BUILD_LOG"
  exit 1
fi

if [[ -f "$BUG_BACKLOG_FILE" ]] && rg -n "^- \[ \] `S0`|^- \[ \] `S1`" "$BUG_BACKLOG_FILE" > /dev/null; then
  echo "Open S0/S1 issues remain in $BUG_BACKLOG_FILE"
  rg -n "^- \[ \] `S0`|^- \[ \] `S1`" "$BUG_BACKLOG_FILE"
  exit 1
fi

echo "Release checks passed."
