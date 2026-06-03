#!/bin/bash
# Plex Media Server Stack - Config Backup
# Backs up all critical configuration files to /mnt/Media/backups/
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

Backs up Kometa, UMTK, ImageMaid, and Docker compose files
to <backups>/<hostname>-backup-YYYYMMDD.zip

Options:
  -h, --help        Show this help message
  -q, --quiet       Suppress terminal output (log only)
  --no-discord      Skip Discord notifications

Schedule: Sundays at 01:00 via crontab
Retention: configured via retention_days in config.yml
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
BACKUP_FILE="$BACKUP_DIR/${SERVER_HOSTNAME}-backup-${DATE}.zip"
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
    [[ -z "$webhook" ]] && return
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
mkdir -p "$TEMP_DIR"/{kometa/{config,scripts},UMTK/config,ImageMaid/config,docker}

# --- Kometa config ---
echo "Collecting Kometa config..."
cp "$KOMETA_CONFIG"/*.yml "$TEMP_DIR/kometa/config/" 2>/dev/null
if find "$METADATA_DIR" -name "*.yml" 2>/dev/null | grep -q .; then
    cp -r "$METADATA_DIR" "$TEMP_DIR/kometa/config/" 2>/dev/null
fi

# --- Scripts config ---
echo "Collecting scripts config..."
cp "$SCRIPTS_DIR/config.yml" "$TEMP_DIR/kometa/scripts/" 2>/dev/null

# --- UMTK/TSSK ---
echo "Collecting UMTK config..."
cp "$UMTK_CONFIG_DIR"/*.yml "$TEMP_DIR/UMTK/config/" 2>/dev/null

# --- ImageMaid ---
echo "Collecting ImageMaid config..."
cp "$IMAGEMAID_CONFIG_DIR/.env" "$TEMP_DIR/ImageMaid/config/" 2>/dev/null

# --- Docker compose files ---
echo "Collecting Docker compose files..."
for compose_path in "${COMPOSE_FILES[@]}"; do
    if [ -f "$compose_path" ]; then
        # Preserve directory context in the archive (use parent folder name)
        dir_name=$(basename "$(dirname "$compose_path")")
        mkdir -p "$TEMP_DIR/docker/$dir_name"
        cp "$compose_path" "$TEMP_DIR/docker/$dir_name/" 2>/dev/null
    fi
done

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

# --- Cleanup old backups ---
DELETED=$(find "$BACKUP_DIR" -name "${SERVER_HOSTNAME}-backup-*.zip" -mtime +$KEEP_DAYS -delete -print | wc -l)
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
echo "Log: $LOG_FILE"

# Discord notification
send_discord "$DISCORD_NOTIFICATIONS" "💾 Backup Complete" "⏱️ ${DURATION}s

**Config backup:**
\`\`\`
Archive: ${SERVER_HOSTNAME}-backup-${DATE}.zip
Size:    $SIZE
Files:   $FILE_COUNT
\`\`\`

**Old backups cleaned:** $DELETED" "3066993"
