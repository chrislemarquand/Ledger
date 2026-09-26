#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

SHAREDUI_PATH="${SHAREDUI_PATH:-../SharedUI}"
REVISION_FILE="${REVISION_FILE:-Config/SharedUI.revision}"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [<git-ref>]"
  echo
  echo "Deliberately records a new accepted SharedUI revision in $REVISION_FILE."
  echo "With no argument: records SharedUI's current HEAD at $SHAREDUI_PATH."
  echo "With an argument: resolves that ref (branch, tag, or SHA) via git rev-parse and records it."
  echo
  echo "SharedUI must be clean (no uncommitted changes) — this never pins a dirty state."
  echo "This does not check out anything; it only records intent. Use it after you've"
  echo "already verified the target revision locally."
  exit 1
fi

"$ROOT_DIR/scripts/deps/verify_shared_ui_pin.sh"

if [[ -n "$(git -C "$SHAREDUI_PATH" status --porcelain 2>/dev/null || true)" ]]; then
  echo "Error: SharedUI has uncommitted changes at $SHAREDUI_PATH."
  echo "Refusing to pin a revision that isn't fully committed — commit or stash first."
  exit 1
fi

if [[ $# -eq 1 ]]; then
  new_revision="$(git -C "$SHAREDUI_PATH" rev-parse "$1")"
else
  new_revision="$(git -C "$SHAREDUI_PATH" rev-parse HEAD)"
fi

echo "$new_revision" > "$REVISION_FILE"

echo "Resolving local package dependencies against the newly recorded revision"
swift package resolve

"$ROOT_DIR/scripts/deps/verify_shared_ui_pin.sh"

echo
echo "Done. $REVISION_FILE now records $new_revision."
echo "This is a deliberate acceptance — review and commit $REVISION_FILE."
