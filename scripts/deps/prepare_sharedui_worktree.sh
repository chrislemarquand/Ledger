#!/usr/bin/env bash
set -euo pipefail

# Provisions the SharedUI revision recorded in Config/SharedUI.revision into an isolated
# sibling checkout, for verifying a release builds from documented inputs alone — never by
# mutating the developer's own ../SharedUI checkout (which may be mid-feature-work on some
# other branch, as it commonly is).
#
# Usage: scripts/deps/prepare_sharedui_worktree.sh [<destination-path>]
# Default destination: ../SharedUI-release-<short-sha>, alongside the existing checkout.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

SHAREDUI_PATH="${SHAREDUI_PATH:-../SharedUI}"
REVISION_FILE="${REVISION_FILE:-Config/SharedUI.revision}"

if [[ ! -f "$REVISION_FILE" ]]; then
  echo "Error: no recorded revision at $REVISION_FILE. Run bump_sharedui.sh first."
  exit 1
fi
recorded_revision="$(tr -d '[:space:]' < "$REVISION_FILE")"
if [[ -z "$recorded_revision" ]]; then
  echo "Error: $REVISION_FILE is empty."
  exit 1
fi

if [[ ! -d "$SHAREDUI_PATH/.git" ]]; then
  echo "Error: $SHAREDUI_PATH is not a git checkout — cannot create a worktree from it."
  exit 1
fi

destination="${1:-../SharedUI-release-${recorded_revision:0:7}}"

if [[ -e "$destination" ]]; then
  echo "Error: $destination already exists."
  echo "Remove it first if it's stale, or pass a different destination path."
  exit 1
fi

if ! git -C "$SHAREDUI_PATH" cat-file -e "${recorded_revision}^{commit}" 2>/dev/null; then
  echo "Error: recorded revision $recorded_revision is not present in $SHAREDUI_PATH."
  echo "Fetch it first (git -C \"$SHAREDUI_PATH\" fetch), then retry."
  exit 1
fi

echo "Creating an isolated SharedUI worktree at $destination, at $recorded_revision"
git -C "$SHAREDUI_PATH" worktree add --detach "$(cd "$(dirname "$destination")" && pwd)/$(basename "$destination")" "$recorded_revision"

echo
echo "Done. This checkout is isolated from $SHAREDUI_PATH and cannot be affected by any"
echo "branch switch, stash, or edit happening there. Remove it when finished:"
echo "  git -C \"$SHAREDUI_PATH\" worktree remove \"$destination\""
