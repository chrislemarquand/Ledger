#!/usr/bin/env bash
set -euo pipefail

# Phase 0.2 of docs/v1.4-performance-audit-plan.md: a thin, on-demand
# benchmark runner. Deliberately not a bespoke performance platform — see
# docs/v1.4-progress.md for what this does and doesn't cover yet.
#
# Usage:
#   scripts/performance/run_benchmarks.sh --scenario launch [options]
#
# Options:
#   --scenario NAME       Journey to measure. Only "launch" exists today.
#   --iterations N        Measured iterations (default 5, per the plan's
#                          "start with five measured iterations for noisy
#                          UI journeys").
#   --warmup N            Unmeasured warm-up iterations first (default 1).
#   --corpus PATH         Browse corpus folder (>=1000 files). Optional for
#                          the "launch" scenario; required for any future
#                          folder-based scenario.
#   --skip-build          Reuse the existing Release build under
#                          DERIVED_DATA_PATH instead of rebuilding.
#   --help                Show this help.
#
# Env overrides (matching scripts/release/archive.sh conventions):
#   PROJECT_PATH, SCHEME_NAME, DERIVED_DATA_PATH

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Ledger.xcodeproj}"
SCHEME_NAME="${SCHEME_NAME:-Ledger}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/$(basename "$SCHEME_NAME" | tr '[:upper:]' '[:lower:]')_performance_derived}"
BUNDLE_ID="com.chrislemarquand.Ledger"
ID_PREFIX="Ledger"

OUTPUT_DIR="$ROOT_DIR/scripts/performance/output"
REPORTS_DIR="$ROOT_DIR/scripts/performance/reports"

SCENARIO="launch"
ITERATIONS=5
WARMUP_ITERATIONS=1
BROWSE_CORPUS=""
SKIP_BUILD=0

usage() {
  sed -n '3,25p' "${BASH_SOURCE[0]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) SCENARIO="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --warmup) WARMUP_ITERATIONS="$2"; shift 2 ;;
    --corpus) BROWSE_CORPUS="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "$SCENARIO" != "launch" ]]; then
  echo "error: unknown --scenario '$SCENARIO'. Only 'launch' exists today; add new scenarios to this script deliberately, don't guess." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR/raw" "$OUTPUT_DIR/homes" "$REPORTS_DIR"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_RAW_DIR="$OUTPUT_DIR/raw/$RUN_ID"
mkdir -p "$RUN_RAW_DIR"

echo "==> Preflight: toolchain"
DEVELOPER_DIR_RESOLVED="${DEVELOPER_DIR:-$(xcode-select -p)}"
XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ')"
echo "    DEVELOPER_DIR: $DEVELOPER_DIR_RESOLVED"
echo "    $XCODE_VERSION"
SWIFT_VERSION="$(swift --version 2>&1 | head -1)"
MACOS_VERSION="$(sw_vers -productVersion)"
MAC_MODEL="$(sysctl -n hw.model)"
LEDGER_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
SHAREDUI_COMMIT="$(git -C "$ROOT_DIR/../SharedUI" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

echo "==> Preflight: resolving package dependencies and compiling SharedUI with this toolchain"
# The plan's evidence policy requires this explicitly: SDK-dependent NSMenuItem
# APIs have previously made the default command-line toolchain unsuitable, so
# a measured run must never silently build against the wrong SDK.
xcodebuild -resolvePackageDependencies -project "$PROJECT_PATH" -scheme "$SCHEME_NAME" > "$RUN_RAW_DIR/preflight-resolve.log" 2>&1

if [[ -n "$BROWSE_CORPUS" ]]; then
  echo "==> Validating browse corpus: $BROWSE_CORPUS"
  if [[ ! -d "$BROWSE_CORPUS" ]]; then
    echo "error: --corpus '$BROWSE_CORPUS' is not a directory" >&2
    exit 1
  fi
  CORPUS_FILE_COUNT="$(find "$BROWSE_CORPUS" -maxdepth 1 -type f | wc -l | tr -d ' ')"
  if (( CORPUS_FILE_COUNT < 1000 )); then
    echo "error: browse corpus has $CORPUS_FILE_COUNT files; the plan requires >=1000 representative files" >&2
    exit 1
  fi
  CORPUS_BYTES="$(du -sh "$BROWSE_CORPUS" | cut -f1)"
  echo "    $CORPUS_FILE_COUNT files, $CORPUS_BYTES"
else
  CORPUS_FILE_COUNT="n/a"
  CORPUS_BYTES="n/a"
  echo "==> No --corpus given (fine for the 'launch' scenario, which never touches a folder)"
fi

if [[ "$SKIP_BUILD" -eq 1 ]]; then
  echo "==> --skip-build: reusing existing Release build under $DERIVED_DATA_PATH"
else
  echo "==> Building $SCHEME_NAME (Release, unsigned, arm64) — this is the only supported architecture for measurement"
  BUILD_LOG="$RUN_RAW_DIR/build.log"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    build > "$BUILD_LOG" 2>&1
