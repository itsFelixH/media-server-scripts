#!/bin/bash
# system-status.sh — Writes system stats to a JSON file for PiBoard
# Schedule: every 1 minute via crontab
# Output: ~/docker/piboard/data/system-status.json
#
# Caching strategy:
#   Fast (every run):   memory, cpu temp, uptime, network
#   Medium (5 min):     root disk, services, containers, last runs, plex
#   Slow (1 hour):      library stats, audit, resolution/codec breakdown
#   Daily:              media disk, growth CSV

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

read -r mem_total mem_used mem_free mem_available <<< $(free -m | awk '/^Mem:/ {print $2, $3, $4, $7}')

cpu_temp=0
for thermal in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$thermal" ] && cpu_temp=$(( $(cat "$thermal") / 1000 )) && break
done

uptime_str=$(uptime -p | sed 's/^up //')

net_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
net_gateway=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
net_gateway_ok="false"
net_internet_ms=""
[ -n "$net_gateway" ] && ping -c1 -W2 "$net_gateway" >/dev/null 2>&1 && net_gateway_ok="true"
net_internet_ms=$(ping -c1 -W3 8.8.8.8 2>/dev/null | grep -oP 'time=\K[0-9.]+' || echo "")

# ===== MEDIUM DATA (every 5 minutes) =====

SERVICES_CACHE="$DATA_DIR/services.cache"

