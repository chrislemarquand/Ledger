#!/usr/bin/env bash
set -euo pipefail

# Inspects an already-signed .app's actual signature, entitlements, and Hardened Runtime —
# rather than just trusting that codesign exited 0 during archive.sh. Never signs anything
# itself.
#
# Usage: scripts/release/verify_signature.sh <path-to-app>

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <path-to-app>" >&2
  exit 1
fi

APP_PATH="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$ROOT_DIR/Config/Ledger.entitlements}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: not a directory: $APP_PATH" >&2
  exit 1
fi

echo "Verifying signature validity (deep, strict)..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

DISPLAY_OUTPUT="$(codesign -dvv "$APP_PATH" 2>&1)"
echo "$DISPLAY_OUTPUT"

echo "Checking signing identity is Developer ID, not ad hoc..."
if echo "$DISPLAY_OUTPUT" | grep -q "^Authority=.*Developer ID Application"; then
  : # ok
else
  echo "error: signing authority is not a Developer ID Application certificate." >&2
  echo "$DISPLAY_OUTPUT" | grep "^Authority=" >&2 || echo "(no Authority= line found — likely ad hoc)" >&2
  exit 1
fi

echo "Checking Hardened Runtime is enabled..."
# The flags appear inline in the CodeDirectory line (e.g. "flags=0x10000(runtime)"), not on a
# separate "Flags=" line — verified directly against real codesign -dvv output, not assumed.
FLAGS_LINE="$(echo "$DISPLAY_OUTPUT" | grep -o 'flags=0x[0-9a-f]*([^)]*)' || true)"
if [[ "$FLAGS_LINE" != *"runtime"* ]]; then
  echo "error: Hardened Runtime not enabled. $FLAGS_LINE" >&2
  exit 1
fi
if [[ "$FLAGS_LINE" == *"adhoc"* ]]; then
  echo "error: signature is ad hoc. $FLAGS_LINE" >&2
  exit 1
fi

echo "Checking for a secure signing timestamp (required for notarization)..."
if ! echo "$DISPLAY_OUTPUT" | grep -q "^Timestamp="; then
  echo "error: no Timestamp= in signature — notarization will reject an unsigned-timestamp binary." >&2
  exit 1
fi

echo "Checking entitlements match $ENTITLEMENTS_PATH..."
if [[ -f "$ENTITLEMENTS_PATH" ]]; then
  ACTUAL_ENTITLEMENTS_PLIST="$(mktemp)"
  codesign -d --entitlements "$ACTUAL_ENTITLEMENTS_PLIST" --xml "$APP_PATH" 2>/dev/null

  # Compare via plistlib (real plist parsing, not regex over PlistBuddy's print format — a
  # first version of this check used a regex that silently truncated any key containing a
  # hyphen, e.g. com.apple.security.app-sandbox, producing a false "missing" failure).
  if ! python3 - "$ENTITLEMENTS_PATH" "$ACTUAL_ENTITLEMENTS_PLIST" <<'PYEOF'
import plistlib, sys
declared = plistlib.load(open(sys.argv[1], "rb"))
actual = plistlib.load(open(sys.argv[2], "rb"))
missing = [k for k in declared if k not in actual]
if missing:
    for k in missing:
        print(f"error: entitlement key '{k}' declared but missing from the signed app.", file=sys.stderr)
    sys.exit(1)
PYEOF
  then
    rm -f "$ACTUAL_ENTITLEMENTS_PLIST"
    exit 1
  fi
  rm -f "$ACTUAL_ENTITLEMENTS_PLIST"
else
  echo "  warning: $ENTITLEMENTS_PATH not found — skipping entitlement comparison." >&2
fi

echo "Checking nested Mach-O binaries, XPC services, frameworks, and nested apps are all signed..."
while IFS= read -r f; do
  if ! codesign --verify --strict "$f" 2>/dev/null; then
    echo "error: nested binary not validly signed: $f" >&2
    exit 1
  fi
done < <(find "$APP_PATH" -type f -not -path "*/MacOS/*" -exec sh -c '/usr/bin/file "$1" 2>/dev/null | grep -q "Mach-O" && echo "$1"' _ {} \;)

echo "Signature verification passed."
