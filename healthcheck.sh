#!/bin/bash
# Plex Media Server Stack - Health Check
# Runs silently, only sends Discord alerts on failures
# Schedule via crontab for automated monitoring

####### HELP #######
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat <<'HELP'
Health Check — Silent automated health check for the media server stack.

Usage: healthcheck.sh [-h|--help] [--no-discord]

Checks systemd services, Docker containers, disk/memory/temperature,
Plex connectivity, API endpoints, and scheduled task recency.

Features:
  - Auto-restarts Docker containers that are down
  - Suppresses repeated alerts for the same issue (no spam)
  - Sends a recovery notification when all issues are resolved

Options:
  -h, --help        Show this help message
  --no-discord      Skip Discord notifications

Only sends a Discord alert when issues are found.
Schedule: every 30 minutes via crontab
HELP
    exit 0
fi

NO_DISCORD=false
[[ "$1" == "--no-discord" || "$2" == "--no-discord" ]] && NO_DISCORD=true

####### CONFIGURATION #######
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

LOG_FILE="$LOG_DIR/healthcheck/healthcheck_$(date +%Y%m%d).log"
LAST_ALERT_FILE="$LOG_DIR/healthcheck/.healthcheck_last_alert"
mkdir -p "$LOG_DIR/healthcheck"

# Redirect all output to log file (append — only logs failures)
exec 2>> "$LOG_FILE"

ISSUES=()
PLEX_DOWN=false

SCRIPT_NAME="healthcheck.sh"

# Check systemd services
for service in "$PLEX_SERVICE" "${ARR_SERVICES[@]}"; do
    if ! systemctl is-active --quiet "$service" 2>/dev/null; then
        ISSUES+=("Service $service is down")
        [[ "$service" == "$PLEX_SERVICE" ]] && PLEX_DOWN=true
    fi
done

# Check Docker containers (auto-restart if down)
RESTARTED=()
for container in "${DOCKER_CONTAINERS[@]}"; do
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        # Attempt auto-restart via compose
        compose_dir="$HOME/docker/$container"
        if [ -f "$compose_dir/docker-compose.yml" ]; then
            echo "[$(date +%Y-%m-%d\ %H:%M)] AUTO-RESTART: attempting $container" >> "$LOG_FILE"
            docker compose -f "$compose_dir/docker-compose.yml" up -d >/dev/null 2>&1
            RESTARTED+=("$container")
        fi
    fi
done

