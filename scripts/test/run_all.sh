#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# LedgerCore is the only local Swift package left in this repo — the app (target `Ledger`) and
# its tests (target `LedgerTests`) are Xcode-native only, with no SPM manifest of their own.
# `swift test` therefore only ever covers LedgerCore; run `xcodebuild test` (see
# docs/RELEASE_CHECKLIST.md / -skip-testing:LedgerUITests) for the app-side test targets.
#
# In this environment, serial `swift test` can intermittently stall after build with no output.
# Parallel mode runs the same suite reliably.
cd "$ROOT_DIR/LedgerCore"
exec swift test --parallel "$@"
