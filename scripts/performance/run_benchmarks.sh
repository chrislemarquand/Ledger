#!/usr/bin/env bash
set -euo pipefail

# Phase 0.2 of docs/v1.4-performance-audit-plan.md: a thin, on-demand
# benchmark runner. Deliberately not a bespoke performance platform — see
# docs/v1.4-progress.md for what this does and doesn't cover yet.
#
# Usage:
#   scripts/performance/run_benchmarks.sh --scenario launch [options]
#   scripts/performance/run_benchmarks.sh --scenario folder-load --corpus scripts/performance/corpus/browse [options]
#   scripts/performance/run_benchmarks.sh --scenario quiescence --corpus scripts/performance/corpus/browse [options]
#
# Options:
#   --scenario NAME       Journey to measure: "launch", "folder-load", or
#                          "quiescence" (Phase 2.3 — time from folder switch
#                          to AppModel+Quiescence.swift's isFolderWorkActive
#                          becoming false: folder metadata prefetch demand
#                          gate aside, this is hydration + initial thumbnail
#                          warmup + any preview preload settling).
#   --iterations N        Measured iterations (default 5, per the plan's
#                          "start with five measured iterations for noisy
#                          UI journeys").
#   --warmup N            Unmeasured warm-up iterations first (default 1).
#   --corpus PATH         Browse corpus folder (>=1000 files — see
#                          generate_browse_corpus.sh). Optional for "launch";
#                          required for "folder-load".
#   --trace               Capture one additional Time Profiler trace via
#                          `xctrace` on a representative run (not counted in
#                          the measured iterations/median). Raw .trace output
#                          is gitignored; open it in Instruments to inspect.
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
CAPTURE_TRACE=0
SKIP_BUILD=0

usage() {
  sed -n '3,29p' "${BASH_SOURCE[0]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) SCENARIO="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --warmup) WARMUP_ITERATIONS="$2"; shift 2 ;;
    --corpus) BROWSE_CORPUS="$2"; shift 2 ;;
    --trace) CAPTURE_TRACE=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "$SCENARIO" in
  launch|folder-load|quiescence) ;;
  *)
    echo "error: unknown --scenario '$SCENARIO'. Only 'launch', 'folder-load', and 'quiescence' exist today; add new scenarios to this script deliberately, don't guess." >&2
    exit 1
    ;;
esac

if [[ ( "$SCENARIO" == "folder-load" || "$SCENARIO" == "quiescence" ) && -z "$BROWSE_CORPUS" ]]; then
  echo "error: --scenario $SCENARIO requires --corpus (see scripts/performance/generate_browse_corpus.sh)" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR/raw" "$REPORTS_DIR"

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

