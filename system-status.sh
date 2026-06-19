#!/bin/bash
# system-status.sh — Writes system stats to a JSON file for PiBoard
# Schedule: every 1 minute via crontab
# Output: ~/docker/piboard/data/system-status.json

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

DATA_DIR="$HOME/docker/piboard/data"
OUTPUT="$DATA_DIR/system-status.json"
mkdir -p "$DATA_DIR"

NOW=$(date +%s)

# --- Helper: check if cache is stale ---
cache_stale() {
    local file="$1" max_age="$2"
    [ ! -f "$file" ] && return 0
    [ $(( NOW - $(stat -c %Y "$file") )) -gt "$max_age" ] && return 0
    return 1
}

# ===== FAST DATA (every run) =====

# Memory (MB)
read -r mem_total mem_used mem_free mem_available <<< $(free -m | awk '/^Mem:/ {print $2, $3, $4, $7}')

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

# Network (ping)
net_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
net_gateway=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
net_gateway_ok="false"
net_internet_ms=""
if [ -n "$net_gateway" ]; then
    ping -c1 -W2 "$net_gateway" >/dev/null 2>&1 && net_gateway_ok="true"
fi
net_internet_ms=$(ping -c1 -W3 8.8.8.8 2>/dev/null | grep -oP 'time=\K[0-9.]+' || echo "")

# ===== MEDIUM DATA (every 5 minutes) =====

SERVICES_CACHE="$DATA_DIR/services.cache"

