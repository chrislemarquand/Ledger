#!/usr/bin/env bash
set -euo pipefail

# Submits $1 for notarization and, once Accepted, staples the result onto $2 (or onto $1 itself
# if $2 is omitted). These are deliberately separable: stapler cannot staple a .zip at all, so
# submitting a .app's zip for notarization and then stapling that same .app path is the normal
# two-argument case — see release.sh, which relies on exactly this to fix a real bug (a
# previous version of this script notarized the .app's zip and then skipped stapling entirely
# for zips, so the .app inside the shipped archive was never actually stapled).
#
# Usage: notarize.sh <submission-artifact> [<staple-target>]

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <submission-artifact> [<staple-target>]" >&2
  exit 1
fi

ARTIFACT="$1"
STAPLE_TARGET="${2:-$1}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile name.}"

SUBMIT_OUTPUT="$(xcrun notarytool submit "$ARTIFACT" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
echo "$SUBMIT_OUTPUT" >&2

# Extract submission ID for log retrieval on failure.
SUBMISSION_ID="$(echo "$SUBMIT_OUTPUT" | awk '/id:/{print $2; exit}')"

# notarytool exits 0 even when status is Invalid — check explicitly.
if echo "$SUBMIT_OUTPUT" | grep -q "status: Invalid"; then
  echo "Notarization FAILED for $ARTIFACT (status: Invalid)" >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    echo "Fetching notarization log for submission $SUBMISSION_ID..." >&2
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fi
  exit 1
fi
if ! echo "$SUBMIT_OUTPUT" | grep -q "status: Accepted"; then
  echo "Notarization for $ARTIFACT did not report Accepted; refusing to staple. See output above." >&2
  exit 1
fi

# Stapler only works with .app, .pkg, and .dmg — never call it on a .zip (submission artifacts
# are frequently zips; the staple target should never be one — the caller is responsible for
# passing something stapler actually supports).
if [[ "$STAPLE_TARGET" == *.zip ]]; then
  echo "error: refusing to staple a .zip ($STAPLE_TARGET) — stapler only supports .app/.pkg/.dmg." >&2
  exit 1
fi
xcrun stapler staple "$STAPLE_TARGET"
xcrun stapler validate "$STAPLE_TARGET"
