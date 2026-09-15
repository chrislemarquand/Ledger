#!/usr/bin/env bash
set -euo pipefail

# Freezes the identity of a release candidate into a local, git-ignored JSON manifest, so a
# candidate has one fixed identity from the moment it's prepared through however many times its
# preparation is retried, rather than each step recomputing values independently. Consumed by the
# release pipeline (scripts/release/release.sh and friends) — this script only writes the record.
#
# This does NOT decide the build number or check it against the published feed. That check needs
# the Sparkle feed's current state, which belongs in the release pipeline's own preflight step,
# not here — this script just records whatever RELEASE_BUILD_NUMBER the caller already decided on
# (or a wall-clock placeholder if run standalone/for inspection).
#
# Usage: scripts/release/write_candidate_manifest.sh [<output-path>]
# Reads: MARKETING_VERSION (from Config/Base.xcconfig), RELEASE_BUILD_NUMBER (env, optional),
#        the current Ledger commit, and Config/SharedUI.revision.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_PATH="${1:-build/release-candidate.json}"
mkdir -p "$(dirname "$OUTPUT_PATH")"

MARKETING_VERSION="$(grep -m1 '^MARKETING_VERSION' Config/Base.xcconfig | sed -E 's/^MARKETING_VERSION = //')"
BUILD_NUMBER="${RELEASE_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
LEDGER_COMMIT="$(git rev-parse HEAD)"
LEDGER_BRANCH="$(git branch --show-current || echo "detached")"
LEDGER_DIRTY="false"
if [[ -n "$(git status --porcelain)" ]]; then
  LEDGER_DIRTY="true"
fi

SHAREDUI_REVISION=""
if [[ -f Config/SharedUI.revision ]]; then
  SHAREDUI_REVISION="$(tr -d '[:space:]' < Config/SharedUI.revision)"
fi

XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ' | sed -E 's/ +$//')"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$OUTPUT_PATH" <<EOF
{
  "generatedAt": "${GENERATED_AT}",
  "marketingVersion": "${MARKETING_VERSION}",
  "buildNumber": "${BUILD_NUMBER}",
  "ledger": {
    "commit": "${LEDGER_COMMIT}",
    "branch": "${LEDGER_BRANCH}",
    "dirty": ${LEDGER_DIRTY}
  },
  "sharedUIRevision": "${SHAREDUI_REVISION}",
  "toolchain": "${XCODE_VERSION}"
}
EOF

echo "Wrote candidate manifest: $OUTPUT_PATH"
cat "$OUTPUT_PATH"
