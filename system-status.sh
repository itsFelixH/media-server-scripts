#!/bin/bash
# system-status.sh — Writes system stats to a JSON file for PiBoard
# Schedule: every 1 minute via crontab
# Output: ~/kometa/scripts/reports/system-status.json

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

OUTPUT="$REPORT_DIR/system-status.json"

# --- Collect data ---

# Memory (MB)
read -r mem_total mem_used mem_free mem_available <<< $(free -m | awk '/^Mem:/ {print $2, $3, $4, $7}')

# Disk: root
read -r disk_root_total disk_root_used disk_root_free disk_root_pct <<< $(df -BG / | awk 'NR==2 {gsub("G",""); print $2, $3, $4, $5}')
disk_root_pct="${disk_root_pct%\%}"

# Disk: media (cached — only refreshed once per day to avoid waking the drive)
MEDIA_MOUNT=$(dirname "$MOVIES_DIR")
MEDIA_CACHE="$REPORT_DIR/.media-disk-cache"
disk_media_total="" disk_media_used="" disk_media_free="" disk_media_pct=""

# Refresh cache if it doesn't exist or is older than 24 hours
if [ ! -f "$MEDIA_CACHE" ] || [ $(( $(date +%s) - $(stat -c %Y "$MEDIA_CACHE") )) -gt 86400 ]; then
    if mountpoint -q "$MEDIA_MOUNT" 2>/dev/null; then
        df -BG "$MEDIA_MOUNT" | awk 'NR==2 {gsub("G",""); print $2, $3, $4, $5}' > "$MEDIA_CACHE"
    fi
fi

if [ -f "$MEDIA_CACHE" ]; then
    read -r disk_media_total disk_media_used disk_media_free disk_media_pct < "$MEDIA_CACHE"
    disk_media_pct="${disk_media_pct%\%}"
fi

# CPU temperature
cpu_temp=""
for thermal in /sys/class/thermal/thermal_zone*/temp; do
    if [ -r "$thermal" ]; then
        cpu_temp=$(( $(cat "$thermal") / 1000 ))
        break
    fi
done

# Uptime
uptime_str=$(uptime -p | sed 's/^up //')

# Services (systemd)
services_json="[]"
all_services=("$PLEX_SERVICE" "${ARR_SERVICES[@]}")
for svc in "${all_services[@]}"; do
    status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    services_json=$(echo "$services_json" | jq --arg name "$svc" --arg status "$status" '. + [{"name": $name, "status": $status}]')
done

# Docker containers
containers_json="[]"
for ctr in "${DOCKER_CONTAINERS[@]}" piboard; do
    status=$(docker inspect --format='{{.State.Status}}' "$ctr" 2>/dev/null || echo "not found")
    health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$ctr" 2>/dev/null || echo "unknown")
    containers_json=$(echo "$containers_json" | jq --arg name "$ctr" --arg status "$status" --arg health "$health" '. + [{"name": $name, "status": $status, "health": $health}]')
done

# --- Library stats (from catalog report, no disk access) ---
library_json='{}'
if [ -f "$REPORT_DIR/library-catalog.md" ]; then
    movies=$(grep '| Movies |' "$REPORT_DIR/library-catalog.md" | grep -oP '\| \K[0-9]+')
    shows=$(grep '| TV Shows |' "$REPORT_DIR/library-catalog.md" | grep -oP '\| \K[0-9]+')
    episodes=$(grep '| Episodes |' "$REPORT_DIR/library-catalog.md" | grep -oP '\| \K[0-9]+')
    library_json=$(jq -n --argjson movies "${movies:-0}" --argjson shows "${shows:-0}" --argjson episodes "${episodes:-0}" \
        '{movies: $movies, shows: $shows, episodes: $episodes}')
fi

# --- Last run times ---
last_runs_json="[]"

# Kometa — meta.log modification time + run duration
kometa_duration=""
if [ -f "$KOMETA_CONFIG/logs/meta.log" ]; then
    ts=$(stat -c '%Y' "$KOMETA_CONFIG/logs/meta.log")
    kometa_duration=$(grep "Run Time:" "$KOMETA_CONFIG/logs/meta.log" | tail -1 | grep -oP 'Run Time: \K[0-9:]+')
    last_runs_json=$(echo "$last_runs_json" | jq --arg name "Kometa" --argjson ts "$ts" --arg duration "${kometa_duration:-}" '. + [{"name": $name, "timestamp": $ts, "duration": $duration}]')
fi

