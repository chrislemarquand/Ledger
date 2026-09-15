#!/usr/bin/env bash
set -euo pipefail

# Preflight: everything that must be true before a release candidate is built, checked once,
# up front, so a failure here never wastes a signing/notarization cycle discovering it late.
# This script only reads and validates — it never signs, notarizes, uploads, or publishes
# anything, and it never modifies SharedUI or any other checkout.
#
# Usage: scripts/release/preflight.sh
# Exits non-zero on the first failed check, with a clear reason.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

SHAREDUI_PATH="${SHAREDUI_PATH:-../SharedUI}"
GITHUB_REPO="${GITHUB_REPOSITORY:-chrislemarquand/Ledger}"

fail() {
  echo "Preflight FAILED: $1" >&2
  exit 1
}

pass() {
  echo "  ok: $1"
}

echo "[1/7] Ledger repo state"
if [[ -n "$(git status --porcelain)" ]]; then
  fail "Ledger working tree is not clean. Commit or stash before preparing a release."
fi
LEDGER_COMMIT="$(git rev-parse HEAD)"
pass "clean at $LEDGER_COMMIT"

echo "[2/7] SharedUI revision pin"
if ! "$ROOT_DIR/scripts/deps/verify_shared_ui_pin.sh" --require-pin-match; then
  fail "SharedUI does not match the recorded release pin, or is dirty. See output above."
fi
pass "SharedUI matches Config/SharedUI.revision, clean"

echo "[3/7] Version / tag relationship"
MARKETING_VERSION="$(grep -m1 '^MARKETING_VERSION' Config/Base.xcconfig | sed -E 's/^MARKETING_VERSION = //')"
if [[ -z "$MARKETING_VERSION" ]]; then
  fail "Could not read MARKETING_VERSION from Config/Base.xcconfig."
fi
GIT_TAG="v${MARKETING_VERSION}"
if git rev-parse -q --verify "refs/tags/${GIT_TAG}" >/dev/null 2>&1; then
  TAG_COMMIT="$(git rev-parse "refs/tags/${GIT_TAG}")"
  if [[ "$TAG_COMMIT" != "$LEDGER_COMMIT" ]]; then
    fail "Tag ${GIT_TAG} already exists but points at ${TAG_COMMIT}, not the current commit ${LEDGER_COMMIT}."
  fi
  pass "tag ${GIT_TAG} exists and matches HEAD"
else
  pass "tag ${GIT_TAG} does not exist yet (will be created at publish time)"
fi

echo "[4/7] Not already published"
if command -v gh >/dev/null 2>&1; then
  if gh release view "$GIT_TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    RELEASE_STATE="$(gh release view "$GIT_TAG" --repo "$GITHUB_REPO" --json isDraft --jq '.isDraft')"
    if [[ "$RELEASE_STATE" == "false" ]]; then
      fail "${GIT_TAG} is already published as a public release on ${GITHUB_REPO}. Bump MARKETING_VERSION to release again."
    fi
    pass "${GIT_TAG} exists on ${GITHUB_REPO} but only as a draft — safe to continue preparing"
  else
    pass "${GIT_TAG} not present on ${GITHUB_REPO}"
  fi
else
  echo "  warning: gh CLI not found — cannot check for an already-published release. Check manually." >&2
fi

echo "[5/7] ExifTool payload"
REQUIRED_VERSION="$(grep -m1 '^EXIFTOOL_REQUIRED_VERSION' Config/Base.xcconfig | sed -E 's/^EXIFTOOL_REQUIRED_VERSION = //')"
FOUND_EXIFTOOL=""
for candidate in "${EXIFTOOL_SOURCE_PATH:-}" "Vendor/exiftool/bin/exiftool" "Vendor/exiftool/exiftool" "/opt/homebrew/bin/exiftool" "/usr/local/bin/exiftool"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    FOUND_EXIFTOOL="$candidate"
    break
  fi
done
if [[ -z "$FOUND_EXIFTOOL" ]]; then
  fail "No exiftool binary found (checked EXIFTOOL_SOURCE_PATH, Vendor/exiftool, Homebrew paths)."
fi
pass "found at $FOUND_EXIFTOOL (version check happens for real during archive.sh)"

echo "[6/7] Signing credentials (presence only — never reads secret material)"
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Team ID.}"
: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your Developer ID Application identity.}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEVELOPER_ID_APPLICATION"; then
  fail "Identity \"$DEVELOPER_ID_APPLICATION\" not found in the local keychain (security find-identity -v -p codesigning)."
fi
pass "DEVELOPMENT_TEAM and DEVELOPER_ID_APPLICATION set, identity present in keychain"

echo "[7/7] Notarization profile (presence only)"
NOTARY_PROFILE="${NOTARY_PROFILE:-EXIFEDIT_NOTARY}"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  fail "Notarization profile \"$NOTARY_PROFILE\" is not configured in this Mac's keychain. Run: xcrun notarytool store-credentials $NOTARY_PROFILE"
fi
pass "notarization profile \"$NOTARY_PROFILE\" is configured"

echo
echo "Preflight passed. Candidate: ${MARKETING_VERSION} @ ${LEDGER_COMMIT}"
