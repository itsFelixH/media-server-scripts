#!/bin/bash
# Plex Media Server Stack - Report Archiver
# Copies new/changed reports from ~/kometa/scripts/reports/ to /mnt/Media/reports/
# Runs daily via crontab; also called by backup.sh.
#
# Usage:
#   ./archive-reports.sh [options]
#
# Options:
#   -h, --help        Show this help message
#   -q, --quiet       Suppress terminal output (log only)
#   --no-discord      Skip Discord notifications

####### HELP #######
show_help() {
    cat <<'HELP'
Report Archiver — Archives new/changed reports to /mnt/Media/reports/

Usage: archive-reports.sh [options]

Copies reports (JSON and markdown) from ~/kometa/scripts/reports/ to /mnt/Media/reports/
with date-stamped filenames. Only copies when content has changed.

Options:
  -h, --help        Show this help message
  -q, --quiet       Suppress terminal output (log only)
  --no-discord      Skip Discord notifications

Schedule: Daily at 05:30 via crontab
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

LOG_FILE="$LOG_DIR/archive-reports/archive-reports_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR/archive-reports"

# Redirect output
if [ "$QUIET" = true ]; then
    exec > "$LOG_FILE" 2>&1
else
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

####### FUNCTIONS #######
SCRIPT_NAME="archive-reports.sh"

####### MAIN #######
echo "=== Report Archiver ==="
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo

# Create archive directory
mkdir -p "$REPORTS_DIR"

# Check if archive drive is mounted
ARCHIVE_MOUNT=$(df "$REPORTS_DIR" 2>/dev/null | awk 'NR==2 {print $6}')
if [ "$ARCHIVE_MOUNT" = "/" ] && [[ "$REPORTS_DIR" == /mnt/* || "$REPORTS_DIR" == /media/* ]]; then
    echo "[✗] Archive destination $REPORTS_DIR is not mounted. Archiving skipped."
    discord_notify "error" "❌ Report Archive Failed" "Archive destination not mounted."
    exit 1
fi

# Archive reports (only if changed)
REPORT_COUNT=0
REPORT_SKIPPED=0
while IFS= read -r -d '' file; do
    filename=$(basename "$file")
    ext="${filename##*.}"
    base_name="${filename%.*}"

    # Create per-report subdirectory
    report_dir="$REPORTS_DIR/$base_name"
    mkdir -p "$report_dir"

    # Extract generation date from the report
    if [ "$ext" = "json" ]; then
        report_date=$(jq -r '.generated // empty' "$file" 2>/dev/null | grep -oP '^[0-9]{4}-[0-9]{2}-[0-9]{2}')
    else
        report_date=$(grep -oP '\*\*Generated:\*\*\s*\K[0-9]{4}-[0-9]{2}-[0-9]{2}' "$file" 2>/dev/null | head -1)
    fi
    [ -z "$report_date" ] && report_date=$(date +%Y-%m-%d)

    dest_file="$report_dir/${base_name}-${report_date}.${ext}"

    # Skip if identical to the latest archived version
    latest_archived=$(find "$report_dir" -name "${base_name}-*.${ext}" ! -name "latest.${ext}" -type f 2>/dev/null | sort | tail -1)
    if [ -n "$latest_archived" ] && diff -q "$file" "$latest_archived" >/dev/null 2>&1; then
        ((REPORT_SKIPPED++))
        continue
    fi

    # Skip if this exact date file already exists and is identical
    if [ -f "$dest_file" ] && diff -q "$file" "$dest_file" >/dev/null 2>&1; then
        ((REPORT_SKIPPED++))
        continue
    fi

    cp "$file" "$dest_file" 2>/dev/null
    ((REPORT_COUNT++))
    echo "  [+] $base_name ($report_date)"
done < <(find "$REPORT_DIR" -maxdepth 1 \( -name "*.md" -o -name "*.json" \) ! -name "*.prev.*" ! -name "system-status.json" -type f -print0)

if [ "$REPORT_COUNT" -gt 0 ]; then
    echo "[✓] Reports archived: $REPORT_COUNT new, $REPORT_SKIPPED unchanged (skipped)"
    discord_notify "success" "📋 Reports Archived" "$REPORT_COUNT new reports"
elif [ "$REPORT_SKIPPED" -gt 0 ]; then
    echo "[✓] Reports: $REPORT_SKIPPED unchanged (nothing to archive)"
else
    echo "[!] No report files found in $REPORT_DIR"
fi

echo
echo "=== Done ==="
echo "Log: $LOG_FILE"