fi

APP_PATH="$(find "$DERIVED_DATA_PATH/Build/Products/Release" -maxdepth 1 -name '*.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  echo "error: no .app found under $DERIVED_DATA_PATH/Build/Products/Release — build failed or --skip-build used with no prior build" >&2
  exit 1
fi
echo "    Built: $APP_PATH"

APP_VERSION="$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)"
MINOR_VERSION="$(echo "$APP_VERSION" | cut -d. -f1-2)"
EXECUTABLE_NAME="$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleExecutable)"

echo "==> App bundle size"
TOTAL_SIZE_BYTES="$(du -sk "$APP_PATH" | cut -f1)"
EXECUTABLE_SIZE_BYTES="$(stat -f%z "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null || echo 0)"
EXIFTOOL_DIR="$APP_PATH/Contents/Resources/exiftool"
EXIFTOOL_SIZE_BYTES=0
if [[ -d "$EXIFTOOL_DIR" ]]; then
  EXIFTOOL_SIZE_BYTES="$(du -sk "$EXIFTOOL_DIR" | cut -f1)"
  EXIFTOOL_SIZE_BYTES=$(( EXIFTOOL_SIZE_BYTES * 1024 ))
fi
TOTAL_SIZE_BYTES=$(( TOTAL_SIZE_BYTES * 1024 ))
echo "    Total: $(( TOTAL_SIZE_BYTES / 1024 / 1024 )) MB, executable: $(( EXECUTABLE_SIZE_BYTES / 1024 )) KB, exiftool: $(( EXIFTOOL_SIZE_BYTES / 1024 / 1024 )) MB"

# Ledger is not sandboxed (Config/Ledger.entitlements: com.apple.security.app-sandbox = false),
# so redirecting HOME for the launched process fully isolates
# ~/Library/Preferences, ~/Library/Caches, and ~/Library/Application Support
# without touching the real developer environment and without any app-code
# changes. This is the mechanism the plan calls "isolated preferences/cache
# roots."
run_isolated_launch() {
  local run_home="$1"
  mkdir -p "$run_home"

  # Suppress the first-run welcome window (WelcomeCoordinator.swift) by
  # pre-seeding its seen-version marker in the isolated defaults domain only.
  HOME="$run_home" defaults write "$BUNDLE_ID" "${ID_PREFIX}.welcomeLastSeenVersion" -string "$MINOR_VERSION"
  # Best-effort Sparkle background-check suppression via its documented
  # SUEnableAutomaticChecks key. Not independently verified against this
  # Sparkle version's exact internals — if launch logs ever show a Sparkle
  # network hit during a measured run, revisit this.
  HOME="$run_home" defaults write "$BUNDLE_ID" SUEnableAutomaticChecks -bool NO

  # Redirect the launched app's stdout/stderr away from this function's own
  # stdout. Without this, `pid=$(run_isolated_launch ...)` at the call site
  # blocks until the app *exits* — command substitution reads until EOF on
  # its pipe, and the backgrounded app inherits (and holds open) that same
  # pipe's write end for as long as it runs. This was observed directly: the
  # script appeared to hang with Ledger open and never getting killed,
  # because it was still stuck on this line, before ever reaching the code
  # that terminates the process.
  HOME="$run_home" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" > /dev/null 2>&1 &
  echo $!
}

