#!/bin/bash
# config.sh — Shared configuration loader for all scripts
# Source this file at the top of any script:
#   SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPTS_DIR/config.sh"
#
# Variables exported (grouped by section):
#
#   Server:     SERVER_HOSTNAME
#   Plex:       PLEX_URL, PLEX_TOKEN
#   API Keys:   API_KEY_RADARR, API_KEY_SONARR
#   Discord:    DISCORD_ALERTS, DISCORD_NOTIFICATIONS, DISCORD_DESC_LIMIT, DISCORD_CONTENT_LIMIT
#   Paths:      KOMETA_CONFIG, SCRIPTS_DIR, LOG_DIR, REPORT_DIR, REPORTS_DIR, METADATA_DIR,
#               MOVIES_DIR, TV_DIR, BACKUP_DIR,
#               UMTK_CONFIG_DIR, UMTK_LOGS_DIR, IMAGEMAID_CONFIG_DIR
#   Services:   PLEX_SERVICE, ARR_SERVICES (array), DOCKER_CONTAINERS (array)
#   Thresholds: THRESH_DISK_ROOT_WARN, THRESH_DISK_ROOT_CRITICAL, THRESH_DISK_MEDIA_CRITICAL,
#               THRESH_MEMORY_CRITICAL, THRESH_TEMP_CRITICAL, THRESH_TEMP_WARN,
#               THRESH_CONTAINER_RESTART_WARN, THRESH_TASK_STALE_MIN
#   Retention:  RETENTION_DAYS, RETENTION_SHORT_DAYS
#   Notify:     NOTIFY_ON_SUCCESS, NOTIFY_ON_FAILURE, FOOTER_PREFIX
#   Defaults:   MEDIA_ANALYZER_DIR, MEDIA_ANALYZER_THRESHOLD_GB, MEDIA_ANALYZER_MIN_BITRATE,
#               ENCODE_QUEUE_DIR, ENCODE_QUEUE_LIMIT, ENCODE_QUEUE_MIN_SIZE_GB, ENCODE_QUEUE_HEVC_RATIO

# Determine scripts directory (caller should set SCRIPTS_DIR before sourcing, or we detect it)
if [ -z "$SCRIPTS_DIR" ]; then
    SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

CONFIG_FILE="$SCRIPTS_DIR/config.yml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Shared config not found: $CONFIG_FILE" >&2
    exit 1
fi

# --- YAML parser (pure awk, no python dependency) ---