# If any containers were restarted, wait and re-check
if [ ${#RESTARTED[@]} -gt 0 ]; then
    sleep 10
    for container in "${RESTARTED[@]}"; do
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
            echo "[$(date +%Y-%m-%d\ %H:%M)] AUTO-RESTART: $container recovered" >> "$LOG_FILE"
        else
            echo "[$(date +%Y-%m-%d\ %H:%M)] AUTO-RESTART: $container FAILED" >> "$LOG_FILE"
            ISSUES+=("Container $container is down (auto-restart failed)")
        fi
    done
fi

# Check Docker container health status
for container in "${DOCKER_CONTAINERS[@]}"; do
    health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null)
    if [[ "$health" == "unhealthy" ]]; then
        ISSUES+=("Container $container is unhealthy")
    fi
done

# Check Docker container restart counts (>threshold restarts suggests instability)
for container in "${DOCKER_CONTAINERS[@]}"; do
    restarts=$(docker inspect --format='{{.RestartCount}}' "$container" 2>/dev/null)
    if [ -n "$restarts" ] && [ "$restarts" -gt "$THRESH_CONTAINER_RESTART_WARN" ]; then
        ISSUES+=("Container $container has restarted $restarts times")
    fi
done

# Check disk space (root)
disk_usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$disk_usage" -gt "$THRESH_DISK_ROOT_CRITICAL" ]; then
    ISSUES+=("Root disk at ${disk_usage}%")
fi

# Check disk space (media drive)
MEDIA_MOUNT=$(dirname "$MOVIES_DIR")
if mountpoint -q "$MEDIA_MOUNT" 2>/dev/null; then
    media_usage=$(df "$MEDIA_MOUNT" | awk 'NR==2 {print $5}' | tr -d '%')
    if [ "$media_usage" -gt "$THRESH_DISK_MEDIA_CRITICAL" ]; then
        ISSUES+=("Media drive at ${media_usage}%")
    fi
else
    ISSUES+=("Media drive $MEDIA_MOUNT not mounted")
fi

# Check memory
mem_pct=$(free | awk '/Mem:/ {printf "%.0f", ($3/$2)*100}')
if [ "$mem_pct" -gt "$THRESH_MEMORY_CRITICAL" ]; then
    ISSUES+=("Memory at ${mem_pct}%")
fi

# Check swap usage (high swap on Pi = early OOM warning)
swap_total=$(free | awk '/Swap:/ {print $2}')
if [ "$swap_total" -gt 0 ]; then
    swap_pct=$(free | awk '/Swap:/ {printf "%.0f", ($3/$2)*100}')
    if [ "$swap_pct" -gt 80 ]; then
        ISSUES+=("Swap at ${swap_pct}% (OOM risk)")
    fi
fi

# Check temperature
for thermal in /sys/class/thermal/thermal_zone*/temp; do
    if [ -r "$thermal" ]; then
        temp_c=$(( $(cat "$thermal") / 1000 ))
        if [ "$temp_c" -gt "$THRESH_TEMP_CRITICAL" ]; then
            ISSUES+=("CPU temperature at ${temp_c}°C")
        fi
    fi
done

# Check Plex connectivity (skip remaining Plex checks if service is already down)
if [ "$PLEX_DOWN" = false ]; then
    if ! curl -s --max-time 5 -o /dev/null "$PLEX_URL/identity"; then
        ISSUES+=("Plex not responding at $PLEX_URL")
        PLEX_DOWN=true
    fi
fi

# Check Plex token validity (only if Plex is reachable)
if [ "$PLEX_DOWN" = false ] && [ -n "$PLEX_TOKEN" ]; then
    plex_resp=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$PLEX_URL/library/sections?X-Plex-Token=$PLEX_TOKEN")
    if [ "$plex_resp" == "401" ]; then
        ISSUES+=("Plex token is invalid (401 Unauthorized)")
    fi
fi

# Check Radarr API (only if service isn't already flagged as down)
if [ -n "$API_KEY_RADARR" ]; then
    radarr_down=false
    for issue in "${ISSUES[@]}"; do
        [[ "$issue" == *"radarr"* ]] && radarr_down=true && break
    done
    if [ "$radarr_down" = false ]; then
        radarr_resp=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "http://localhost:7878/api/v3/system/status?apikey=$API_KEY_RADARR")
        if [ "$radarr_resp" != "200" ]; then
            ISSUES+=("Radarr API not responding (HTTP $radarr_resp)")
        fi
    fi
fi

# Check Sonarr API (only if service isn't already flagged as down)
if [ -n "$API_KEY_SONARR" ]; then
    sonarr_down=false
    for issue in "${ISSUES[@]}"; do
        [[ "$issue" == *"sonarr"* ]] && sonarr_down=true && break
    done
    if [ "$sonarr_down" = false ]; then
        sonarr_resp=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "http://localhost:8989/api/v3/system/status?apikey=$API_KEY_SONARR")
        if [ "$sonarr_resp" != "200" ]; then
            ISSUES+=("Sonarr API not responding (HTTP $sonarr_resp)")
        fi
    fi
fi

# Check internet connectivity
if ! ping -c1 -W5 8.8.8.8 >/dev/null 2>&1; then
    ISSUES+=("No internet connectivity")
elif ! curl -s --max-time 5 -o /dev/null "https://api.themoviedb.org"; then
    ISSUES+=("TMDb API unreachable (internet may be degraded)")
