#!/bin/zsh
set -euo pipefail

# Reset Ledger window, pane, and list column layout to defaults for UX testing.
#
# Clears:
#   - Window frame autosave (position and size)
#   - Split pane divider positions (sidebar width, inspector width)
#   - List column widths, order, and visibility
#   - Split autosave migration sentinel (harmless to re-run)
#   - Saved application state (NSApplicationRestorationState)
#
# Preserves:
#   - Pinned sidebar items     (sidebar_favorites.json in Application Support)
#   - Recent sidebar locations (recent_locations.json in Application Support)
#   - All settings/preferences (sort order, view mode, inspector visibility, etc.)
#
# Usage:
#   ./reset_ledger_layout.sh
#   ./reset_ledger_layout.sh --yes

BUNDLE_ID="com.chrislemarquand.Ledger"
ID_PREFIX="Ledger"

ASSUME_YES=0

usage() {
  cat <<'USAGE'
Usage:
  ./reset_ledger_layout.sh [--yes]

Options:
  --yes    Skip confirmation prompt
  --help   Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

SAVED_STATE_DIR="$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState"

# UserDefaults keys to remove.
DEFAULTS_KEYS=(
  # Window frame
  "NSWindow Frame ${ID_PREFIX}.MainWindow"
  # Settings window frame
  "NSWindow Frame SharedUI.SettingsWindow"
  # Split pane divider positions
  "NSSplitView Subview Frames ${ID_PREFIX}.MainSplit"
  "NSSplitView Subview Frames ${ID_PREFIX}.ContentSplit"
  "NSSplitView Divider Positions ${ID_PREFIX}.MainSplit"
  "NSSplitView Divider Positions ${ID_PREFIX}.ContentSplit"
  # List column widths and order
  "NSTableView Columns ${ID_PREFIX}.BrowserList"
  # List column visibility
  "${ID_PREFIX}.listColumns.visible"
  # Initial column fit sentinel (cleared so first-launch fit re-runs on next open)
  "${ID_PREFIX}.listColumns.initialFitApplied"
  # Split autosave migration sentinel (safe to re-run, no legacy data present)
  "ui.split.autosave.reset.v4"
)

echo "This will reset Ledger window and list column layout."
echo "Sidebar items and preferences will NOT be affected."
echo ""
echo "Will remove UserDefaults keys:"
for key in "${DEFAULTS_KEYS[@]}"; do
  echo "  - $key"
done
echo ""
echo "Will remove:"
echo "  - $SAVED_STATE_DIR"
echo ""

if [[ $ASSUME_YES -ne 1 ]]; then
  printf "Continue? [y/N] "
  read -r REPLY
  if [[ "${REPLY:l}" != "y" ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

echo "Stopping Ledger if running..."
pkill -x Ledger 2>/dev/null || true
sleep 0.5

echo "Removing layout defaults keys..."
for key in "${DEFAULTS_KEYS[@]}"; do
  defaults delete "$BUNDLE_ID" "$key" 2>/dev/null && echo "  Deleted: $key" || echo "  Not set: $key"
done

echo "Removing saved application state..."
rm -rf "$SAVED_STATE_DIR"

echo ""
echo "Done. Next launch will open with default layout."