if cache_stale "$SERVICES_CACHE" 300; then
    # Disk: root
    read -r disk_root_total disk_root_used disk_root_free disk_root_pct <<< $(df -BG / | awk 'NR==2 {gsub("G",""); print $2, $3, $4, $5}')
    disk_root_pct="${disk_root_pct%\%}"

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

    # Last run times
    last_runs_json="[]"
    add_last_run() {
        local name="$1" ts="$2" duration="${3:-}"
        last_runs_json=$(echo "$last_runs_json" | jq --arg name "$name" --argjson ts "$ts" --arg duration "$duration" '. + [{"name": $name, "timestamp": $ts, "duration": $duration}]')
    }

    if [ -f "$KOMETA_CONFIG/logs/meta.log" ]; then
        ts=$(stat -c '%Y' "$KOMETA_CONFIG/logs/meta.log")
        dur=$(grep "Run Time:" "$KOMETA_CONFIG/logs/meta.log" | tail -1 | grep -oP 'Run Time: \K[0-9:]+')
        add_last_run "Kometa" "$ts" "${dur:-}"
    fi

    umtk_latest=$(ls -t "$UMTK_LOGS_DIR"/UMTK_*.log 2>/dev/null | head -1)
    if [ -n "$umtk_latest" ]; then
        ts=$(stat -c '%Y' "$umtk_latest")
        dur=$(grep "Total runtime:" "$umtk_latest" 2>/dev/null | tail -1 | grep -oP 'Total runtime: \K[0-9:]+')
        add_last_run "UMTK" "$ts" "${dur:-}"
    fi

    if [ -f "$IMAGEMAID_CONFIG_DIR/logs/imagemaid.log" ]; then
        ts=$(stat -c '%Y' "$IMAGEMAID_CONFIG_DIR/logs/imagemaid.log")
        add_last_run "ImageMaid" "$ts"
    fi

    pts_latest=$(ls -t "$LOG_DIR/plextraktsync"/plextraktsync_*.log 2>/dev/null | head -1)
    if [ -n "$pts_latest" ]; then
        ts=$(stat -c '%Y' "$pts_latest")
        add_last_run "PlexTraktSync" "$ts"
    fi

    # Plex server info
    PLEX_CACHE="$DATA_DIR/plex-info.cache"
    plex_json='{}'
    if cache_stale "$PLEX_CACHE" 300; then
        plex_data=$(curl -s --max-time 5 "$PLEX_URL/?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null)
        if [ -n "$plex_data" ]; then
            echo "$plex_data" | jq '{
                version: .MediaContainer.version,
                platform: .MediaContainer.platform,
                platform_version: .MediaContainer.platformVersion,
                transcoder_active: (.MediaContainer.transcoderActiveVideoSessions // 0)
            }' > "$PLEX_CACHE" 2>/dev/null
        fi
    fi
    [ -f "$PLEX_CACHE" ] && plex_json=$(cat "$PLEX_CACHE")

    # Write medium cache
    jq -n \
        --argjson disk_root_total "${disk_root_total:-0}" \
        --argjson disk_root_used "${disk_root_used:-0}" \
        --argjson disk_root_pct "${disk_root_pct:-0}" \
        --argjson services "$services_json" \
        --argjson containers "$containers_json" \
        --argjson last_runs "$last_runs_json" \
        --argjson plex "$plex_json" \
        '{disk_root: {total_gb: $disk_root_total, used_gb: $disk_root_used, percent: $disk_root_pct}, services: $services, containers: $containers, last_runs: $last_runs, plex: $plex}' \
        > "$SERVICES_CACHE"
fi

# Read medium cache
medium=$(cat "$SERVICES_CACHE")
disk_root_total=$(echo "$medium" | jq '.disk_root.total_gb')
disk_root_used=$(echo "$medium" | jq '.disk_root.used_gb')
disk_root_pct=$(echo "$medium" | jq '.disk_root.percent')
services_json=$(echo "$medium" | jq '.services')
containers_json=$(echo "$medium" | jq '.containers')
last_runs_json=$(echo "$medium" | jq '.last_runs')
plex_json=$(echo "$medium" | jq '.plex')

# ===== SLOW DATA (every hour) =====

REPORTS_CACHE="$DATA_DIR/reports.cache"

if cache_stale "$REPORTS_CACHE" 3600; then
    # Library stats
    library_json='{}'
    if [ -f "$REPORT_DIR/library-catalog.md" ]; then
        movies=$(grep '| Movies |' "$REPORT_DIR/library-catalog.md" | grep -oP '\| \K[0-9]+')
        shows=$(grep '| TV Shows |' "$REPORT_DIR/library-catalog.md" | grep -oP '\| \K[0-9]+')
        episodes=$(grep '| Episodes |' "$REPORT_DIR/library-catalog.md" | grep -oP '\| \K[0-9]+')
        library_json=$(jq -n --argjson movies "${movies:-0}" --argjson shows "${shows:-0}" --argjson episodes "${episodes:-0}" \
            '{movies: $movies, shows: $shows, episodes: $episodes}')
    fi

    # Metadata audit summary
    audit_json='{}'
    if [ -f "$REPORT_DIR/metadata-audit.md" ]; then
        audit_orphaned=$(awk -F'|' '/\| Orphaned \|/{gsub(/[^0-9]/,"",$3); print $3}' "$REPORT_DIR/metadata-audit.md" | head -1)
        audit_warnings=$(awk -F'|' '/\| Warnings \|/{gsub(/[^0-9]/,"",$3); print $3}' "$REPORT_DIR/metadata-audit.md" | head -1)
        audit_duplicates=$(awk -F'|' '/\| Duplicates \|/{gsub(/[^0-9]/,"",$3); print $3}' "$REPORT_DIR/metadata-audit.md" | head -1)
        audit_issues=$(awk -F'|' '/\| Issues \(errors\) \|/{gsub(/[^0-9]/,"",$3); print $3}' "$REPORT_DIR/metadata-audit.md" | head -1)
        audit_upcoming=$(awk -F'|' '/\| Upcoming/{gsub(/[^0-9]/,"",$3); print $3}' "$REPORT_DIR/metadata-audit.md" | head -1)
        audit_json=$(jq -n \
            --argjson orphaned "${audit_orphaned:-0}" \
            --argjson warnings "${audit_warnings:-0}" \
            --argjson duplicates "${audit_duplicates:-0}" \
            --argjson issues "${audit_issues:-0}" \
            --argjson upcoming "${audit_upcoming:-0}" \
            '{orphaned: $orphaned, warnings: $warnings, duplicates: $duplicates, issues: $issues, upcoming: $upcoming}')
    fi

    # Library breakdown
    breakdown_json='[]'
    codec_json='[]'
    if [ -f "$REPORT_DIR/storage-report.md" ]; then
        breakdown_json=$(awk '/^## Resolution Breakdown/,/^---$/' "$REPORT_DIR/storage-report.md" | grep '^|' | tail -n +3 | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if($2!="") printf "{\"resolution\":\"%s\",\"folders\":\"%s\",\"size\":\"%s\"}\n",$2,$3,$4}' | jq -s '.')
        codec_json=$(awk '/^## Codec Breakdown/,/^---$/' "$REPORT_DIR/storage-report.md" | grep '^|' | tail -n +3 | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if($2!="") printf "{\"codec\":\"%s\",\"folders\":\"%s\",\"size\":\"%s\"}\n",$2,$3,$4}' | jq -s '.')
    fi

    # Write report cache
    jq -n \
        --argjson library "$library_json" \
        --argjson audit "$audit_json" \
        --argjson resolution_breakdown "$breakdown_json" \
        --argjson codec_breakdown "${codec_json:-[]}" \
        '{library: $library, audit: $audit, resolution_breakdown: $resolution_breakdown, codec_breakdown: $codec_breakdown}' \
        > "$REPORTS_CACHE"
fi

# Read report cache
reports=$(cat "$REPORTS_CACHE")
library_json=$(echo "$reports" | jq '.library')
audit_json=$(echo "$reports" | jq '.audit')
breakdown_json=$(echo "$reports" | jq '.resolution_breakdown')
codec_json=$(echo "$reports" | jq '.codec_breakdown')

# ===== DAILY DATA =====

# Disk: media (cached daily to avoid waking drive)
MEDIA_CACHE="$DATA_DIR/media-disk.cache"
disk_media_total="0" disk_media_used="0" disk_media_pct="0"

if cache_stale "$MEDIA_CACHE" 86400; then
    MEDIA_MOUNT=$(dirname "$MOVIES_DIR")
    if mountpoint -q "$MEDIA_MOUNT" 2>/dev/null; then
        df -BG "$MEDIA_MOUNT" | awk 'NR==2 {gsub("G",""); print $2, $3, $4, $5}' > "$MEDIA_CACHE"
    fi
fi

if [ -f "$MEDIA_CACHE" ]; then
    read -r disk_media_total disk_media_used disk_media_free disk_media_pct < "$MEDIA_CACHE"
    disk_media_pct="${disk_media_pct%\%}"
fi

# Disk growth (append once per day)
GROWTH_FILE="$DATA_DIR/disk-growth.csv"
TODAY=$(date +%Y-%m-%d)

if [ ! -f "$GROWTH_FILE" ]; then
    echo "date,root_used_gb,media_used_gb" > "$GROWTH_FILE"
fi

if ! grep -q "^$TODAY," "$GROWTH_FILE" 2>/dev/null; then
    echo "$TODAY,${disk_root_used:-0},${disk_media_used:-0}" >> "$GROWTH_FILE"
fi

growth_json=$(tail -90 "$GROWTH_FILE" | grep -v "^date," | awk -F',' '{printf "{\"date\":\"%s\",\"root\":%s,\"media\":%s}\n", $1, $2, $3}' | jq -s '.')

# ===== WRITE FINAL JSON =====

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
    --argjson plex "$plex_json" \
    --argjson audit "$audit_json" \
    --argjson resolution_breakdown "$breakdown_json" \
    --argjson codec_breakdown "${codec_json:-[]}" \
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
        disk_growth: $disk_growth,
        plex: $plex,
        audit: $audit,
        resolution_breakdown: $resolution_breakdown,
        codec_breakdown: $codec_breakdown
    }' > "$OUTPUT"
