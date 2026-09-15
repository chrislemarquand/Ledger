#!/usr/bin/env bash
set -euo pipefail

# Local prepare pipeline: preflight -> validate -> build -> verify signature -> notarize+staple
# -> validate finished artifacts -> generate update metadata -> record. This is the "prepare" half
# of the plan's ten-step sequence; steps 8-9 (stage a GitHub draft, then publish) are deliberately
# separate scripts (stage_github_release.sh, publish.sh) run manually afterward, so staging and
# publishing are never accidental side effects of building.
#
# Never rebuilds an already-prepared candidate: re-running this script after a partial failure
# re-verifies what's already on disk rather than blindly redoing signing/notarization work.
#
# Usage: scripts/release/release.sh <marketing-version>
# Env: GENERATE_APPCAST=1 to also produce the merged Sparkle feed (off by default, since not
#      every prepare run is heading toward a release).
#
# The version is a required argument, checked against Config/Base.xcconfig by preflight.sh
# (see its own comment for why that check exists — it's not optional ceremony).

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <marketing-version>  (e.g. 1.4)" >&2
  exit 1
fi
MARKETING_VERSION="$1"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"

# --- Local release lock (mirrors release_check.sh's own PID-lock pattern) ---
LOCK_FILE="/tmp/ledger_release.lock"
if [[ -f "$LOCK_FILE" ]]; then
  existing_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && /bin/ps -p "$existing_pid" >/dev/null 2>&1; then
    echo "Another release preparation is already running (PID $existing_pid)." >&2
    exit 1
  fi
  rm -f "$LOCK_FILE"
fi
echo "$$" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

echo "=== [1/7] Preflight ==="
"$ROOT_DIR/scripts/release/preflight.sh" "$MARKETING_VERSION"

echo "=== [2/7] Validate locally (build + full test suite) ==="
"$ROOT_DIR/scripts/release/release_check.sh"

echo "=== [3/7] Freeze candidate identity ==="
export RELEASE_BUILD_NUMBER="${RELEASE_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
MANIFEST_PATH="$BUILD_DIR/release-candidate.json"
"$ROOT_DIR/scripts/release/write_candidate_manifest.sh" "$MANIFEST_PATH"

echo "=== [4/7] Build (archive + sign) ==="
APP_PATH="$("$ROOT_DIR/scripts/release/archive.sh")"
APP_NAME="$(basename "$APP_PATH" .app)"

echo "=== [5/7] Verify signature ==="
"$ROOT_DIR/scripts/release/verify_signature.sh" "$APP_PATH"

echo "=== [6/7] Notarize, staple, and package ==="
# Submit a throwaway zip for notarization, but staple the .app itself once Accepted — not the
# submission zip. This is the fix for a real bug: the previous version of this script notarized
# the ZIP and then skipped stapling entirely (stapler can't staple a .zip), so the .app inside
# the shipped archive was never actually stapled, defeating offline Gatekeeper acceptance.
SUBMISSION_ZIP="$BUILD_DIR/archive/${APP_NAME}-submission.zip"
rm -f "$SUBMISSION_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$SUBMISSION_ZIP"
"$ROOT_DIR/scripts/release/notarize.sh" "$SUBMISSION_ZIP" "$APP_PATH"
rm -f "$SUBMISSION_ZIP"

# Now re-zip the ALREADY-STAPLED app as the real distributable — this is the actual fix. Every
# earlier version of this pipeline zipped the app before stapling; this is the only correct order.
ZIP_PATH="$BUILD_DIR/archive/${APP_NAME}.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# DMG is built from the now-stapled app, then separately notarized+stapled (a DMG isn't a zip,
# so this is stapler's ordinary single-argument case).
DMG_PATH="$("$ROOT_DIR/scripts/release/create_dmg.sh" "$APP_PATH")"
"$ROOT_DIR/scripts/release/notarize.sh" "$DMG_PATH"

echo "=== [7/7] Validate finished artifacts and record evidence ==="
VALIDATION_OUTPUT="$("$ROOT_DIR/scripts/release/validate_artifacts.sh" "$APP_PATH" "$ZIP_PATH" "$DMG_PATH")"
echo "$VALIDATION_OUTPUT"

APPCAST_PATH=""
if [[ "${GENERATE_APPCAST:-0}" == "1" ]]; then
  echo "=== Generating update metadata (merged with the live feed's history) ==="
  APPCAST_PATH="$("$ROOT_DIR/scripts/release/merge_appcast.sh" "$ZIP_PATH")"
fi

# Record: local, uncommitted evidence bundle — never uploaded, never committed. Credentials are
# never written here; only hashes, paths, and identifiers.
EVIDENCE_DIR="$BUILD_DIR/evidence/$(basename "$APP_NAME")-${RELEASE_BUILD_NUMBER}"
mkdir -p "$EVIDENCE_DIR"
cp "$MANIFEST_PATH" "$EVIDENCE_DIR/candidate-manifest.json"
echo "$VALIDATION_OUTPUT" > "$EVIDENCE_DIR/artifact-validation.txt"
[[ -n "$APPCAST_PATH" ]] && cp "$APPCAST_PATH" "$EVIDENCE_DIR/appcast.xml"
if [[ -d "$APP_PATH.dSYM" || -n "$(find "$BUILD_DIR/archive" -maxdepth 2 -iname '*.dSYM' -print -quit 2>/dev/null)" ]]; then
  DSYM_PATH="$(find "$BUILD_DIR/archive" -maxdepth 3 -iname '*.dSYM' -print -quit 2>/dev/null || true)"
  [[ -n "$DSYM_PATH" ]] && echo "dSYM: $DSYM_PATH" >> "$EVIDENCE_DIR/artifact-validation.txt"
fi

echo
echo "Release artifacts prepared (NOT published):"
echo "  ZIP: $ZIP_PATH"
echo "  DMG: $DMG_PATH"
[[ -n "$APPCAST_PATH" ]] && echo "  Appcast: $APPCAST_PATH"
echo "  Evidence: $EVIDENCE_DIR"
echo
echo "Next steps (manual, never automatic):"
echo "  scripts/release/stage_github_release.sh $MARKETING_VERSION \"$ZIP_PATH\" \"$DMG_PATH\" \"$APPCAST_PATH\""
echo "  scripts/release/publish.sh $MARKETING_VERSION"
