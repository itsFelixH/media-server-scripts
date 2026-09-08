#!/bin/bash
# Plex & AURA Artwork Metadata Audit
# Audits Plex library artwork health and AURA / MediUX set coverage.
#
# Usage:
#   ./metadata-audit.sh [options]
#
# Options:
#   -h, --help        Show this help message
#   -q, --quiet       Suppress terminal output (log only)
#   --no-discord      Skip Discord notification

VERSION="2.0"

####### HELP #######
show_help() {
    cat <<'HELP'
Plex & AURA Artwork Metadata Audit - Audits Plex artwork and MediUX set coverage.

Usage: metadata-audit.sh [options]

Audits:
  - Movies & TV Shows with AURA / MediUX sets applied
  - Movies & TV Shows missing MediUX artwork sets
  - TV Shows missing episode title card sets
  - Plex items with missing posters or unmatched TMDb/TVDb IDs
  - MediUX creator breakdown and set links

Options:
  -h, --help        Show this help message
  -q, --quiet       Suppress terminal output (log only)
  --no-discord      Skip Discord notification

Output: ~/kometa/scripts/reports/metadata-audit.json (overwritten each run)
Schedule: Sundays at 02:00 via crontab
HELP
}

####### ARGUMENT PARSING #######
QUIET=false
NO_DISCORD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        -q|--quiet) QUIET=true; shift ;;
        --no-discord) NO_DISCORD=true; shift ;;
        *) shift ;;
    esac
done

####### CONFIGURATION #######
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

LOG_FILE="$LOG_DIR/metadata-audit/metadata-audit_$(date +%Y%m%d_%H%M%S).log"
REPORT_FILE="$REPORT_DIR/metadata-audit.json"
BASELINE_FILE="$REPORT_DIR/metadata-audit.baseline.json"
mkdir -p "$LOG_DIR/metadata-audit"

if [ "$QUIET" = true ]; then
    exec > "$LOG_FILE" 2>&1
else
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

####### DEPENDENCY CHECK #######
MISSING_DEPS=()
command -v jq &>/dev/null || MISSING_DEPS+=("jq")
command -v curl &>/dev/null || MISSING_DEPS+=("curl")
command -v python3 &>/dev/null || MISSING_DEPS+=("python3")

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "ERROR: Missing required dependencies:"
    for dep in "${MISSING_DEPS[@]}"; do echo "  - $dep"; done
    exit 1
fi

####### MAIN #######
START_TIME=$(date +%s)
SCRIPT_NAME="metadata-audit.sh"

echo "=== Plex & AURA Artwork Audit v$VERSION ==="
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo

python3 "$SCRIPTS_DIR/metadata-audit.py"
EXIT_CODE=$?

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ $EXIT_CODE -ne 0 ]; then
    echo "ERROR: metadata-audit.py failed with exit code $EXIT_CODE"
    discord_notify "error" "❌ Metadata Audit Failed" "Python engine returned error $EXIT_CODE"
    exit $EXIT_CODE
fi

# Refresh baseline if older than 7 days
if [ ! -f "$BASELINE_FILE" ]; then
    cp "$REPORT_FILE" "$BASELINE_FILE"
elif [ $(( $(date +%s) - $(stat -c %Y "$BASELINE_FILE" 2>/dev/null || echo 0) )) -gt 604800 ]; then
    cp "$REPORT_FILE" "$BASELINE_FILE"
fi

echo
echo "=== Complete ==="
echo "Duration: ${DURATION}s"
echo "Log: $LOG_FILE"

# Extract metrics for Discord notification
M_COV=$(jq -r '.summary.movie_coverage_pct // 0' "$REPORT_FILE" 2>/dev/null)
T_COV=$(jq -r '.summary.tv_coverage_pct // 0' "$REPORT_FILE" 2>/dev/null)
M_MISS=$(jq -r '.data.missing.movies | length // 0' "$REPORT_FILE" 2>/dev/null)
T_MISS=$(jq -r '.data.missing.tv | length // 0' "$REPORT_FILE" 2>/dev/null)
TC_MISS=$(jq -r '.data.titlecards_missing | length // 0' "$REPORT_FILE" 2>/dev/null)
H_STAT=$(jq -r '.health.status // "ok"' "$REPORT_FILE" 2>/dev/null)

DISCORD_DESC="**MediUX Artwork Coverage**
• Movies: **${M_COV}%** (${M_MISS} without set)
• TV Shows: **${T_COV}%** (${T_MISS} without set)
• TV Title Cards: **${TC_MISS}** shows missing cards"

if [ "$H_STAT" = "error" ]; then
    discord_notify "error" "❌ Artwork Audit Issues" "$DISCORD_DESC"
elif [ "$H_STAT" = "warning" ]; then
    discord_notify "warning" "🎨 Artwork Audit Summary" "$DISCORD_DESC"
else
    discord_notify "success" "🎨 Artwork Audit Complete" "$DISCORD_DESC"
fi
