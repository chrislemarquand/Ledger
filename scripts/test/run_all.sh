#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# In this environment, serial `swift test` can intermittently stall after build
# with no output. Parallel mode runs the same suite reliably.
exec swift test --parallel "$@"