_cfg() {
    # Usage: _cfg "section.key" [default]
    local key="$1" default="${2:-}"
    local value=""
    local section="" field=""

    if [[ "$key" == *.* ]]; then
        section="${key%%.*}"
        field="${key#*.}"
    else
        field="$key"
    fi

    if [ -n "$section" ]; then
        value=$(awk -v section="$section:" -v field="$field:" '
            $0 ~ "^" section { in_section=1; next }
            in_section && /^[a-z_]/ { in_section=0 }
            in_section && $0 ~ "^  " field {
                sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
                sub(/[[:space:]]+#.*$/, "")
                print
                exit
            }
        ' "$CONFIG_FILE")
    else
        value=$(awk -v field="$field:" '
            $0 ~ "^" field {
                sub(/^[^:]+:[[:space:]]*/, "")
                sub(/[[:space:]]+#.*$/, "")
                print
                exit
            }
        ' "$CONFIG_FILE")
    fi

    # Expand ~ to $HOME
    value="${value/#\~/$HOME}"

    printf '%s' "${value:-$default}"
}

_cfg_list() {
    # Parse YAML list items (lines starting with "    - " under section.subsection)
    local section="$1" subsection="$2"
    awk -v section="$section:" -v subsection="$subsection:" '
        $0 ~ "^" section { in_section=1; next }
        in_section && /^[a-z_]/ { in_section=0 }
        in_section && $0 ~ "^  " subsection { in_subsection=1; next }
        in_subsection && /^    - / { sub(/^[[:space:]]*- /, ""); print; next }
        in_subsection && /^  [a-z_]/ { in_subsection=0 }
        in_subsection && /^[a-z_]/ { in_subsection=0; in_section=0 }
    ' "$CONFIG_FILE"
}

# --- Load configuration ---

# Server
SERVER_HOSTNAME="$(_cfg server.hostname)"

# Plex
PLEX_URL="$(_cfg plex.url "http://localhost:32400")"
PLEX_TOKEN="$(_cfg plex.token)"

# API Keys (optional — scripts skip checks if empty)
API_KEY_RADARR="$(_cfg api_keys.radarr)"
API_KEY_SONARR="$(_cfg api_keys.sonarr)"

# Discord
DISCORD_ALERTS="$(_cfg discord.alerts)"
DISCORD_NOTIFICATIONS="$(_cfg discord.notifications)"
DISCORD_DESC_LIMIT=4000               # Discord API constant
DISCORD_CONTENT_LIMIT=1900            # Safe max for content messages

# Paths — media
MOVIES_DIR="$(_cfg media.movies)"
TV_DIR="$(_cfg media.tv)"

# Paths — tool installations
KOMETA_CONFIG="$(_cfg tools.kometa)"
METADATA_DIR="$KOMETA_CONFIG/metadata"
UMTK_CONFIG_DIR="$(_cfg tools.umtk)"
UMTK_LOGS_DIR="$(_cfg tools.umtk)/logs"
IMAGEMAID_CONFIG_DIR="$(_cfg tools.imagemaid)"

# Paths — script output
LOG_DIR="$(_cfg output.logs)"
REPORT_DIR="$(_cfg output.reports)"

# Paths — backup destinations
BACKUP_DIR="$(_cfg backup.configs)"
REPORTS_DIR="$(_cfg backup.reports)"

# Compose files to back up
mapfile -t COMPOSE_FILES < <(_cfg_list tools compose_files)
COMPOSE_FILES=("${COMPOSE_FILES[@]/#\~/$HOME}")

# Services
PLEX_SERVICE="$(_cfg services.plex "plexmediaserver")"
mapfile -t ARR_SERVICES < <(_cfg_list services arr)
mapfile -t DOCKER_CONTAINERS < <(_cfg_list services docker_containers)

# Thresholds (hardcoded — sensible defaults for most systems)
THRESH_DISK_ROOT_WARN=80
THRESH_DISK_ROOT_CRITICAL=90
THRESH_DISK_MEDIA_CRITICAL=95
THRESH_MEMORY_CRITICAL=95
THRESH_TEMP_CRITICAL=80
THRESH_TEMP_WARN=70
THRESH_CONTAINER_RESTART_WARN=3
THRESH_TASK_STALE_MIN=1560            # ~26h — alert if scheduled task hasn't run

# Retention (single config value, applied uniformly)
RETENTION_DAYS="$(_cfg retention_days 30)"
RETENTION_LOGS_DAYS="$RETENTION_DAYS"
RETENTION_BACKUPS_DAYS="$RETENTION_DAYS"
RETENTION_UMTK_LOGS_DAYS="$RETENTION_DAYS"
RETENTION_PTS_DAYS="$RETENTION_DAYS"

# Notifications
NOTIFY_ON_SUCCESS="$(_cfg notifications.on_success true)"
NOTIFY_ON_FAILURE="$(_cfg notifications.on_failure true)"
FOOTER_PREFIX="$SERVER_HOSTNAME"

# Ensure log and report directories exist
mkdir -p "$LOG_DIR" "$REPORT_DIR"

# Media Analyzer defaults (override via CLI flags)
MEDIA_ANALYZER_DIR="$TV_DIR"
MEDIA_ANALYZER_THRESHOLD_GB=5
MEDIA_ANALYZER_MIN_BITRATE=1000

# Encode Queue defaults (override via CLI flags)
ENCODE_QUEUE_DIR="$TV_DIR"
ENCODE_QUEUE_LIMIT=50
ENCODE_QUEUE_MIN_SIZE_GB=1
ENCODE_QUEUE_HEVC_RATIO=45

# --- Discord helpers ---
# Shared by all scripts. Set NO_DISCORD=true in your script to suppress.

# Color constants
DISCORD_COLOR_SUCCESS=3066993         # Green
DISCORD_COLOR_WARNING=16776960        # Yellow
DISCORD_COLOR_ERROR=16711680          # Red

# Send a Discord embed notification
# Usage: discord_notify <level> <title> <description>
#   level: success | warning | error
#   title: embed title (short, no emoji needed — added automatically)
#   description: embed body (markdown supported, keep it brief)
#
# Respects NOTIFY_ON_SUCCESS / NOTIFY_ON_FAILURE preferences.
# Footer auto-includes: hostname • script name • duration (if START_TIME is set)
discord_notify() {
    local level="$1" title="$2" description="${3:-}"
    [ "$NO_DISCORD" = true ] && return

    local webhook="" color=0
    case "$level" in
        success)
            [ "$NOTIFY_ON_SUCCESS" != true ] && return
            webhook="$DISCORD_NOTIFICATIONS"
            color=$DISCORD_COLOR_SUCCESS
            ;;
        warning)
            webhook="$DISCORD_ALERTS"
            color=$DISCORD_COLOR_WARNING
            ;;
        error)
            [ "$NOTIFY_ON_FAILURE" != true ] && return
            webhook="$DISCORD_ALERTS"
            color=$DISCORD_COLOR_ERROR
            ;;
    esac

    [[ -z "$webhook" ]] && return

    # Truncate description to Discord limit
    if [ ${#description} -gt $DISCORD_DESC_LIMIT ]; then
        description="${description:0:$((DISCORD_DESC_LIMIT - 20))}…

*(truncated)*"
    fi

    # Build footer: hostname • script name • duration
    local footer="$FOOTER_PREFIX"
    [ -n "$SCRIPT_NAME" ] && footer="$footer • $SCRIPT_NAME"
    if [ -n "$START_TIME" ]; then
        local elapsed=$(( $(date +%s) - START_TIME ))
        footer="$footer • ${elapsed}s"
    fi

    local payload
    payload=$(jq -n \
        --arg title "$title" \
        --arg desc "$description" \
        --argjson color "$color" \
        --arg footer "$footer" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{embeds: [{title: $title, description: $desc, color: $color, footer: {text: $footer}, timestamp: $ts}]}')

    curl -s -H "Content-Type: application/json" -d "$payload" "$webhook" >/dev/null 2>&1
}
