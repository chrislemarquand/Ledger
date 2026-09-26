#!/bin/sh
set -euo pipefail

# Single source of truth for CFBundleVersion. Runs on every build (Debug, Release,
# archive, CI) and overwrites whatever CURRENT_PROJECT_VERSION resolved to in the
# built Info.plist, so the build number is always auto-generated and never manually
# bumped or computed twice in different places. It is intentionally independent of
# MARKETING_VERSION — bump that by hand when you want a release; this just needs to
# be unique and increasing across ordinary builds in between.
#
# Ordinary local/CI builds: wall-clock, as before — cheap, no network, never touches tracked
# source (only this build's own processed Info.plist output).
#
# Release candidates: the release pipeline (scripts/release/) is expected to set
# RELEASE_BUILD_NUMBER once per candidate and pass it in as an explicit input, so a candidate's
# identity is frozen rather than recomputed from wall-clock on every invocation, and so it can be
# checked monotonic against the already-published Sparkle feed *before* this script ever runs —
# that check belongs in the release pipeline's preflight step, which has the feed data to check
# against; it doesn't belong here, where a plain rebuild has no such context.
INFOPLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
BUILD_NUMBER="${RELEASE_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
CURRENT_YEAR="$(date -u +%Y)"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${INFOPLIST}"

# NSHumanReadableCopyright used to embed a $(CURRENT_YEAR) Xcode build-setting token that was
# never actually defined anywhere, so it substituted to nothing and the built copyright string
# was silently broken. Xcode's Info.plist processing has no date-substitution mechanism of its
# own, so — same pattern as CFBundleVersion above — the real value is computed and written here,
# once per build, rather than relying on a build setting that doesn't exist.
/usr/libexec/PlistBuddy -c "Set :NSHumanReadableCopyright Copyright © ${CURRENT_YEAR} Chris Le Marquand" "${INFOPLIST}"
