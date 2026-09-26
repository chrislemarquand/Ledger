#!/usr/bin/env bash
set -euo pipefail

# Generates the >=1,000-file browse corpus required by
# docs/v1.4-performance-audit-plan.md's evidence policy. Never modifies or
# deletes anything in the source folders — read-only copies only. See
# docs/v1.4-progress.md and the feedback_ledger_test_data_safety memory:
# real photo libraries (anything under ~/Pictures) are never touched, and
# these specific source folders were explicitly named by the user as safe to
# copy from.
#
# Usage: scripts/performance/generate_browse_corpus.sh [--force]
#   --force   Delete and regenerate an existing corpus directory.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORPUS_DIR="$ROOT_DIR/scripts/performance/corpus/browse"

JPEG_SOURCE_DIRS=(
  "/Users/chrislemarquand/Downloads/Ledger Import Test Large"
  "/Users/chrislemarquand/Downloads/Ledger v1.3 Smoke Test/Gallery Browse"
  "/Users/chrislemarquand/Downloads/Ledger v1.3 Smoke Test/Unknown Focal Length"
  "/Users/chrislemarquand/Downloads/Ledger v1.3 Smoke Test/Metadata Copy Paste"
)
TIFF_SOURCE_DIR="/Users/chrislemarquand/Downloads/Ledger Import Test Large"
RAW_SOURCE_DIR="/Users/chrislemarquand/Library/Mobile Documents/com~apple~CloudDocs/Pictures/Capture - iCloud Drive/Home"

JPG_TARGET_COUNT=900
RAW_CR2_COUNT=80
RAW_JPG_COUNT=20

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

if [[ -d "$CORPUS_DIR" ]]; then
  if [[ "$FORCE" -eq 1 ]]; then
    rm -rf "$CORPUS_DIR"
  else
    echo "error: $CORPUS_DIR already exists. Pass --force to regenerate." >&2
    exit 1
  fi
fi
mkdir -p "$CORPUS_DIR"

echo "==> Collecting JPEG sources"
jpeg_sources=()
for dir in "${JPEG_SOURCE_DIRS[@]}"; do
  while IFS= read -r -d '' f; do
    jpeg_sources+=("$f")
  done < <(find "$dir" -maxdepth 1 -iname '*.jpg' -print0 2>/dev/null)
done
jpeg_source_count="${#jpeg_sources[@]}"
if [[ "$jpeg_source_count" -eq 0 ]]; then
  echo "error: no JPEG sources found" >&2
  exit 1
fi
echo "    $jpeg_source_count unique JPEG sources"

echo "==> Duplicating JPEGs to $JPG_TARGET_COUNT files"
i=0
while [[ "$i" -lt "$JPG_TARGET_COUNT" ]]; do
  src="${jpeg_sources[$((i % jpeg_source_count))]}"
  base="$(basename "$src" .jpg)"
  # A running global index guarantees a unique destination name even when
  # two source folders share a basename (e.g. IMG_0029.jpg appears in both
  # "Ledger Import Test Large" and "Metadata Copy Paste") — using only
  # source-relative dup counters there would silently collide and overwrite.
  dest="$CORPUS_DIR/corpus_$(printf '%04d' "$i")_${base}.jpg"
  cp "$src" "$dest"
  i=$((i + 1))
done
echo "    wrote $i JPEG files"

echo "==> Copying original TIFFs (not duplicated — ~180MB each)"
tiff_count=0
while IFS= read -r -d '' f; do
  cp "$f" "$CORPUS_DIR/$(basename "$f")"
  tiff_count=$((tiff_count + 1))
done < <(find "$TIFF_SOURCE_DIR" -maxdepth 1 -iname '*.tif' -print0 2>/dev/null)
echo "    wrote $tiff_count TIFF files"

echo "==> Copying $RAW_CR2_COUNT CR2 + $RAW_JPG_COUNT JPG files from the RAW source"
raw_cr2_count=0
while IFS= read -r -d '' f; do
  if [[ "$raw_cr2_count" -ge "$RAW_CR2_COUNT" ]]; then break; fi
  cp "$f" "$CORPUS_DIR/$(basename "$f")"
  raw_cr2_count=$((raw_cr2_count + 1))
done < <(find "$RAW_SOURCE_DIR" -maxdepth 1 -iname '*.CR2' -print0 2>/dev/null)

raw_jpg_count=0
while IFS= read -r -d '' f; do
  if [[ "$raw_jpg_count" -ge "$RAW_JPG_COUNT" ]]; then break; fi
  cp "$f" "$CORPUS_DIR/$(basename "$f")"
  raw_jpg_count=$((raw_jpg_count + 1))
done < <(find "$RAW_SOURCE_DIR" -maxdepth 1 -iname '*.JPG' -print0 2>/dev/null)
echo "    wrote $raw_cr2_count CR2 + $raw_jpg_count JPG files"

total=$(find "$CORPUS_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')
size=$(du -sh "$CORPUS_DIR" | cut -f1)
echo ""
echo "==> Corpus generated: $total files, $size at $CORPUS_DIR"
if [[ "$total" -lt 1000 ]]; then
  echo "warning: corpus has fewer than 1000 files" >&2
fi
