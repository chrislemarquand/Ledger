#!/usr/bin/env bash
set -euo pipefail

# Creates or reuses a DRAFT GitHub release tied to the exact release commit and uploads the
# finished artifacts to it. A draft is invisible to the public — this is "prepare", not
# "publish". Never uses --clobber: an asset that already exists with different content is a
# hard error, never silently replaced. Never flips the release public — that's publish.sh.
#
# Usage: scripts/release/stage_github_release.sh <marketing-version> <zip-path> <dmg-path> <appcast-path>
# Reads: GITHUB_REPOSITORY (env, defaults to chrislemarquand/Ledger), CHANGELOG.md for notes.

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <marketing-version> <zip-path> <dmg-path> <appcast-path>" >&2
  exit 1
fi

MARKETING_VERSION="$1"
ZIP_PATH="$2"
DMG_PATH="$3"
APPCAST_PATH="$4"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GITHUB_REPO="${GITHUB_REPOSITORY:-chrislemarquand/Ledger}"
TAG="v${MARKETING_VERSION}"

for p in "$ZIP_PATH" "$DMG_PATH" "$APPCAST_PATH"; do
  [[ -f "$p" ]] || { echo "error: missing artifact: $p" >&2; exit 1; }
done

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found." >&2
  exit 1
fi

# Extract release notes from CHANGELOG.md. Missing notes are an error, not a placeholder
# published to users — a real release always has a real note.
NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT
awk -v ver="$MARKETING_VERSION" '
  /^## \[/ {
    if (found) exit
    if ($0 == "## [" ver "]" || index($0, "## [" ver "] ") == 1) { found=1; next }
    next
  }
  found && /^---$/ { exit }
  found { print }
' "$ROOT_DIR/CHANGELOG.md" | sed -e '/./,$!d' > "$NOTES_FILE"

if [[ ! -s "$NOTES_FILE" ]]; then
  echo "error: no CHANGELOG.md section found for [$MARKETING_VERSION]. Add release notes before staging." >&2
  exit 1
fi

if gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
  IS_DRAFT="$(gh release view "$TAG" --repo "$GITHUB_REPO" --json isDraft --jq '.isDraft')"
  if [[ "$IS_DRAFT" != "true" ]]; then
    echo "error: $TAG is already published (not a draft) on $GITHUB_REPO. Refusing to touch it." >&2
    exit 1
  fi
  echo "Reusing existing draft $TAG."
  TARGET_COMMIT="$(gh release view "$TAG" --repo "$GITHUB_REPO" --json targetCommitish --jq '.targetCommitish')"
  CURRENT_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  if [[ "$TARGET_COMMIT" != "$CURRENT_COMMIT" ]]; then
    echo "error: existing draft $TAG targets $TARGET_COMMIT, not the current commit $CURRENT_COMMIT." >&2
    exit 1
  fi
else
  echo "Creating draft $TAG."
  gh release create "$TAG" \
    --repo "$GITHUB_REPO" \
    --target "$(git -C "$ROOT_DIR" rev-parse HEAD)" \
    --title "$TAG" \
    --notes-file "$NOTES_FILE" \
    --draft
fi

# Check each asset individually: uploading is safe to retry, but an asset that already exists
# with the WRONG bytes must be a hard stop, never silently clobbered.
upload_or_verify() {
  local file_path="$1"
  local asset_name
  asset_name="$(basename "$file_path")"
  local local_sha
  local_sha="$(shasum -a 256 "$file_path" | awk '{print $1}')"

  local existing_url
  existing_url="$(gh release view "$TAG" --repo "$GITHUB_REPO" --json assets --jq ".assets[] | select(.name==\"$asset_name\") | .url" || true)"

  if [[ -n "$existing_url" ]]; then
    local remote_sha
    remote_sha="$(curl -fsSL "$existing_url" | shasum -a 256 | awk '{print $1}')"
    if [[ "$remote_sha" != "$local_sha" ]]; then
      echo "error: $asset_name already exists on $TAG with different content (remote sha256=$remote_sha, local=$local_sha)." >&2
      echo "Refusing to overwrite — never uses --clobber. Delete the asset manually if this is deliberate." >&2
      exit 1
    fi
    echo "  $asset_name: already uploaded, hash matches — nothing to do."
  else
    echo "  $asset_name: uploading..."
    gh release upload "$TAG" "$file_path" --repo "$GITHUB_REPO"
  fi
}

echo "Staging assets on draft $TAG:"
upload_or_verify "$ZIP_PATH"
upload_or_verify "$DMG_PATH"
upload_or_verify "$APPCAST_PATH"

echo
echo "Draft $TAG staged: https://github.com/$GITHUB_REPO/releases/tag/$TAG (not public)"
echo "Review it, then run scripts/release/publish.sh $MARKETING_VERSION to make it public."