# Sends SIGTERM, polls with kill -0 up to a bound, then SIGKILL — never a bare
# blocking `wait`. Mirrors scripts/release/release_check.sh's run_with_timeout,
# because a bare `kill "$pid"; wait "$pid"` was observed to hang indefinitely
# in this bash (3.2, macOS's system bash) when $pid came from a command
# substitution subshell rather than a direct job of the calling shell.
terminate_process() {
  local pid="$1"
  local timeout_seconds="${2:-5}"
  kill -TERM "$pid" > /dev/null 2>&1 || true
  local elapsed=0
  while kill -0 "$pid" > /dev/null 2>&1; do
    if (( elapsed >= timeout_seconds )); then
      kill -KILL "$pid" > /dev/null 2>&1 || true
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

# Parses the ndjson `log stream --signpost` capture for this run and prints
# the Launch signpost interval's duration in milliseconds, or empty if not
# found. Field shape verified against a real capture on 2026-08-31: signpost
# events carry `signpostName` ("Launch", "MenuReady", ...) and `signpostType`
# ("begin"/"event"/"end") — NOT `category` or `eventMessage` (which is always
# empty for signposts).
extract_launch_duration_ms() {
  local log_file="$1"
  /usr/bin/python3 - "$log_file" <<'PY'
import json, sys
from datetime import datetime

begin_ts = None
end_ts = None
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("signpostName") != "Launch":
            continue
        if entry.get("signpostType") == "begin":
            begin_ts = entry.get("timestamp")
        elif entry.get("signpostType") == "end":
            end_ts = entry.get("timestamp")

if begin_ts and end_ts:
    def parse(t):
        return datetime.strptime(t, "%Y-%m-%d %H:%M:%S.%f%z")
    delta = (parse(end_ts) - parse(begin_ts)).total_seconds() * 1000
    print(f"{delta:.1f}")
PY
}

echo "==> Warm-up ($WARMUP_ITERATIONS unmeasured iteration(s))"
for ((i = 1; i <= WARMUP_ITERATIONS; i++)); do
  run_home="$OUTPUT_DIR/homes/warmup-$i"
  pid=$(run_isolated_launch "$run_home")
  sleep 4
  terminate_process "$pid"
done

echo "==> Measured iterations ($ITERATIONS)"
declare -a WALL_TIMES_MS=()
declare -a PEAK_RSS_KB=()

for ((i = 1; i <= ITERATIONS; i++)); do
  run_home="$OUTPUT_DIR/homes/run-$i"
  log_file="$RUN_RAW_DIR/launch-$i.ndjson"

  log stream --style ndjson --signpost --predicate "subsystem == \"$BUNDLE_ID\"" > "$log_file" 2>/dev/null &
  log_stream_pid=$!
  sleep 0.4 # let log stream attach before the process we're measuring exists

  pid=$(run_isolated_launch "$run_home")

  # Sample RSS a few times while the app settles; report the peak.
  peak_rss=0
  for _ in $(seq 1 8); do
    sleep 0.25
    rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [[ -n "$rss" && "$rss" -gt "$peak_rss" ]]; then
      peak_rss="$rss"
    fi
  done

  terminate_process "$log_stream_pid" 2
  terminate_process "$pid"

  duration_ms="$(extract_launch_duration_ms "$log_file" || true)"
  if [[ -z "$duration_ms" ]]; then
    echo "    iteration $i: could not extract Launch signpost duration from $log_file (raw log kept for inspection)" >&2
  else
    echo "    iteration $i: launch=${duration_ms}ms peak_rss=${peak_rss}KB"
    WALL_TIMES_MS+=("$duration_ms")
  fi
  PEAK_RSS_KB+=("$peak_rss")
done

# Bash 3.2 (macOS's system bash) has no `local -n` nameref, so this takes the
# array elements as positional args rather than an array name.
median() {
  local n=$#
  if (( n == 0 )); then echo "n/a"; return; fi
  local sorted=($(printf '%s\n' "$@" | sort -n))
  local mid=$(( n / 2 ))
  if (( n % 2 == 1 )); then
    echo "${sorted[$mid]}"
  else
    /usr/bin/python3 -c "print(f'{(${sorted[$((mid-1))]} + ${sorted[$mid]}) / 2:.1f}')"
  fi
}

MEDIAN_LAUNCH_MS="$(median "${WALL_TIMES_MS[@]:-}")"
MEDIAN_PEAK_RSS_KB="$(median "${PEAK_RSS_KB[@]:-}")"

REPORT_FILE="$REPORTS_DIR/launch-$RUN_ID.md"
cat > "$REPORT_FILE" <<EOF
# Benchmark report: launch — $RUN_ID

## Environment
- Ledger commit: $LEDGER_COMMIT
- SharedUI commit: $SHAREDUI_COMMIT
- DEVELOPER_DIR: $DEVELOPER_DIR_RESOLVED
- $XCODE_VERSION
- $SWIFT_VERSION
- macOS: $MACOS_VERSION
- Mac model: $MAC_MODEL
- App version: $APP_VERSION

## Corpus
- Browse corpus: $CORPUS_FILE_COUNT files, $CORPUS_BYTES (not used by the launch scenario)

## App bundle size
- Total: $(( TOTAL_SIZE_BYTES / 1024 / 1024 )) MB
- Executable: $(( EXECUTABLE_SIZE_BYTES / 1024 )) KB
- Bundled ExifTool: $(( EXIFTOOL_SIZE_BYTES / 1024 / 1024 )) MB

## Launch scenario
- Warm-up iterations: $WARMUP_ITERATIONS
- Measured iterations: $ITERATIONS
- Median launch time (menu ready → window shown signpost interval): ${MEDIAN_LAUNCH_MS} ms
- Median peak resident memory during launch: ${MEDIAN_PEAK_RSS_KB} KB
- Raw per-iteration values (ms): ${WALL_TIMES_MS[*]:-none extracted}
- Raw per-iteration peak RSS (KB): ${PEAK_RSS_KB[*]:-none}

## Not yet captured by this thin harness
CPU%, idle wakeups, Energy Impact, and disk I/O are not automated here yet —
per the plan, these are reviewed manually in Instruments/Activity Monitor
until repeated use shows scripting them pays for itself. Subprocess count is
not meaningful for the launch scenario (no ExifTool work happens at launch);
this column will matter once a metadata-loading scenario is added.

Raw logs and per-iteration homes: \`scripts/performance/output/raw/$RUN_ID/\`
(gitignored — not committed).
EOF

echo ""
echo "==> Report written: $REPORT_FILE"
cat "$REPORT_FILE"

rm -rf "$OUTPUT_DIR/homes"