# CORRECTED 2026-08-31: this used to redirect HOME and call `defaults write`
# against the real bundle ID, believing that isolated preferences/caches per
# the plan's "isolated preferences/cache roots" requirement. Verified directly
# that this NEVER worked: on this platform, `NSHomeDirectory()` resolves via
# the real system passwd record (getpwuid), not the `HOME` environment
# variable, for an unsandboxed GUI process — and `defaults`/NSUserDefaults
# reads and writes go through cfprefsd, which is keyed the same way. Every
# "isolated" launch before this fix was actually reading and writing the
# real ~/Library/Preferences/com.chrislemarquand.Ledger.plist, the real
# ~/Library/Caches thumbnail cache, and the real
# ~/Library/Application Support/Ledger/recent_locations.json — confirmed by
# finding real preference values (a user-configured Icon subtitle column)
# leaking into what was assumed to be a fresh isolated run, and by finding
# corpus/test paths polluting the real Recents list. See
# feedback_macos_home_isolation_broken memory and docs/v1.4-progress.md.
#
# Actually-correct mechanism: NSUserDefaults' documented command-line
# "argument domain" — passing `-KeyName Value` as launch arguments (not env
# vars, not `defaults write`) creates a temporary, non-persisted, per-process
# override that shadows the real value without ever touching a plist. No
# HOME redirection, no mkdir, no real-preferences risk.
run_isolated_launch() {
  # Redirect the launched app's stdout/stderr away from this function's own
  # stdout. Without this, `pid=$(run_isolated_launch ...)` at the call site
  # blocks until the app *exits* — command substitution reads until EOF on
  # its pipe, and the backgrounded app inherits (and holds open) that same
  # pipe's write end for as long as it runs. This was observed directly: the
  # script appeared to hang with Ledger open and never getting killed,
  # because it was still stuck on this line, before ever reaching the code
  # that terminates the process.
  #
  # -disableSparkleAutoupdate and -skipRecentLocationPersistence gate their
  # respective behaviors in code (LedgerApp.swift / AppModel+Sidebar.swift) —
  # more reliable than hoping a UserDefaults value is honored. Any additional
  # args (e.g. -openFolderPath) are passed through by the caller.
  "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" \
    -disableSparkleAutoupdate \
    -skipRecentLocationPersistence \
    -"${ID_PREFIX}.welcomeLastSeenVersion" "$MINOR_VERSION" \
    "$@" > /dev/null 2>&1 &
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
# the span in milliseconds between the LAST `begin_name` "begin" signpost and
# the first `end_name` "end" or "event" signpost after it, or empty if not
# found. Field shape verified against a real capture on 2026-08-31:
# signpost events carry `signpostName` ("Launch", "MenuReady",
# "FirstStablePaint", ...) and `signpostType` ("begin"/"event"/"end") — NOT
# `category` or `eventMessage` (which is always empty for signposts). Pass
# the same name twice for a plain begin/end interval (the "launch" and
# "quiescence" scenarios); different names measure the span between an
# interval's begin and a separate event fired later (the "folder-load"
# scenario's FolderLoad-begin -> FirstStablePaint-event span).
#
# Uses the LAST begin, not the first: confirmed directly (2026-08-31, Phase
# 2.3) that opening a folder via `-openFolderPath` on a real dev machine can
# fire more than one begin/end cycle for the same name in one launch — e.g.
# the app restoring its previously-selected sidebar location on launch, moments
# before `-openFolderPath` redirects to the benchmark corpus, produces a
# begin/end/begin/end sequence where the FIRST cycle is a same-run artifact,
# not the journey being measured. AppModel+Quiescence.swift already discards a
# superseded measurement's meaning (tagged "superseded by ..." rather than a
# real duration); this extractor now matches that by always resetting to the
# most recent begin before it looks for that begin's end.
extract_signpost_span_ms() {
  local log_file="$1"
  local begin_name="$2"
  local end_name="$3"
  /usr/bin/python3 - "$log_file" "$begin_name" "$end_name" <<'PY'
import json, sys
from datetime import datetime

log_file, begin_name, end_name = sys.argv[1], sys.argv[2], sys.argv[3]
begin_ts = None
end_ts = None
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        name = entry.get("signpostName")
        kind = entry.get("signpostType")
        if name == begin_name and kind == "begin":
            begin_ts = entry.get("timestamp")
            end_ts = None
            continue
        if begin_ts is not None and end_ts is None and name == end_name and kind in ("end", "event"):
            end_ts = entry.get("timestamp")

if begin_ts and end_ts:
    def parse(t):
        return datetime.strptime(t, "%Y-%m-%d %H:%M:%S.%f%z")
    delta = (parse(end_ts) - parse(begin_ts)).total_seconds() * 1000
    print(f"{delta:.1f}")
PY
}

# Scenario-specific launch args and signpost span to measure.
if [[ "$SCENARIO" == "folder-load" ]]; then
  SCENARIO_LAUNCH_ARGS=(-openFolderPath "$BROWSE_CORPUS")
  BEGIN_SIGNPOST="FolderLoad"
  END_SIGNPOST="FirstStablePaint"
  METRIC_LABEL="folder load (folder-load begin → first stable paint signpost span)"
elif [[ "$SCENARIO" == "quiescence" ]]; then
  SCENARIO_LAUNCH_ARGS=(-openFolderPath "$BROWSE_CORPUS")
  BEGIN_SIGNPOST="Quiescence"
  END_SIGNPOST="Quiescence"
  METRIC_LABEL="folder quiescence (folder switch → AppModel fully idle signpost interval)"
else
  SCENARIO_LAUNCH_ARGS=()
  BEGIN_SIGNPOST="Launch"
  END_SIGNPOST="Launch"
  METRIC_LABEL="launch (menu ready → window shown signpost interval)"
fi

WARMUP_SETTLE_SECONDS=4
if [[ "$SCENARIO" == "folder-load" ]]; then
  WARMUP_SETTLE_SECONDS=20
elif [[ "$SCENARIO" == "quiescence" ]]; then
  # v1.4 Phase 2.3: confirmed directly (2026-08-31) on a real dev machine that
  # real quiescence for this corpus takes ~30-45s of continuous 90-130% CPU —
  # NOT a measurement artifact (verified with `ps` CPU sampling across the
  # whole window) — so this needs a much longer settle/capture window than
  # folder-load's "first paint" measurement. See docs/v1.4-progress.md's
  # Phase 2.3 section for what's actually consuming that CPU (not yet
  # root-caused — flagged as a real finding, not silently hidden).
  WARMUP_SETTLE_SECONDS=60
fi

echo "==> Warm-up ($WARMUP_ITERATIONS unmeasured iteration(s))"
for ((i = 1; i <= WARMUP_ITERATIONS; i++)); do
  pid=$(run_isolated_launch "${SCENARIO_LAUNCH_ARGS[@]:-}")
  sleep "$WARMUP_SETTLE_SECONDS"
  terminate_process "$pid"
done

if [[ "$CAPTURE_TRACE" -eq 1 ]]; then
  echo "==> Capturing one Time Profiler trace via xctrace (not counted in measured iterations)"
  TRACE_FILE="$RUN_RAW_DIR/$SCENARIO.trace"
  # xctrace exits non-zero when --time-limit forcibly ends the launched
  # process, even on a fully successful capture (verified directly: the log
  # says "Recording completed. Saving output file..." on the same run that
  # reports a non-zero exit) — so check for the trace file actually landing,
  # not the exit code.
  xcrun xctrace record \
    --template 'Time Profiler' \
    --time-limit 10s \
    --no-prompt \
    --output "$TRACE_FILE" \
    --launch -- "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" \
      -disableSparkleAutoupdate -skipRecentLocationPersistence \
      -"${ID_PREFIX}.welcomeLastSeenVersion" "$MINOR_VERSION" \
      "${SCENARIO_LAUNCH_ARGS[@]}" \
    > "$RUN_RAW_DIR/xctrace.log" 2>&1 || true
  if [[ -d "$TRACE_FILE" ]]; then
    echo "    Trace: $TRACE_FILE (open in Instruments to inspect)"
  else
    echo "    warning: xctrace capture failed, see $RUN_RAW_DIR/xctrace.log" >&2
  fi
fi

echo "==> Measured iterations ($ITERATIONS)"
declare -a WALL_TIMES_MS=()
declare -a PEAK_RSS_KB=()

for ((i = 1; i <= ITERATIONS; i++)); do
  log_file="$RUN_RAW_DIR/$SCENARIO-$i.ndjson"

  log stream --style ndjson --signpost --predicate "subsystem == \"$BUNDLE_ID\"" > "$log_file" 2>/dev/null &
  log_stream_pid=$!
  sleep 0.4 # let log stream attach before the process we're measuring exists

  pid=$(run_isolated_launch "${SCENARIO_LAUNCH_ARGS[@]:-}")

  # Sample RSS while the app settles; report the peak. folder-load with a
  # 1000+ file corpus needs longer to reach FirstStablePaint than a bare
  # launch does — 8x0.25s (2s total) was tuned for "launch" only.
  rss_samples=8
  rss_interval=0.25
  if [[ "$SCENARIO" == "folder-load" ]]; then
    rss_samples=40
    rss_interval=0.5
  elif [[ "$SCENARIO" == "quiescence" ]]; then
    rss_samples=60
    rss_interval=1
  fi
  peak_rss=0
  for _ in $(seq 1 "$rss_samples"); do
    sleep "$rss_interval"
    rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [[ -n "$rss" && "$rss" -gt "$peak_rss" ]]; then
      peak_rss="$rss"
    fi
  done

  terminate_process "$log_stream_pid" 2
  terminate_process "$pid"

  duration_ms="$(extract_signpost_span_ms "$log_file" "$BEGIN_SIGNPOST" "$END_SIGNPOST" || true)"
  if [[ -z "$duration_ms" ]]; then
    echo "    iteration $i: could not extract $METRIC_LABEL duration from $log_file (raw log kept for inspection)" >&2
  else
    echo "    iteration $i: ${SCENARIO}=${duration_ms}ms peak_rss=${peak_rss}KB"
    WALL_TIMES_MS+=("$duration_ms")
  fi
  PEAK_RSS_KB+=("$peak_rss")
done

# Bash 3.2 (macOS's system bash) has no `local -n` nameref, so this takes the
# array elements as positional args rather than an array name. Filters out
# empty args first: "${arr[@]:-}" on a truly-empty array under `set -u`
# word-splits to zero args, but if $1 ever legitimately arrives empty, count
# it correctly rather than crashing on an unbound `sorted[$mid]` (observed
# directly: n computed from $# didn't match the post-filter sorted array).
median() {
  local vals=()
  for v in "$@"; do
    [[ -n "$v" ]] && vals+=("$v")
  done
  local n="${#vals[@]}"
  if (( n == 0 )); then echo "n/a"; return; fi
  local sorted=($(printf '%s\n' "${vals[@]}" | sort -n))
  local mid=$(( n / 2 ))
  if (( n % 2 == 1 )); then
    echo "${sorted[$mid]}"
  else
    /usr/bin/python3 -c "print(f'{(${sorted[$((mid-1))]} + ${sorted[$mid]}) / 2:.1f}')"
  fi
}

MEDIAN_LAUNCH_MS="$(median "${WALL_TIMES_MS[@]:-}")"
MEDIAN_PEAK_RSS_KB="$(median "${PEAK_RSS_KB[@]:-}")"

CORPUS_NOTE="not used by the launch scenario"
if [[ "$SCENARIO" == "folder-load" || "$SCENARIO" == "quiescence" ]]; then
  CORPUS_NOTE="used as the opened folder for this run"
fi

TRACE_NOTE="Not captured this run (pass --trace to record one)."
if [[ "$CAPTURE_TRACE" -eq 1 ]]; then
  TRACE_NOTE="\`scripts/performance/output/raw/$RUN_ID/$SCENARIO.trace\` (gitignored — open in Instruments)."
fi

REPORT_FILE="$REPORTS_DIR/$SCENARIO-$RUN_ID.md"
cat > "$REPORT_FILE" <<EOF
# Benchmark report: $SCENARIO — $RUN_ID

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
- Browse corpus: $CORPUS_FILE_COUNT files, $CORPUS_BYTES ($CORPUS_NOTE)

## App bundle size
- Total: $(( TOTAL_SIZE_BYTES / 1024 / 1024 )) MB
- Executable: $(( EXECUTABLE_SIZE_BYTES / 1024 )) KB
- Bundled ExifTool: $(( EXIFTOOL_SIZE_BYTES / 1024 / 1024 )) MB

## $SCENARIO scenario
- Warm-up iterations: $WARMUP_ITERATIONS
- Measured iterations: $ITERATIONS
- Median $METRIC_LABEL: ${MEDIAN_LAUNCH_MS} ms
- Median peak resident memory: ${MEDIAN_PEAK_RSS_KB} KB
- Raw per-iteration values (ms): ${WALL_TIMES_MS[*]:-none extracted}
- Raw per-iteration peak RSS (KB): ${PEAK_RSS_KB[*]:-none}

## Instruments trace
$TRACE_NOTE

## Not yet captured by this thin harness
CPU%, idle wakeups, Energy Impact, and disk I/O are not automated here yet —
per the plan, these are reviewed manually in Instruments/Activity Monitor
(or from the --trace capture above) until repeated use shows scripting them
pays for itself. Subprocess count (ExifTool launches) is not yet tracked
here; it matters once a metadata-loading scenario is added.

Raw logs: \`scripts/performance/output/raw/$RUN_ID/\` (gitignored — not
committed).
EOF

echo ""
echo "==> Report written: $REPORT_FILE"
cat "$REPORT_FILE"
