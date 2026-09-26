#!/usr/bin/env bash
set -euo pipefail

# The one step in this whole pipeline that makes anything public. Everything before this
# (archive, notarize, stage) is reversible or already-private; this is not. Flips the staged
# draft public, verifies the assets are actually downloadable, then deploys the Sparkle feed
# LAST — so an update never gets advertised before the bytes it points to are live.
#
# This script does not build, sign, or notarize anything — it only publishes what
# stage_github_release.sh already staged and validate_artifacts.sh already checked.
#
# Usage: scripts/release/publish.sh <marketing-version>

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <marketing-version>" >&2
  exit 1
fi

MARKETING_VERSION="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GITHUB_REPO="${GITHUB_REPOSITORY:-chrislemarquand/Ledger}"
TAG="v${MARKETING_VERSION}"

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found." >&2
  exit 1
fi

echo "[1/5] Re-checking remote state immediately before publishing (race guard)"
if ! gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
  echo "error: no draft $TAG found on $GITHUB_REPO. Run stage_github_release.sh first." >&2
  exit 1
fi
IS_DRAFT="$(gh release view "$TAG" --repo "$GITHUB_REPO" --json isDraft --jq '.isDraft')"
if [[ "$IS_DRAFT" != "true" ]]; then
  echo "$TAG is already published (not a draft). Nothing to do — refusing to re-publish or re-touch it."
  exit 0
fi
ASSET_COUNT="$(gh release view "$TAG" --repo "$GITHUB_REPO" --json assets --jq '.assets | length')"
if [[ "$ASSET_COUNT" -lt 3 ]]; then
  echo "error: draft $TAG has only $ASSET_COUNT asset(s); expected at least 3 (zip, dmg, appcast). Refusing to publish an incomplete draft." >&2
  exit 1
fi

echo "[2/5] Publishing draft $TAG"
gh release edit "$TAG" --repo "$GITHUB_REPO" --draft=false

echo "[3/5] Verifying assets are actually downloadable"
ASSET_URLS="$(gh release view "$TAG" --repo "$GITHUB_REPO" --json assets --jq '.assets[].url')"
while IFS= read -r url; do
  [[ -z "$url" ]] && continue
  STATUS="$(curl -fsSL -o /dev/null -w '%{http_code}' "$url")"
  if [[ "$STATUS" != "200" ]]; then
    echo "error: asset not downloadable (HTTP $STATUS): $url" >&2
    echo "The release is now public with a broken asset — investigate immediately." >&2
    exit 1
  fi
done <<< "$ASSET_URLS"
echo "  all assets return HTTP 200"

echo "[4/5] Deploying the Sparkle feed (last, deliberately, after assets are confirmed live)"
if ! gh workflow run "deploy-appcast.yml" --repo "$GITHUB_REPO" -f tag="$TAG"; then
  echo "error: failed to trigger the appcast deploy workflow. Assets are public but the feed is" >&2
  echo "NOT yet updated — the previous version's feed entry is still being served, which is safe" >&2
  echo "but stale. Retry: gh workflow run deploy-appcast.yml --repo $GITHUB_REPO -f tag=$TAG" >&2
  exit 1
fi
echo "  triggered deploy-appcast.yml for $TAG — this only deploys the already-generated feed" >&2
echo "  asset from the release, it does not build/sign/notarize anything." >&2

echo "[5/5] Done"
echo "Published: https://github.com/$GITHUB_REPO/releases/tag/$TAG"
echo "Feed deploy is running asynchronously — check: gh run list --repo $GITHUB_REPO --workflow=deploy-appcast.yml"
echo "Validate the served feed once deployed: curl -fsSL https://chrislemarquand.github.io/Ledger/appcast.xml"