fi

# Check UMTK last run (should have run within threshold)
latest_umtk=$(find "$UMTK_LOGS_DIR" -name "UMTK_*.log" -mmin -$THRESH_TASK_STALE_MIN 2>/dev/null | head -1)
if [ -z "$latest_umtk" ]; then
    ISSUES+=("UMTK has not run in over 26 hours")
fi

# Check Kometa last run (should have run within threshold)
if [ -f "$KOMETA_CONFIG/logs/meta.log" ]; then
    kometa_age=$(find "$KOMETA_CONFIG/logs/meta.log" -mmin -$THRESH_TASK_STALE_MIN 2>/dev/null | head -1)
    if [ -z "$kometa_age" ]; then
        ISSUES+=("Kometa has not run in over 26 hours")
    fi
else
    ISSUES+=("Kometa log file not found")
fi

# Check PlexTraktSync last run (should have run within threshold)
pts_today="$LOG_DIR/plextraktsync/plextraktsync_$(date +%Y%m%d).log"
if [ -f "$pts_today" ]; then
    pts_age=$(find "$pts_today" -mmin -$THRESH_TASK_STALE_MIN 2>/dev/null | head -1)
    if [ -z "$pts_age" ]; then
        ISSUES+=("PlexTraktSync has not run in over 26 hours")
    fi
else
    # Check if any recent log exists in the PTS directory
    pts_latest=$(find "$LOG_DIR/plextraktsync" -type f -name "*.log" -mmin -$THRESH_TASK_STALE_MIN 2>/dev/null | head -1)
    if [ -z "$pts_latest" ]; then
        ISSUES+=("PlexTraktSync has not run in over 26 hours")
    fi
fi

# --- Report results ---

# Build current issues fingerprint (sorted, one per line)
CURRENT_FINGERPRINT=$(printf '%s\n' "${ISSUES[@]}" | sort)

# Load previous alert fingerprint
PREV_FINGERPRINT=""
[ -f "$LAST_ALERT_FILE" ] && PREV_FINGERPRINT=$(cat "$LAST_ALERT_FILE")

if [ ${#ISSUES[@]} -gt 0 ]; then
    # Only alert if issues changed (prevents repeated alerts for same problem)
    if [ "$CURRENT_FINGERPRINT" != "$PREV_FINGERPRINT" ]; then
        desc=""
        for issue in "${ISSUES[@]}"; do
            desc+="• $issue"$'\n'
        done
        # Build a short summary for the title (e.g. "sonarr, disk, temp")
        title_summary=$(printf '%s\n' "${ISSUES[@]}" | sed 's/Service \([^ ]*\).*/\1/; s/Container \([^ ]*\).*/\1/; s/.*disk.*/disk/i; s/.*memory.*/memory/i; s/.*temperature.*/temp/i; s/.*has not run.*/stale task/i' | sort -u | paste -sd', ')
        discord_notify "error" "❌ Health Check — $title_summary" "$desc"
    fi
    # Save current issues
    printf '%s' "$CURRENT_FINGERPRINT" > "$LAST_ALERT_FILE"
    # Log failure
    echo "[$(date +%Y-%m-%d\ %H:%M)] FAIL (${#ISSUES[@]} issues): $(IFS=', '; echo "${ISSUES[*]}")" >> "$LOG_FILE"
    exit 1
fi

# All clear — check if we're recovering from a previous failure
if [ -n "$PREV_FINGERPRINT" ]; then
    desc=""
    while IFS= read -r prev_issue; do
        [ -n "$prev_issue" ] && desc+="• ~~$prev_issue~~"$'\n'
    done <<< "$PREV_FINGERPRINT"
    discord_notify "success" "✅ All Issues Resolved" "$desc"
    rm -f "$LAST_ALERT_FILE"
fi

# Healthy — single heartbeat line
echo "[$(date +%Y-%m-%d\ %H:%M)] OK" >> "$LOG_FILE"
exit 0