if cache_stale "$SERVICES_CACHE" 300; then
    # Root disk
    read -r _drT _drU _drF _drP <<< $(df -BG / | awk 'NR==2 {gsub("G",""); print $2, $3, $4, $5}')
    _drP="${_drP%\%}"

    # Services
    _svc_json="[]"
    for svc in "$PLEX_SERVICE" "${ARR_SERVICES[@]}"; do
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        _svc_json=$(echo "$_svc_json" | jq --arg n "$svc" --arg s "$status" '. + [{"name":$n,"status":$s}]')
    done

    # Containers
    _ctr_json="[]"
    for ctr in "${DOCKER_CONTAINERS[@]}" piboard; do
        status=$(docker inspect --format='{{.State.Status}}' "$ctr" 2>/dev/null || echo "not found")
        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$ctr" 2>/dev/null || echo "unknown")
        _ctr_json=$(echo "$_ctr_json" | jq --arg n "$ctr" --arg s "$status" --arg h "$health" '. + [{"name":$n,"status":$s,"health":$h}]')
    done

    # Last runs
    _lr_json="[]"
    _add_lr() {
        _lr_json=$(echo "$_lr_json" | jq --arg n "$1" --argjson t "$2" --arg d "${3:-}" '. + [{"name":$n,"timestamp":$t,"duration":$d}]')
    }
    [ -f "$KOMETA_CONFIG/logs/meta.log" ] && {
        _t=$(stat -c '%Y' "$KOMETA_CONFIG/logs/meta.log")
        _d=$(grep "Run Time:" "$KOMETA_CONFIG/logs/meta.log" | tail -1 | grep -oP 'Run Time: \K[0-9:]+')
        _add_lr "Kometa" "$_t" "${_d:-}"
    }
    _ul=$(ls -t "$UMTK_LOGS_DIR"/UMTK_*.log 2>/dev/null | head -1)
    [ -n "$_ul" ] && {
        _t=$(stat -c '%Y' "$_ul")
        _d=$(grep "Total runtime:" "$_ul" 2>/dev/null | tail -1 | grep -oP 'Total runtime: \K[0-9:]+')
        _add_lr "UMTK" "$_t" "${_d:-}"
    }
    [ -f "$IMAGEMAID_CONFIG_DIR/logs/imagemaid.log" ] && {
        _t=$(stat -c '%Y' "$IMAGEMAID_CONFIG_DIR/logs/imagemaid.log")
        _add_lr "ImageMaid" "$_t"
    }
    _pl=$(ls -t "$LOG_DIR/plextraktsync"/plextraktsync_*.log 2>/dev/null | head -1)
    [ -n "$_pl" ] && {
        _t=$(stat -c '%Y' "$_pl")
        _add_lr "PlexTraktSync" "$_t"
    }

    # Plex API
    PLEX_CACHE="$DATA_DIR/plex-info.cache"
    _plex_json='{}'
    if cache_stale "$PLEX_CACHE" 300; then
        _pd=$(curl -s --max-time 5 "$PLEX_URL/?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null)
        [ -n "$_pd" ] && _plex_json=$(echo "$_pd" | jq '{version:.MediaContainer.version,platform:.MediaContainer.platform,platform_version:.MediaContainer.platformVersion,transcoder_active:(.MediaContainer.transcoderActiveVideoSessions // 0)}' 2>/dev/null)
        [ "$_plex_json" != "null" ] && [ -n "$_plex_json" ] || _plex_json='{}'
        echo "$_plex_json" > "$PLEX_CACHE"
    else
        _plex_json=$(cat "$PLEX_CACHE")
    fi

    # Write shell-sourceable cache
    cat > "$SERVICES_CACHE" <<CACHE
disk_root_total=${_drT:-0}
disk_root_used=${_drU:-0}
disk_root_pct=${_drP:-0}
services_json='$_svc_json'
containers_json='$_ctr_json'
last_runs_json='$_lr_json'
plex_json='$_plex_json'
CACHE
fi

# Source medium cache (instant — no jq)
source "$SERVICES_CACHE"

# ===== SLOW DATA (every hour) =====

REPORTS_CACHE="$DATA_DIR/reports.cache"

if cache_stale "$REPORTS_CACHE" 3600; then
    # Library stats
    _lib_json='{}'
    if [ -f "$REPORT_DIR/library-catalog.md" ]; then
        _m=$(grep '| Movies |' "$REPORT_DIR/library-catalog.md" | grep -oP '\| \K[0-9]+')
        _s=$(grep '| TV Shows |' "$REPORT_DIR/library-catalog.md" | grep -oP '\| \K[0-9]+')
        _e=$(grep '| Episodes |' "$REPORT_DIR/library-catalog.md" | grep -oP '\| \K[0-9]+')
        _lib_json=$(jq -n --argjson m "${_m:-0}" --argjson s "${_s:-0}" --argjson e "${_e:-0}" '{movies:$m,shows:$s,episodes:$e}')
    fi

    # Audit
    _aud_json='{}'
    if [ -f "$REPORT_DIR/metadata-audit.md" ]; then
        _ao=$(awk -F'|' '/\| Orphaned \|/{gsub(/[^0-9]/,"",$3); print $3}' "$REPORT_DIR/metadata-audit.md" | head -1)
        _aw=$(awk -F'|' '/\| Warnings \|/{gsub(/[^0-9]/,"",$3); print $3}' "$REPORT_DIR/metadata-audit.md" | head -1)
        _ad=$(awk -F'|' '/\| Duplicates \|/{gsub(/[^0-9]/,"",$3); print $3}' "$REPORT_DIR/metadata-audit.md" | head -1)
        _ai=$(awk -F'|' '/\| Issues \(errors\) \|/{gsub(/[^0-9]/,"",$3); print $3}' "$REPORT_DIR/metadata-audit.md" | head -1)
        _au=$(awk -F'|' '/\| Upcoming/{gsub(/[^0-9]/,"",$3); print $3}' "$REPORT_DIR/metadata-audit.md" | head -1)
        _pw=$(awk '/Comparison/,0' "$REPORT_DIR/metadata-audit.md" | awk -F'|' '/Warnings/{gsub(/[^0-9]/,"",$3); print $3}')
        _pi=$(awk '/Comparison/,0' "$REPORT_DIR/metadata-audit.md" | awk -F'|' '/Issues/{gsub(/[^0-9]/,"",$3); print $3}')
        _pd=$(awk '/Comparison/,0' "$REPORT_DIR/metadata-audit.md" | awk -F'|' '/Duplicates/{gsub(/[^0-9]/,"",$3); print $3}')
        _aud_json=$(jq -n --argjson o "${_ao:-0}" --argjson w "${_aw:-0}" --argjson d "${_ad:-0}" --argjson i "${_ai:-0}" --argjson u "${_au:-0}" --argjson pw "${_pw:-0}" --argjson pi "${_pi:-0}" --argjson pd "${_pd:-0}" '{orphaned:$o,warnings:$w,duplicates:$d,issues:$i,upcoming:$u,prev_warnings:$pw,prev_issues:$pi,prev_duplicates:$pd}')
    fi

    # Breakdown
    _res_json='[]'
    _cod_json='[]'
    _res_movies_json='[]'
    _cod_movies_json='[]'
    if [ -f "$REPORT_DIR/storage-report.md" ]; then
        # TV breakdown (first occurrence)
        _res_json=$(awk '/^# TV Shows/,/^# Movies/' "$REPORT_DIR/storage-report.md" | awk '/^## Resolution Breakdown/,/^---$/' | grep '^|' | tail -n +3 | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if($2!="") printf "{\"resolution\":\"%s\",\"folders\":\"%s\",\"size\":\"%s\"}\n",$2,$3,$4}' | jq -s '.' 2>/dev/null || echo '[]')
        _cod_json=$(awk '/^# TV Shows/,/^# Movies/' "$REPORT_DIR/storage-report.md" | awk '/^## Codec Breakdown/,/^---$/' | grep '^|' | tail -n +3 | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if($2!="") printf "{\"codec\":\"%s\",\"folders\":\"%s\",\"size\":\"%s\"}\n",$2,$3,$4}' | jq -s '.' 2>/dev/null || echo '[]')
        # Movies breakdown (after "# Movies")
        _res_movies_json=$(awk '/^# Movies/,0' "$REPORT_DIR/storage-report.md" | awk '/^## Resolution Breakdown/,/^---$/' | grep '^|' | tail -n +3 | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if($2!="") printf "{\"resolution\":\"%s\",\"folders\":\"%s\",\"size\":\"%s\"}\n",$2,$3,$4}' | jq -s '.' 2>/dev/null || echo '[]')
        _cod_movies_json=$(awk '/^# Movies/,0' "$REPORT_DIR/storage-report.md" | awk '/^## Codec Breakdown/,/^---$/' | grep '^|' | tail -n +3 | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if($2!="") printf "{\"codec\":\"%s\",\"folders\":\"%s\",\"size\":\"%s\"}\n",$2,$3,$4}' | jq -s '.' 2>/dev/null || echo '[]')
        # Fallback: if no "# TV Shows" header (old single-library format), read directly
        [ "$_res_json" = "[]" ] && _res_json=$(awk '/^## Resolution Breakdown/,/^---$/' "$REPORT_DIR/storage-report.md" | grep '^|' | tail -n +3 | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if($2!="") printf "{\"resolution\":\"%s\",\"folders\":\"%s\",\"size\":\"%s\"}\n",$2,$3,$4}' | jq -s '.')
        [ "$_cod_json" = "[]" ] && _cod_json=$(awk '/^## Codec Breakdown/,/^---$/' "$REPORT_DIR/storage-report.md" | grep '^|' | tail -n +3 | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if($2!="") printf "{\"codec\":\"%s\",\"folders\":\"%s\",\"size\":\"%s\"}\n",$2,$3,$4}' | jq -s '.')
    fi

    # Upcoming + Recently Watched (TMDb posters, cached daily)
    TMDB_KEY="6d32d887bcfd246d796970654c83b804"
    _content_hash=$(echo "$(date +%Y-%m-%d)" | md5sum | awk '{print $1}')
    _cached_hash=""
    [ -f "$DATA_DIR/content-hash" ] && _cached_hash=$(cat "$DATA_DIR/content-hash")

    if [ "$_content_hash" != "$_cached_hash" ] || [ ! -f "$DATA_DIR/upcoming.cache" ]; then
        # Helper: get TMDb poster URL for a Plex ratingKey
        _get_poster() {
            local rkey="$1" mtype="$2"
            local tmdb_id poster
            tmdb_id=$(curl -s --max-time 5 "$PLEX_URL/library/metadata/$rkey?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[0].Guid[]?.id' | grep "tmdb://" | sed 's|tmdb://||')
            [ -z "$tmdb_id" ] && return
            poster=$(curl -s --max-time 5 "https://api.themoviedb.org/3/${mtype}/${tmdb_id}?api_key=$TMDB_KEY" 2>/dev/null | jq -r '.poster_path // empty')
            [ -n "$poster" ] && echo "https://image.tmdb.org/t/p/w200${poster}"
        }

        # Upcoming Movies
        _upcoming_json="[]"
        _mov_col=$(curl -s --max-time 5 "$PLEX_URL/library/sections/4/collections?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | select(.title | contains("Coming Soon")) | .ratingKey')
        [ -n "$_mov_col" ] && while IFS=$'\t' read -r title year rkey; do
            [ -z "$rkey" ] && continue
            p=$(_get_poster "$rkey" "movie")
            _upcoming_json=$(echo "$_upcoming_json" | jq --arg n "$title ($year)" --arg p "${p:-}" --arg t "movie" '. + [{name:$n,poster:$p,type:$t}]')
        done < <(curl -s --max-time 5 "$PLEX_URL/library/collections/$_mov_col/children?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | "\(.title)\t\(.year)\t\(.ratingKey)"')

        # Upcoming TV
        _tv_col=$(curl -s --max-time 5 "$PLEX_URL/library/sections/5/collections?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | select(.title | contains("Coming Soon")) | .ratingKey')
        [ -n "$_tv_col" ] && while IFS=$'\t' read -r title rkey; do
            [ -z "$rkey" ] && continue
            p=$(_get_poster "$rkey" "tv")
            _upcoming_json=$(echo "$_upcoming_json" | jq --arg n "$title" --arg p "${p:-}" --arg t "tv" '. + [{name:$n,poster:$p,type:$t}]')
        done < <(curl -s --max-time 5 "$PLEX_URL/library/collections/$_tv_col/children?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | "\(.title)\t\(.ratingKey)"')
        echo "$_upcoming_json" > "$DATA_DIR/upcoming.cache"

        # Recently Watched
        _recent_json="[]"
        _seen=""
        while IFS=$'\t' read -r title type gp_title rkey; do
            [ -z "$rkey" ] && continue
            if [ "$type" = "episode" ]; then
                gp_rkey=$(curl -s --max-time 3 "$PLEX_URL/library/metadata/$rkey?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[0].grandparentRatingKey // empty')
                [ -z "$gp_rkey" ] && continue
                echo "$_seen" | grep -q "$gp_rkey" && continue
                _seen="$_seen $gp_rkey"
                p=$(_get_poster "$gp_rkey" "tv")
                _recent_json=$(echo "$_recent_json" | jq --arg n "$gp_title" --arg p "${p:-}" --arg t "tv" '. + [{name:$n,poster:$p,type:$t}]')
            else
                p=$(_get_poster "$rkey" "movie")
                _recent_json=$(echo "$_recent_json" | jq --arg n "$title" --arg p "${p:-}" --arg t "movie" '. + [{name:$n,poster:$p,type:$t}]')
            fi
        done < <(curl -s --max-time 5 "$PLEX_URL/status/sessions/history/all?X-Plex-Token=$PLEX_TOKEN&sort=viewedAt:desc&limit=30" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | "\(.title)\t\(.type)\t\(.grandparentTitle // "")\t\(.ratingKey)"')
        echo "$_recent_json" > "$DATA_DIR/recent.cache"

        echo "$_content_hash" > "$DATA_DIR/content-hash"
    fi

    # Write shell-sourceable cache
    # Get total sizes for breakdown headers
    _tv_size=""
    _mov_size=""
    if [ -f "$REPORT_DIR/storage-report.md" ]; then
        _tv_size=$(awk '/^# TV Shows/,/^# Movies/' "$REPORT_DIR/storage-report.md" | grep "Total size" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
        _mov_size=$(awk '/^# Movies/,0' "$REPORT_DIR/storage-report.md" | grep "Total size" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
        # Fallback for old single-library format
        [ -z "$_tv_size" ] && _tv_size=$(grep "Total size" "$REPORT_DIR/storage-report.md" | head -1 | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
    fi

    cat > "$REPORTS_CACHE" <<CACHE
library_json='$_lib_json'
audit_json='$_aud_json'
breakdown_json='$_res_json'
codec_json='$_cod_json'
breakdown_movies_json='$_res_movies_json'
codec_movies_json='$_cod_movies_json'
tv_total_size='$_tv_size'
movies_total_size='$_mov_size'
CACHE
fi

# Source report cache (instant)
source "$REPORTS_CACHE"

# ===== DAILY DATA =====

# Media disk
MEDIA_CACHE="$DATA_DIR/media-disk.cache"
disk_media_total=0 disk_media_used=0 disk_media_pct=0

if cache_stale "$MEDIA_CACHE" 86400; then
    MEDIA_MOUNT=$(dirname "$MOVIES_DIR")
    if mountpoint -q "$MEDIA_MOUNT" 2>/dev/null; then
        df -BG "$MEDIA_MOUNT" | awk 'NR==2 {gsub("G",""); print $2, $3, $4, $5}' > "$MEDIA_CACHE"
    fi
fi
[ -f "$MEDIA_CACHE" ] && read -r disk_media_total disk_media_used _dmf disk_media_pct < "$MEDIA_CACHE" && disk_media_pct="${disk_media_pct%\%}"

# Disk growth
GROWTH_FILE="$DATA_DIR/disk-growth.csv"
TODAY=$(date +%Y-%m-%d)
[ ! -f "$GROWTH_FILE" ] && echo "date,root_used_gb,media_used_gb" > "$GROWTH_FILE"
grep -q "^$TODAY," "$GROWTH_FILE" 2>/dev/null || echo "$TODAY,${disk_root_used:-0},${disk_media_used:-0}" >> "$GROWTH_FILE"

growth_json=$(tail -90 "$GROWTH_FILE" | grep -v "^date," | awk -F',' '{printf "{\"date\":\"%s\",\"root\":%s,\"media\":%s}\n", $1, $2, $3}' | jq -s '.')

# ===== WRITE FINAL JSON (atomic) =====

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
    --argjson resolution_breakdown_movies "${breakdown_movies_json:-[]}" \
    --argjson codec_breakdown_movies "${codec_movies_json:-[]}" \
    --argjson upcoming "$(cat "$DATA_DIR/upcoming.cache" 2>/dev/null || echo '[]')" \
    --argjson recent "$(cat "$DATA_DIR/recent.cache" 2>/dev/null || echo '[]')" \
    --arg tv_total_size "${tv_total_size:-}" \
    --arg movies_total_size "${movies_total_size:-}" \
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
        codec_breakdown: $codec_breakdown,
        resolution_breakdown_movies: $resolution_breakdown_movies,
        codec_breakdown_movies: $codec_breakdown_movies,
        upcoming: $upcoming,
        recent: $recent,
        tv_total_size: $tv_total_size,
        movies_total_size: $movies_total_size
    }' > "$OUTPUT.tmp" && mv "$OUTPUT.tmp" "$OUTPUT"