# UMTK — latest log file
umtk_latest=$(ls -t "$UMTK_LOGS_DIR"/UMTK_*.log 2>/dev/null | head -1)
if [ -n "$umtk_latest" ]; then
    ts=$(stat -c '%Y' "$umtk_latest")
    last_runs_json=$(echo "$last_runs_json" | jq --arg name "UMTK" --argjson ts "$ts" '. + [{"name": $name, "timestamp": $ts}]')
fi

# ImageMaid — imagemaid.log modification time
if [ -f "$IMAGEMAID_CONFIG_DIR/logs/imagemaid.log" ]; then
    ts=$(stat -c '%Y' "$IMAGEMAID_CONFIG_DIR/logs/imagemaid.log")
    last_runs_json=$(echo "$last_runs_json" | jq --arg name "ImageMaid" --argjson ts "$ts" '. + [{"name": $name, "timestamp": $ts}]')
fi

# PlexTraktSync — latest log
pts_latest=$(ls -t "$LOG_DIR/plextraktsync"/plextraktsync_*.log 2>/dev/null | head -1)
if [ -n "$pts_latest" ]; then
    ts=$(stat -c '%Y' "$pts_latest")
    last_runs_json=$(echo "$last_runs_json" | jq --arg name "PlexTraktSync" --argjson ts "$ts" '. + [{"name": $name, "timestamp": $ts}]')
fi

# --- Network status ---
net_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
net_gateway=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
net_gateway_ok="false"
net_internet_ms=""

if [ -n "$net_gateway" ]; then
    ping -c1 -W2 "$net_gateway" >/dev/null 2>&1 && net_gateway_ok="true"
fi

# Internet latency (single ping to 8.8.8.8)
net_internet_ms=$(ping -c1 -W3 8.8.8.8 2>/dev/null | grep -oP 'time=\K[0-9.]+' || echo "")

# --- Disk growth tracking (append once per day) ---
GROWTH_FILE="$REPORT_DIR/.disk-growth.csv"
TODAY=$(date +%Y-%m-%d)

# Create header if file doesn't exist
if [ ! -f "$GROWTH_FILE" ]; then
    echo "date,root_used_gb,media_used_gb" > "$GROWTH_FILE"
fi

# Only append if we haven't logged today
if ! grep -q "^$TODAY," "$GROWTH_FILE" 2>/dev/null; then
    echo "$TODAY,${disk_root_used:-0},${disk_media_used:-0}" >> "$GROWTH_FILE"
fi

# Read last 90 days for the JSON output
growth_json="[]"
if [ -f "$GROWTH_FILE" ]; then
    growth_json=$(tail -90 "$GROWTH_FILE" | grep -v "^date," | awk -F',' '{printf "{\"date\":\"%s\",\"root\":%s,\"media\":%s}\n", $1, $2, $3}' | jq -s '.')
fi

# --- Write JSON ---

jq -n \
    --arg timestamp "$(date -Iseconds)" \
    --argjson mem_total "$mem_total" \
    --argjson mem_used "$mem_used" \
    --argjson mem_available "${mem_available:-0}" \
    --argjson disk_root_total "${disk_root_total:-0}" \
    --argjson disk_root_used "${disk_root_used:-0}" \
    --argjson disk_root_pct "${disk_root_pct:-0}" \
    --argjson disk_media_total "${disk_media_total:-0}" \
    --argjson disk_media_used "${disk_media_used:-0}" \
    --argjson disk_media_pct "${disk_media_pct:-0}" \
    --argjson cpu_temp "${cpu_temp:-0}" \
    --arg uptime "$uptime_str" \
    --argjson services "$services_json" \
    --argjson containers "$containers_json" \
    --argjson last_runs "$last_runs_json" \
    --argjson library "$library_json" \
    --arg net_ip "${net_ip:-}" \
    --arg net_gateway "${net_gateway:-}" \
    --argjson net_gateway_ok "$net_gateway_ok" \
    --arg net_internet_ms "${net_internet_ms:-}" \
    --argjson disk_growth "$growth_json" \
    '{
        timestamp: $timestamp,
        memory: { total_mb: $mem_total, used_mb: $mem_used, available_mb: $mem_available },
        disk: {
            root: { total_gb: $disk_root_total, used_gb: $disk_root_used, percent: $disk_root_pct },
            media: { total_gb: $disk_media_total, used_gb: $disk_media_used, percent: $disk_media_pct }
        },
        cpu_temp_c: $cpu_temp,
        uptime: $uptime,
        services: $services,
        containers: $containers,
        last_runs: $last_runs,
        library: $library,
        network: { ip: $net_ip, gateway: $net_gateway, gateway_ok: $net_gateway_ok, internet_ms: $net_internet_ms },
        disk_growth: $disk_growth
    }' > "$OUTPUT"
