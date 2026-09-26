#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# Resolves and builds against whatever SharedUI revision is currently checked out at
# ../SharedUI. This is a read-only check against your local checkout — it does NOT write
# Config/SharedUI.revision and never accepts a new revision on your behalf. Use
# bump_sharedui.sh to deliberately record a new one after you've verified it locally.
"$ROOT_DIR/scripts/deps/verify_shared_ui_pin.sh"

echo "Resolving local package dependencies"
swift package resolve

echo "Building against the resolved local SharedUI checkout"
swift build

echo "Done. This did not change Config/SharedUI.revision."
