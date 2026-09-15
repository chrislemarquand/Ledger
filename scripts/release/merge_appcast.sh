#!/usr/bin/env bash
set -euo pipefail

# Runs Sparkle's own generate_appcast (correct signing, correct <item> shape) against just the
# new release's zip, then splices that one new <item> into the CURRENTLY PUBLISHED feed rather
# than replacing the whole feed with a single-item one. Sparkle's generate_appcast is designed to
# rebuild a feed from a directory containing every release's archive; pointing it at a directory
# holding only the newest zip (which is what this repo's release process actually has locally —
# past archives live only as GitHub release assets, not on this disk) silently drops every
# earlier <item>, which is exactly what the audit flagged as unacceptable: an update feed must
# not stop offering a still-supported earlier version just because building the newest one didn't
# happen to have the old binaries lying around locally.
#
# Usage: scripts/release/merge_appcast.sh <path-to-final-zip>
# Reads: LIVE_APPCAST_URL (env, defaults to the real published feed) for the "before" state.
# Writes: $APPCAST_OUTPUT_DIR/appcast.xml (default build/appcast/appcast.xml) — the merged feed.

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <path-to-final-zip>" >&2
  exit 1
fi

ZIP_PATH="$1"
[[ -f "$ZIP_PATH" ]] || { echo "error: not found: $ZIP_PATH" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPCAST_OUTPUT_DIR="${APPCAST_OUTPUT_DIR:-$ROOT_DIR/build/appcast}"
LIVE_APPCAST_URL="${LIVE_APPCAST_URL:-https://chrislemarquand.github.io/Ledger/appcast.xml}"
mkdir -p "$APPCAST_OUTPUT_DIR"

# Step 1: generate a single-item feed for just the new release, using Sparkle's own tool —
# reuses generate_appcast.sh unchanged so signing/URL-prefix logic isn't duplicated here.
NEW_ITEM_FEED="$APPCAST_OUTPUT_DIR/new-item-only.xml"
GENERATED="$("$ROOT_DIR/scripts/release/generate_appcast.sh" "$ZIP_PATH")"
cp "$GENERATED" "$NEW_ITEM_FEED"

# Step 2: fetch the currently-published feed. If it's unreachable (first-ever release, or the
# feed is temporarily down), fall back to treating this as the only item rather than failing —
# but say so loudly, since silently dropping history is the exact bug being fixed here.
LIVE_FEED="$APPCAST_OUTPUT_DIR/live-before-merge.xml"
if curl -fsSL -o "$LIVE_FEED" "$LIVE_APPCAST_URL" 2>/dev/null; then
  echo "Fetched current live feed from $LIVE_APPCAST_URL for merging."
else
  echo "warning: could not fetch $LIVE_APPCAST_URL — treating this as the first release (no history to preserve)." >&2
  rm -f "$LIVE_FEED"
fi

MERGED_OUTPUT="$APPCAST_OUTPUT_DIR/appcast.xml"

python3 - "$NEW_ITEM_FEED" "$LIVE_FEED" "$MERGED_OUTPUT" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

new_item_path, live_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
for prefix, uri in ns.items():
    ET.register_namespace(prefix, uri)

new_tree = ET.parse(new_item_path)
new_channel = new_tree.getroot().find("channel")
new_items = new_channel.findall("item")
if not new_items:
    print("error: generate_appcast produced no <item> for the new release", file=sys.stderr)
    sys.exit(1)
new_version = new_items[0].findtext("sparkle:version", namespaces=ns)

import os
if os.path.exists(live_path):
    live_tree = ET.parse(live_path)
    root = live_tree.getroot()
    channel = root.find("channel")
    existing_items = channel.findall("item")
else:
    root = new_tree.getroot()
    channel = new_channel
    existing_items = []

# Refuse to reuse a version's slot with different bytes: if an item with the same
# sparkle:version already exists, its enclosure must match exactly (same URL/length/signature),
# not be silently replaced with different content.
for existing in existing_items:
    existing_version = existing.findtext("sparkle:version", namespaces=ns)
    if existing_version == new_version:
        old_enc = existing.find("enclosure")
        new_enc = new_items[0].find("enclosure")
        if (old_enc.get("url"), old_enc.get("length")) != (new_enc.get("url"), new_enc.get("length")):
            print(f"error: version {new_version} already exists in the live feed with different "
                  f"enclosure (url/length) — refusing to overwrite. Bump the version to release "
                  f"different bytes.", file=sys.stderr)
            sys.exit(1)
        print(f"Version {new_version} already present in the live feed with matching enclosure — "
              f"nothing to merge, output is the live feed unchanged.")
        live_tree.write(out_path, encoding="UTF-8", xml_declaration=True)
        sys.exit(0)

if channel is not new_channel:
    # Prepend the new item, keep every existing item (this is the actual fix: history survives).
    # Find insertion index: after any leading non-item elements (title, link, description...).
    children = list(channel)
    insert_at = 0
    for i, child in enumerate(children):
        if child.tag == "item":
            insert_at = i
            break
    else:
        insert_at = len(children)
    channel.insert(insert_at, new_items[0])
    live_tree.write(out_path, encoding="UTF-8", xml_declaration=True)
else:
    new_tree.write(out_path, encoding="UTF-8", xml_declaration=True)

print(f"Merged feed written to {out_path}: {1 + len(existing_items) if channel is not new_channel and existing_items else len(new_items)} total item(s) "
      f"({len(existing_items)} preserved from the live feed + this release).")
PYEOF

echo "$MERGED_OUTPUT"
