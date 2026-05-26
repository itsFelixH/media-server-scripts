#!/bin/bash
# config.sh — Shared configuration loader for all scripts
# Source this file at the top of any script:
#   SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPTS_DIR/config.sh"
#
# After sourcing, the following variables are available:
#
#   Server:     SERVER_HOSTNAME, SERVER_IP, SERVER_USER, SERVER_TIMEZONE
#   Plex:       PLEX_URL, PLEX_URL_DOCKER, PLEX_URL_KOMETA, PLEX_TOKEN
#   API Keys:   API_KEY_TMDB, API_KEY_MDBLIST, API_KEY_RADARR, API_KEY_SONARR, API_KEY_GITHUB_PAT
#   Trakt:      TRAKT_CLIENT_ID, TRAKT_CLIENT_SECRET
#   Discord:    DISCORD_ALERTS, DISCORD_NOTIFICATIONS, DISCORD_DESC_LIMIT, DISCORD_CONTENT_LIMIT
#   Paths:      KOMETA_CONFIG, SCRIPTS_DIR, LOG_DIR, REPORT_DIR, REPORTS_DIR, METADATA_DIR,
#               MOVIES_DIR, TV_DIR, BACKUP_DIR,
#               UMTK_CONFIG_DIR, UMTK_LOGS_DIR, IMAGEMAID_CONFIG_DIR, WTWP_DATA_DIR
#   Services:   PLEX_SERVICE, ARR_SERVICES (array), DOCKER_CONTAINERS (array)
#   Thresholds: THRESH_DISK_ROOT_WARN, THRESH_DISK_ROOT_CRITICAL, THRESH_DISK_MEDIA_CRITICAL,
#               THRESH_MEMORY_CRITICAL, THRESH_TEMP_CRITICAL, THRESH_TEMP_WARN,
#               THRESH_LOAD_MULTIPLIER, THRESH_CONTAINER_RESTART_WARN, THRESH_TASK_STALE_MIN
#   Retention:  RETENTION_LOGS_DAYS, RETENTION_UMTK_LOGS_DAYS, RETENTION_BACKUPS_DAYS,
#               RETENTION_PTS_DAYS
#   Defaults:   MEDIA_ANALYZER_DIR, MEDIA_ANALYZER_THRESHOLD_GB, MEDIA_ANALYZER_MIN_BITRATE,
#               ENCODE_QUEUE_DIR, ENCODE_QUEUE_LIMIT, ENCODE_QUEUE_MIN_SIZE_GB, ENCODE_QUEUE_HEVC_RATIO
#   Notify:     NOTIFY_ON_SUCCESS, NOTIFY_ON_FAILURE, FOOTER_PREFIX

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
SERVER_IP="$(_cfg server.ip)"
SERVER_USER="$(_cfg server.user)"
SERVER_TIMEZONE="$(_cfg server.timezone)"

# Plex
PLEX_URL="$(_cfg plex.url)"
PLEX_URL_DOCKER="$(_cfg plex.url_docker)"
PLEX_URL_KOMETA="$(_cfg plex.url_kometa)"
PLEX_TOKEN="$(_cfg plex.token)"

# API Keys
API_KEY_TMDB="$(_cfg api_keys.tmdb)"
API_KEY_MDBLIST="$(_cfg api_keys.mdblist)"
API_KEY_RADARR="$(_cfg api_keys.radarr)"
API_KEY_SONARR="$(_cfg api_keys.sonarr)"
API_KEY_GITHUB_PAT="$(_cfg api_keys.github_pat)"

# Trakt
TRAKT_CLIENT_ID="$(_cfg trakt.client_id)"
TRAKT_CLIENT_SECRET="$(_cfg trakt.client_secret)"

