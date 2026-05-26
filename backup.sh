#!/bin/bash
# Plex Media Server Stack - Config Backup
# Backs up all critical configuration files to /mnt/Media/backups/
# Archives report snapshots to /mnt/Media/reports/
# Run weekly via crontab or maintenance script.
#
# Usage:
#   ./backup.sh [options]
#
# Options:
#   -h, --help        Show this help message
#   -q, --quiet       Suppress terminal output (log only)
#   --no-discord      Skip Discord notifications

####### HELP #######
show_help() {
    cat <<'HELP'
Config Backup — Backs up all critical configuration files.

Usage: backup.sh [options]

Backs up Kometa, UMTK, ImageMaid, Docker compose files, and scripts
to /mnt/Media/backups/plex-config-YYYYMMDD.zip

Report files (*.md from logs/) are archived separately to:
  /mnt/Media/reports/ (with date timestamp: filename-YYYYMMDD.md)

Options:
  -h, --help        Show this help message
  -q, --quiet       Suppress terminal output (log only)
  --no-discord      Skip Discord notifications

Schedule: Sundays at 01:00 via crontab
Retention: 30 days (config backups only; reports are kept indefinitely)
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

LOG_FILE="$LOG_DIR/backup/backup_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR/backup"

# Redirect output
if [ "$QUIET" = true ]; then
    exec > "$LOG_FILE" 2>&1
else
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

DATE=$(date +%Y%m%d)
BACKUP_FILE="$BACKUP_DIR/plex-config-${DATE}.zip"
KEEP_DAYS=$RETENTION_BACKUPS_DAYS

####### DEPENDENCY CHECK #######
MISSING_DEPS=()
command -v zip &>/dev/null || MISSING_DEPS+=("zip")
command -v unzip &>/dev/null || MISSING_DEPS+=("unzip")
command -v jq &>/dev/null || MISSING_DEPS+=("jq")
command -v curl &>/dev/null || MISSING_DEPS+=("curl")

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "ERROR: Missing required dependencies:"
    for dep in "${MISSING_DEPS[@]}"; do echo "  - $dep"; done
    exit 1
fi

####### FUNCTIONS #######
send_discord() {
    local webhook="$1" title="$2" description="$3" color="$4"
    [ "$NO_DISCORD" = true ] && return
    if [ ${#description} -gt $DISCORD_DESC_LIMIT ]; then
        description="${description:0:$((DISCORD_DESC_LIMIT - 20))}…

*(truncated)*"
    fi
    local payload
    payload=$(jq -n --arg title "$title" --arg desc "$description" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson color "$color" \
        '{embeds: [{title: $title, description: $desc, color: $color, footer: {text: "'"$FOOTER_PREFIX"' • backup.sh"}, timestamp: $ts}]}')
    curl -s -H "Content-Type: application/json" -d "$payload" "$webhook" >/dev/null 2>&1
}

####### MAIN #######
START_TIME=$(date +%s)
echo "=== Config Backup ==="
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo

# Create backup directory if needed
mkdir -p "$BACKUP_DIR"
mkdir -p "$REPORTS_DIR"

# Check if backup drive is mounted
BACKUP_MOUNT=$(df "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $6}')
if [ "$BACKUP_MOUNT" = "/" ] && [[ "$BACKUP_DIR" == /mnt/* || "$BACKUP_DIR" == /media/* ]]; then
    echo "[✗] Backup destination $BACKUP_DIR is not mounted. Backup aborted."
    send_discord "$DISCORD_ALERTS" "❌ Backup Failed" "Backup destination $BACKUP_DIR is not mounted. Backup aborted." "16711680"
    exit 1
fi

echo "Destination: $BACKUP_FILE"
echo

# Create a temporary directory for backup staging
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Create directory structure in temp location
mkdir -p "$TEMP_DIR"/{kometa/{config,scripts},UMTK/config,ImageMaid/config,docker/{kometa,umtk,wtwp,imagemaid}}

# --- Kometa config ---
echo "Collecting Kometa config..."
cp "$KOMETA_CONFIG/config.yml" "$TEMP_DIR/kometa/config/" 2>/dev/null
cp "$KOMETA_CONFIG/movies.yml" "$TEMP_DIR/kometa/config/" 2>/dev/null
cp "$KOMETA_CONFIG/tv.yml" "$TEMP_DIR/kometa/config/" 2>/dev/null
cp "$KOMETA_CONFIG/playlists.yml" "$TEMP_DIR/kometa/config/" 2>/dev/null
cp -r "$METADATA_DIR" "$TEMP_DIR/kometa/config/" 2>/dev/null

# --- Scripts ---
echo "Collecting scripts..."
cp "$SCRIPTS_DIR/maintenance.sh" "$TEMP_DIR/kometa/scripts/" 2>/dev/null
cp "$SCRIPTS_DIR/runkometa.sh" "$TEMP_DIR/kometa/scripts/" 2>/dev/null
cp "$SCRIPTS_DIR/backup.sh" "$TEMP_DIR/kometa/scripts/" 2>/dev/null
cp "$SCRIPTS_DIR/healthcheck.sh" "$TEMP_DIR/kometa/scripts/" 2>/dev/null
cp "$SCRIPTS_DIR/media-analyzer.sh" "$TEMP_DIR/kometa/scripts/" 2>/dev/null
cp "$SCRIPTS_DIR/storage-report.sh" "$TEMP_DIR/kometa/scripts/" 2>/dev/null
cp "$SCRIPTS_DIR/metadata-audit.sh" "$TEMP_DIR/kometa/scripts/" 2>/dev/null
cp "$SCRIPTS_DIR/library-catalog.sh" "$TEMP_DIR/kometa/scripts/" 2>/dev/null
cp "$SCRIPTS_DIR/encode-queue.sh" "$TEMP_DIR/kometa/scripts/" 2>/dev/null
cp "$SCRIPTS_DIR/config.yml" "$TEMP_DIR/kometa/scripts/" 2>/dev/null
cp "$SCRIPTS_DIR/config.yml.template" "$TEMP_DIR/kometa/scripts/" 2>/dev/null
cp "$SCRIPTS_DIR/config.sh" "$TEMP_DIR/kometa/scripts/" 2>/dev/null

# --- UMTK/TSSK ---
echo "Collecting UMTK config..."
cp "$UMTK_CONFIG_DIR/config.yml" "$TEMP_DIR/UMTK/config/" 2>/dev/null
cp "$UMTK_CONFIG_DIR/tssk_config.yml" "$TEMP_DIR/UMTK/config/" 2>/dev/null

# --- ImageMaid ---
echo "Collecting ImageMaid config..."
cp "$IMAGEMAID_CONFIG_DIR/.env" "$TEMP_DIR/ImageMaid/config/" 2>/dev/null

# --- Docker compose files ---
echo "Collecting Docker compose files..."
cp "$HOME/docker/kometa/docker-compose.yml" "$TEMP_DIR/docker/kometa/" 2>/dev/null
cp "$HOME/docker/umtk/docker-compose.yml" "$TEMP_DIR/docker/umtk/" 2>/dev/null
cp "$HOME/docker/wtwp/docker-compose.yml" "$TEMP_DIR/docker/wtwp/" 2>/dev/null
cp "$HOME/docker/imagemaid/docker-compose.yml" "$TEMP_DIR/docker/imagemaid/" 2>/dev/null

# --- Crontab ---
echo "Collecting crontab..."
crontab -l > "$TEMP_DIR/crontab.txt" 2>/dev/null

echo

# Create main config backup zip
echo "Creating archive..."
if cd "$TEMP_DIR" && zip -rq "$BACKUP_FILE" . ; then
    SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo "[✓] Backup created: $BACKUP_FILE ($SIZE)"

    # Verify backup integrity
    if unzip -tq "$BACKUP_FILE" >/dev/null 2>&1; then
        FILE_COUNT=$(unzip -l "$BACKUP_FILE" 2>/dev/null | tail -1 | awk '{print $2}')
        echo "[✓] Verified: $FILE_COUNT files, archive is valid"
    else
        echo "[✗] Verification FAILED — archive may be corrupt"
        send_discord "$DISCORD_ALERTS" "⚠️ Backup Warning" "Backup created ($SIZE) but verification failed — archive may be corrupt." "16776960"
    fi
else
    echo "[✗] Backup failed (zip error)"
    send_discord "$DISCORD_ALERTS" "❌ Backup Failed" "zip command failed. Check disk space and permissions." "16711680"
    exit 1
fi

# --- Archive reports (only if changed) ---
echo
echo "Archiving reports..."
REPORT_COUNT=0
REPORT_SKIPPED=0
while IFS= read -r -d '' file; do
    filename=$(basename "$file")
    base_name="${filename%.*}"

    # Create per-report subdirectory
    report_dir="$REPORTS_DIR/$base_name"
    mkdir -p "$report_dir"

    # Extract generation date from the report (looks for "**Generated:** YYYY-MM-DD")
    report_date=$(grep -oP '\*\*Generated:\*\*\s*\K[0-9]{4}-[0-9]{2}-[0-9]{2}' "$file" 2>/dev/null | head -1)
    [ -z "$report_date" ] && report_date=$(date +%Y-%m-%d)

    dest_file="$report_dir/${base_name}-${report_date}.md"

    # Skip if identical to the latest archived version
    latest_archived=$(find "$report_dir" -name "${base_name}-*.md" ! -name "latest.md" -type f 2>/dev/null | sort | tail -1)
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
done < <(find "$REPORT_DIR" -maxdepth 1 -name "*.md" ! -name "*.prev.md" -type f -print0)

if [ "$REPORT_COUNT" -gt 0 ]; then
    echo "[✓] Reports archived: $REPORT_COUNT new, $REPORT_SKIPPED unchanged (skipped)"
elif [ "$REPORT_SKIPPED" -gt 0 ]; then
    echo "[✓] Reports: $REPORT_SKIPPED unchanged (nothing to archive)"
else
    echo "[!] No report files found in $REPORT_DIR"
fi

# --- Cleanup old backups ---
DELETED=$(find "$BACKUP_DIR" -name "plex-config-*.zip" -mtime +$KEEP_DAYS -delete -print | wc -l)
if [ "$DELETED" -gt 0 ]; then
    echo "[✓] Cleaned up $DELETED old backup(s) (older than $KEEP_DAYS days)"
fi

# --- Summary ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo
echo "=== Backup Complete ==="
echo "Duration: ${DURATION}s"
echo "Archive: $BACKUP_FILE ($SIZE)"
echo "Reports: $REPORT_COUNT new, $REPORT_SKIPPED unchanged"
echo "Log: $LOG_FILE"

# Discord notification
send_discord "$DISCORD_NOTIFICATIONS" "💾 Backup Complete" "⏱️ ${DURATION}s

**Config backup:**
\`\`\`
Archive: plex-config-${DATE}.zip
Size:    $SIZE
Files:   $FILE_COUNT
\`\`\`

**Reports:** $REPORT_COUNT new, $REPORT_SKIPPED unchanged
**Old backups cleaned:** $DELETED" "3066993"
