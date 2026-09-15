#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PROJECT_PBXPROJ="${PROJECT_PBXPROJ:-Ledger.xcodeproj/project.pbxproj}"
SHAREDUI_PATH="${SHAREDUI_PATH:-../SharedUI}"
REVISION_FILE="${REVISION_FILE:-Config/SharedUI.revision}"

REQUIRE_PIN_MATCH=0
if [[ "${1:-}" == "--require-pin-match" ]]; then
  REQUIRE_PIN_MATCH=1
fi

# The app has no SPM manifest of its own (LedgerCore is the only local package, and it has no
# SharedUI dependency at all) — SharedUI is wired directly into Ledger.xcodeproj as its own
# XCLocalSwiftPackageReference. That's what's checked here, not a Package.swift.
if [[ ! -f "$PROJECT_PBXPROJ" ]]; then
  echo "Missing $PROJECT_PBXPROJ"
  exit 1
fi

if grep -Eq 'repositoryURL = "https://github\.com/chrislemarquand/SharedUI(\.git)?"' "$PROJECT_PBXPROJ"; then
  echo "Error: remote SharedUI dependency detected in $PROJECT_PBXPROJ"
  echo "Local-only policy is active. Use a local XCLocalSwiftPackageReference (relativePath = ../SharedUI)."
  exit 1
fi

if ! grep -Eq 'XCLocalSwiftPackageReference "\.\./SharedUI"' "$PROJECT_PBXPROJ" \
  || ! grep -Eq 'relativePath = \.\./SharedUI;' "$PROJECT_PBXPROJ"; then
  echo "Error: SharedUI local package reference is missing in $PROJECT_PBXPROJ"
  echo "Expected an XCLocalSwiftPackageReference with relativePath = ../SharedUI"
  exit 1
fi

if [[ ! -d "$SHAREDUI_PATH" ]]; then
  echo "Error: SharedUI local path not found: $SHAREDUI_PATH"
  exit 1
fi

if [[ ! -f "$SHAREDUI_PATH/Package.swift" ]]; then
  echo "Error: SharedUI Package.swift missing at $SHAREDUI_PATH/Package.swift"
  exit 1
fi

# Revision-pin reporting. This is informational by default — an ordinary dev build must not
# fail just because ../SharedUI has moved on or has local edits, since that's the whole point
# of local lockstep development. Only --require-pin-match (used by release validation) turns
# a mismatch or a dirty tree into a hard failure.
sharedui_head="$(git -C "$SHAREDUI_PATH" rev-parse HEAD 2>/dev/null || true)"
sharedui_branch="$(git -C "$SHAREDUI_PATH" branch --show-current 2>/dev/null || true)"
sharedui_dirty=0
if [[ -n "$(git -C "$SHAREDUI_PATH" status --porcelain 2>/dev/null || true)" ]]; then
  sharedui_dirty=1
fi

recorded_revision=""
if [[ -f "$REVISION_FILE" ]]; then
  recorded_revision="$(tr -d '[:space:]' < "$REVISION_FILE")"
fi

pin_matches=0
if [[ -n "$recorded_revision" && -n "$sharedui_head" && "$sharedui_head" == "$recorded_revision" ]]; then
  pin_matches=1
fi

dirty_label="clean"
if [[ $sharedui_dirty -eq 1 ]]; then
  dirty_label="dirty"
fi
echo "SharedUI: branch '${sharedui_branch:-detached}', HEAD ${sharedui_head:-unknown} ($dirty_label)"

if [[ -n "$recorded_revision" ]]; then
  if [[ $pin_matches -eq 1 ]]; then
    echo "SharedUI revision matches $REVISION_FILE ($recorded_revision)."
  else
    echo "SharedUI revision does NOT match $REVISION_FILE."
    echo "  Recorded: $recorded_revision"
    echo "  Actual:   ${sharedui_head:-unknown}"
  fi
else
  echo "No recorded revision at $REVISION_FILE yet — nothing to compare against."
fi

if [[ $REQUIRE_PIN_MATCH -eq 1 ]]; then
  if [[ $sharedui_dirty -eq 1 ]]; then
    echo "Error: SharedUI has uncommitted changes; refusing to treat this as release-quality."
    exit 1
  fi
  if [[ $pin_matches -ne 1 ]]; then
    echo "Error: SharedUI does not match the recorded release revision."
    echo "Run scripts/deps/bump_sharedui.sh to deliberately accept a new one, or check out the recorded revision."
    exit 1
  fi
fi