# Discord
DISCORD_ALERTS="$(_cfg discord.alerts)"
DISCORD_NOTIFICATIONS="$(_cfg discord.notifications)"
DISCORD_DESC_LIMIT="$(_cfg discord.description_limit 4000)"
DISCORD_CONTENT_LIMIT="$(_cfg discord.content_limit 1900)"

# Paths
KOMETA_CONFIG="$(_cfg paths.kometa_config)"
LOG_DIR="$(_cfg paths.logs)"
REPORT_DIR="$(_cfg paths.reports)"
REPORTS_DIR="$(_cfg paths.reports_archive)"
METADATA_DIR="$(_cfg paths.metadata)"
MOVIES_DIR="$(_cfg paths.movies)"
TV_DIR="$(_cfg paths.tv_shows)"
BACKUP_DIR="$(_cfg paths.backups)"
UMTK_CONFIG_DIR="$(_cfg paths.umtk_config)"
UMTK_LOGS_DIR="$(_cfg paths.umtk_logs)"
IMAGEMAID_CONFIG_DIR="$(_cfg paths.imagemaid_config)"
WTWP_DATA_DIR="$(_cfg paths.wtwp_data)"

# Services
PLEX_SERVICE="$(_cfg services.plex)"
mapfile -t ARR_SERVICES < <(_cfg_list services arr)
mapfile -t DOCKER_CONTAINERS < <(_cfg_list services docker_containers)

# Thresholds
THRESH_DISK_ROOT_WARN="$(_cfg thresholds.disk_root_warn 80)"
THRESH_DISK_ROOT_CRITICAL="$(_cfg thresholds.disk_root_critical 90)"
THRESH_DISK_MEDIA_CRITICAL="$(_cfg thresholds.disk_media_critical 95)"
THRESH_MEMORY_CRITICAL="$(_cfg thresholds.memory_critical 95)"
THRESH_TEMP_CRITICAL="$(_cfg thresholds.temperature_critical 80)"
THRESH_TEMP_WARN="$(_cfg thresholds.temperature_warn 70)"
THRESH_LOAD_MULTIPLIER="$(_cfg thresholds.load_multiplier 1)"
THRESH_CONTAINER_RESTART_WARN="$(_cfg thresholds.container_restart_warn 3)"
THRESH_TASK_STALE_MIN="$(_cfg thresholds.task_stale_minutes 1560)"

# Retention
RETENTION_LOGS_DAYS="$(_cfg retention.logs_days 30)"
RETENTION_UMTK_LOGS_DAYS="$(_cfg retention.umtk_logs_days 14)"
RETENTION_BACKUPS_DAYS="$(_cfg retention.backups_days 30)"
RETENTION_PTS_DAYS="$(_cfg retention.plextraktsync_days 14)"

# Notifications
NOTIFY_ON_SUCCESS="$(_cfg notifications.notify_on_success true)"
NOTIFY_ON_FAILURE="$(_cfg notifications.notify_on_failure true)"
FOOTER_PREFIX="$(_cfg notifications.footer_prefix bundepi)"

# Ensure log and report directories exist
mkdir -p "$LOG_DIR" "$REPORT_DIR"

# Media Analyzer defaults
MEDIA_ANALYZER_DIR="$(_cfg media_analyzer.default_directory "/mnt/Media/TV Shows")"
MEDIA_ANALYZER_THRESHOLD_GB="$(_cfg media_analyzer.threshold_gb 5)"
MEDIA_ANALYZER_MIN_BITRATE="$(_cfg media_analyzer.min_bitrate_kbps 1000)"

# Encode Queue defaults
ENCODE_QUEUE_DIR="$(_cfg encode_queue.default_directory "/mnt/Media/TV Shows")"
ENCODE_QUEUE_LIMIT="$(_cfg encode_queue.limit 50)"
ENCODE_QUEUE_MIN_SIZE_GB="$(_cfg encode_queue.min_size_gb 1)"
ENCODE_QUEUE_HEVC_RATIO="$(_cfg encode_queue.hevc_ratio 45)"
