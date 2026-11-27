#!/bin/bash
# Plex Media Server Stack - UMTK Overlay Placeholder Sanitiser
# ------------------------------------------------------------------------------
# UMTK regenerates ~/UMTK/kometa/*_OVERLAYS.yml on every run. When a category has
# no matching library items it writes a comment-only file, and Kometa then fails
# to load it with:
#   "YAML Error: overlays attribute is required"   (modules/meta.py:2690)
# Kometa rejects the placeholder in every "empty" form - `overlays: {}`, `overlays: []`
# and a bare `overlays:` all leave the parsed overlay collection empty/falsy - so
# such files are rewritten here with a valid overlay that matches nothing. The file
# then loads cleanly ("Overlay File Loaded Successfully") and applies no artwork.
#
# Files referenced by ~/kometa/config/config.yml must never be deleted (Kometa
# would report a missing overlay file instead); they are kept valid between runs.
# UMTK overwrites the placeholder with real content as soon as a show matches.
#
# Usage:
#   ./fix-umtk-overlays.sh [options]
#
# Options:
#   -h, --help      Show this help message
#   -q, --quiet     Suppress terminal output (log only)
#
# Schedule: daily at 02:30 via crontab (after the UMTK run, before Kometa)

####### HELP #######
show_help() {
    cat <<'HELP'
UMTK Overlay Placeholder Sanitiser — keeps UMTK-generated overlay files loadable

Usage: fix-umtk-overlays.sh [options]

Rewrites UMTK overlay files that contain no overlay definitions (empty files,
comment-only files, or `overlays: {}` / `overlays: []`) with a valid overlay that
matches no library item, so every file listed in ~/kometa/config/config.yml loads
without error.

Options:
  -h, --help      Show this help message
  -q, --quiet     Suppress terminal output (log only)

Schedule: Daily at 02:30 via crontab
HELP
}

####### ARGUMENT PARSING #######
QUIET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        -q|--quiet) QUIET=true; shift ;;
        *) shift ;;
    esac
done

####### CONFIGURATION #######
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

LOG_FILE="$LOG_DIR/fix-umtk-overlays/fix-umtk-overlays_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR/fix-umtk-overlays"

# Redirect output
if [ "$QUIET" = true ]; then
    exec > "$LOG_FILE" 2>&1
else
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

####### FUNCTIONS #######
SCRIPT_NAME="fix-umtk-overlays.sh"
PLACEHOLDER_TITLE="zzz-umtk-placeholder-no-match-zzz"

# Write a Kometa-valid overlay block that cannot match any library item:
#   - plex_all + a never-matching filter -> the overlay queue stays empty
#     (plex_search is NOT used: an empty Plex *search* raises
#      "Plex Error: No Items found in Plex")
#   - backdrop (built-in overlay type) with a 1x1 black box as a harmless fallback
write_placeholder() {
    local file="$1"
    cat > "$file" <<PLACEHOLDER
# UMTK placeholder - no matching library items when this file was generated.
# Written by ~/kometa/scripts/fix-umtk-overlays.sh: Kometa requires a non-empty
# "overlays" block, so an overlay that matches nothing is used instead of an
# empty mapping. UMTK rewrites this file with real content once a show matches.
overlays:
  umtk_placeholder_no_match:
    plex_all: true
    filters:
      title.is: "$PLACEHOLDER_TITLE"
    overlay:
      name: backdrop
      back_color: '#000000'
      back_height: 1
      back_width: 1
      horizontal_align: left
      vertical_align: top
      horizontal_offset: 0
      vertical_offset: 0
      weight: 1
PLACEHOLDER
}

####### MAIN #######
echo "=== UMTK Overlay Placeholder Sanitiser ==="
echo "Date:        $(date '+%Y-%m-%d %H:%M:%S')"
echo "Overlay dir: $UMTK_OUTPUT_DIR"
echo

if [ ! -d "$UMTK_OUTPUT_DIR" ]; then
    echo "[✗] Overlay directory not found: $UMTK_OUTPUT_DIR"
    discord_notify "error" "❌ UMTK Overlay Sanitiser Failed" "Overlay directory not found: $UMTK_OUTPUT_DIR"
    exit 1
fi

CHECKED=0
FIXED=0
REAL=0

for file in "$UMTK_OUTPUT_DIR"/*_OVERLAYS.yml; do
    [ -e "$file" ] || continue
    CHECKED=$((CHECKED + 1))

    # Lines that are neither comments/blank nor a bare/empty `overlays:` key decide
    # whether the file carries real overlay definitions. Files that still hold our
    # own placeholder are rewritten too, so template changes propagate.
    real_content=$(grep -vE '^[[:space:]]*(#.*)?$' "$file" 2>/dev/null \
        | grep -vE '^[[:space:]]*overlays:[[:space:]]*(\{\}|\[\])?[[:space:]]*$' || true)

    if [ -z "$real_content" ] || grep -q "$PLACEHOLDER_TITLE" "$file" 2>/dev/null; then
        write_placeholder "$file"
        FIXED=$((FIXED + 1))
        echo "  [+] placeholder written: $(basename "$file")"
    else
        REAL=$((REAL + 1))
    fi
done

echo
echo "[✓] $CHECKED overlay file(s) checked: $FIXED placeholder(s) written, $REAL with real content"
exit 0
