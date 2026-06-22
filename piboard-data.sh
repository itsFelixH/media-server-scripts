#!/bin/bash
# piboard-data.sh — Collects system, Plex, and library data for PiBoard
# Schedule: every 1 minute via crontab
# Output: ~/docker/piboard/data/system-status.json
#
# Caching strategy:
#   Fast (every run):   memory, cpu temp, uptime, network
#   Medium (5 min):     root disk, services, containers, last runs, plex info
#   Slow (1 hour):      library stats, audit, resolution/codec breakdown
#   Daily:              media disk, growth CSV, genre/decade, content (upcoming/recent)

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

DATA_DIR="$HOME/docker/piboard/data"
OUTPUT="$DATA_DIR/system-status.json"
mkdir -p "$DATA_DIR"

NOW=$(date +%s)
TODAY=$(date +%Y-%m-%d)

# --- Helper: check if cache is stale ---
cache_stale() {
    local file="$1" max_age="$2"
    [ ! -f "$file" ] && return 0
    [ $(( NOW - $(stat -c %Y "$file") )) -gt "$max_age" ] && return 0
    return 1
}

# --- Helper: safe cache read (returns empty/defaults on malformed file) ---
safe_source() {
    local file="$1"
    if [ -f "$file" ]; then
        source "$file" 2>/dev/null || true
    fi
}

# ===== FAST DATA (every run) =====

read -r mem_total mem_used mem_free mem_available <<< $(free -m | awk '/^Mem:/ {print $2, $3, $4, $7}')

# Swap
read -r swap_total swap_used swap_free <<< $(free -m | awk '/^Swap:/ {print $2, $3, $4}')

# CPU load averages
read -r load_1 load_5 load_15 <<< $(awk '{print $1, $2, $3}' /proc/loadavg)

cpu_temp=0
for thermal in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$thermal" ] && cpu_temp=$(( $(cat "$thermal") / 1000 )) && break
done

uptime_str=$(uptime -p | sed 's/^up //')
uptime_since=$(uptime -s 2>/dev/null || echo "")

# Top processes by memory (top 5)
top_procs=$(ps aux --sort=-%mem | awk 'NR>1 && NR<=6 {cmd=$11; gsub(/.*\//, "", cmd); printf "{\"name\":\"%s\",\"cpu\":%s,\"mem\":%s,\"mem_mb\":%.0f}\n", cmd, $3, $4, $6/1024}' | jq -s '.' 2>/dev/null || echo '[]')

net_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
net_gateway=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
net_gateway_ok="false"
net_internet_ms=""
[ -n "$net_gateway" ] && ping -c1 -W2 "$net_gateway" >/dev/null 2>&1 && net_gateway_ok="true"
net_internet_ms=$(ping -c1 -W3 8.8.8.8 2>/dev/null | grep -oP 'time=\K[0-9.]+' || echo "")

# ===== MEDIUM DATA (every 5 minutes) =====

SERVICES_CACHE="$DATA_DIR/.services.cache"

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

    # Plex API info
    _plex_json='{}'
    _pd=$(curl -s --max-time 5 "$PLEX_URL/?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null)
    if [ -n "$_pd" ]; then
        _plex_json=$(echo "$_pd" | jq '{version:.MediaContainer.version,platform:.MediaContainer.platform,platform_version:.MediaContainer.platformVersion,transcoder_active:(.MediaContainer.transcoderActiveVideoSessions // 0)}' 2>/dev/null)
        [ "$_plex_json" = "null" ] || [ -z "$_plex_json" ] && _plex_json='{}'
    fi

    # Kometa run status (errors/warnings from last run in meta.log)
    _kometa_status='{}'
    if [ -f "$KOMETA_CONFIG/logs/meta.log" ]; then
        _k_errors=$(grep -c "\[ERROR\]" "$KOMETA_CONFIG/logs/meta.log" 2>/dev/null) || _k_errors=0
        _k_warnings=$(grep -c "\[WARNING\]" "$KOMETA_CONFIG/logs/meta.log" 2>/dev/null) || _k_warnings=0
        _k_collections=$(grep -Ec "Collection .* created|Collection .* updated|Updating Details" "$KOMETA_CONFIG/logs/meta.log" 2>/dev/null) || _k_collections=0
        _kometa_status=$(jq -n --argjson e "$_k_errors" --argjson w "$_k_warnings" --argjson c "$_k_collections" '{errors:$e,warnings:$w,collections:$c}')
    fi

    # Write JSON cache files (safe against single quotes in data)
    echo "$_svc_json" > "$DATA_DIR/.services-list.json"
    echo "$_ctr_json" > "$DATA_DIR/.containers-list.json"
    echo "$_lr_json" > "$DATA_DIR/.last-runs.json"
    echo "$_plex_json" > "$DATA_DIR/.plex-info.json"
    echo "$_kometa_status" > "$DATA_DIR/.kometa-status.json"

    # Shell-sourceable cache for simple values only
    cat > "$SERVICES_CACHE" <<CACHE
disk_root_total=${_drT:-0}
disk_root_used=${_drU:-0}
disk_root_pct=${_drP:-0}
CACHE
fi

# Source medium cache
safe_source "$SERVICES_CACHE"

# Read JSON caches
services_json=$(cat "$DATA_DIR/.services-list.json" 2>/dev/null || echo '[]')
containers_json=$(cat "$DATA_DIR/.containers-list.json" 2>/dev/null || echo '[]')
last_runs_json=$(cat "$DATA_DIR/.last-runs.json" 2>/dev/null || echo '[]')
plex_json=$(cat "$DATA_DIR/.plex-info.json" 2>/dev/null || echo '{}')
kometa_status_json=$(cat "$DATA_DIR/.kometa-status.json" 2>/dev/null)
[ -z "$kometa_status_json" ] || ! echo "$kometa_status_json" | jq . >/dev/null 2>&1 && kometa_status_json='{}'

# ===== SLOW DATA (every hour) =====

REPORTS_CACHE="$DATA_DIR/.reports.cache"

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
    _tv_size=""
    _mov_size=""
    if [ -f "$REPORT_DIR/storage-report.md" ]; then
        # TV breakdown (first occurrence)
        _res_json=$(awk '/^# TV Shows/,/^# Movies/' "$REPORT_DIR/storage-report.md" | awk '/^## Resolution Breakdown/,/^---$/' | grep '^|' | tail -n +3 | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if($2!="") printf "{\"resolution\":\"%s\",\"folders\":\"%s\",\"size\":\"%s\"}\n",$2,$3,$4}' | jq -s '.' 2>/dev/null || echo '[]')
        _cod_json=$(awk '/^# TV Shows/,/^# Movies/' "$REPORT_DIR/storage-report.md" | awk '/^## Codec Breakdown/,/^---$/' | grep '^|' | tail -n +3 | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if($2!="") printf "{\"codec\":\"%s\",\"folders\":\"%s\",\"size\":\"%s\"}\n",$2,$3,$4}' | jq -s '.' 2>/dev/null || echo '[]')
        # Movies breakdown (after "# Movies")
        _res_movies_json=$(awk '/^# Movies/,0' "$REPORT_DIR/storage-report.md" | awk '/^## Resolution Breakdown/,/^---$/' | grep '^|' | tail -n +3 | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if($2!="") printf "{\"resolution\":\"%s\",\"folders\":\"%s\",\"size\":\"%s\"}\n",$2,$3,$4}' | jq -s '.' 2>/dev/null || echo '[]')
        _cod_movies_json=$(awk '/^# Movies/,0' "$REPORT_DIR/storage-report.md" | awk '/^## Codec Breakdown/,/^---$/' | grep '^|' | tail -n +3 | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if($2!="") printf "{\"codec\":\"%s\",\"folders\":\"%s\",\"size\":\"%s\"}\n",$2,$3,$4}' | jq -s '.' 2>/dev/null || echo '[]')
        # Fallback: if no "# TV Shows" header (old single-library format)
        [ "$_res_json" = "[]" ] && _res_json=$(awk '/^## Resolution Breakdown/,/^---$/' "$REPORT_DIR/storage-report.md" | grep '^|' | tail -n +3 | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if($2!="") printf "{\"resolution\":\"%s\",\"folders\":\"%s\",\"size\":\"%s\"}\n",$2,$3,$4}' | jq -s '.')
        [ "$_cod_json" = "[]" ] && _cod_json=$(awk '/^## Codec Breakdown/,/^---$/' "$REPORT_DIR/storage-report.md" | grep '^|' | tail -n +3 | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if($2!="") printf "{\"codec\":\"%s\",\"folders\":\"%s\",\"size\":\"%s\"}\n",$2,$3,$4}' | jq -s '.')
        # Total sizes for breakdown headers
        _tv_size=$(awk '/^# TV Shows/,/^# Movies/' "$REPORT_DIR/storage-report.md" | grep "Total size" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
        _mov_size=$(awk '/^# Movies/,0' "$REPORT_DIR/storage-report.md" | grep "Total size" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
        [ -z "$_tv_size" ] && _tv_size=$(grep "Total size" "$REPORT_DIR/storage-report.md" | head -1 | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
    fi

    # Write JSON caches (safe against single quotes)
    echo "$_lib_json" > "$DATA_DIR/.library.json"
    echo "$_aud_json" > "$DATA_DIR/.audit.json"
    echo "$_res_json" > "$DATA_DIR/.breakdown-res-tv.json"
    echo "$_cod_json" > "$DATA_DIR/.breakdown-cod-tv.json"
    echo "$_res_movies_json" > "$DATA_DIR/.breakdown-res-movies.json"
    echo "$_cod_movies_json" > "$DATA_DIR/.breakdown-cod-movies.json"

    # Shell-sourceable for simple string values only
    cat > "$REPORTS_CACHE" <<CACHE
tv_total_size=$(printf '%q' "$_tv_size")
movies_total_size=$(printf '%q' "$_mov_size")
CACHE
fi

# Source reports cache
safe_source "$REPORTS_CACHE"

# Read JSON caches
library_json=$(cat "$DATA_DIR/.library.json" 2>/dev/null || echo '{}')
audit_json=$(cat "$DATA_DIR/.audit.json" 2>/dev/null || echo '{}')
breakdown_json=$(cat "$DATA_DIR/.breakdown-res-tv.json" 2>/dev/null || echo '[]')
codec_json=$(cat "$DATA_DIR/.breakdown-cod-tv.json" 2>/dev/null || echo '[]')
breakdown_movies_json=$(cat "$DATA_DIR/.breakdown-res-movies.json" 2>/dev/null || echo '[]')
codec_movies_json=$(cat "$DATA_DIR/.breakdown-cod-movies.json" 2>/dev/null || echo '[]')

# ===== GENRE/DECADE DATA (daily — Plex API for full library metadata) =====

GENRE_CACHE="$DATA_DIR/.genre-decade-date"

_last_genre_check=""
[ -f "$GENRE_CACHE" ] && _last_genre_check=$(cat "$GENRE_CACHE")

if [ "$TODAY" != "$_last_genre_check" ]; then
    # Fetch full library metadata once (reuse for both genre and decade)
    _movies_meta=$(curl -s --max-time 15 "$PLEX_URL/library/sections/4/all?X-Plex-Token=$PLEX_TOKEN&type=1" -H "Accept: application/json" 2>/dev/null)
    _tv_meta=$(curl -s --max-time 15 "$PLEX_URL/library/sections/5/all?X-Plex-Token=$PLEX_TOKEN&type=2" -H "Accept: application/json" 2>/dev/null)

    # Genre breakdown (combined Movies + TV)
    _genre_json='[]'
    _movies_genres=""
    _tv_genres=""
    [ -n "$_movies_meta" ] && _movies_genres=$(echo "$_movies_meta" | jq '[.MediaContainer.Metadata[].Genre[]?.tag] | group_by(.) | map({genre: .[0], count: length}) | sort_by(-.count)' 2>/dev/null)
    [ -n "$_tv_meta" ] && _tv_genres=$(echo "$_tv_meta" | jq '[.MediaContainer.Metadata[].Genre[]?.tag] | group_by(.) | map({genre: .[0], count: length}) | sort_by(-.count)' 2>/dev/null)

    if [ -n "$_movies_genres" ] && [ "$_movies_genres" != "null" ] && [ -n "$_tv_genres" ] && [ "$_tv_genres" != "null" ]; then
        _genre_json=$(jq -n --argjson m "$_movies_genres" --argjson t "$_tv_genres" '$m + $t | group_by(.genre) | map({genre: .[0].genre, count: (map(.count) | add)}) | sort_by(-.count)' 2>/dev/null || echo '[]')
    elif [ -n "$_movies_genres" ] && [ "$_movies_genres" != "null" ]; then
        _genre_json="$_movies_genres"
    elif [ -n "$_tv_genres" ] && [ "$_tv_genres" != "null" ]; then
        _genre_json="$_tv_genres"
    fi

    # Decade breakdown (combined Movies + TV)
    _decade_json='[]'
    _movies_years=""
    _tv_years=""
    [ -n "$_movies_meta" ] && _movies_years=$(echo "$_movies_meta" | jq '[.MediaContainer.Metadata[].year // empty]' 2>/dev/null)
    [ -n "$_tv_meta" ] && _tv_years=$(echo "$_tv_meta" | jq '[.MediaContainer.Metadata[].year // empty]' 2>/dev/null)

    if [ -n "$_movies_years" ] && [ "$_movies_years" != "null" ]; then
        _all_years=$(jq -n --argjson m "$_movies_years" --argjson t "${_tv_years:-[]}" '$m + $t')
        _decade_json=$(echo "$_all_years" | jq '[.[] | (. / 10 | floor) * 10] | group_by(.) | map({decade: (.[0] | tostring + "s"), count: length}) | sort_by(.decade)' 2>/dev/null || echo '[]')
    fi

    # Write JSON caches (safe against any characters in data)
    echo "$_genre_json" > "$DATA_DIR/.genres.json"
    echo "$_decade_json" > "$DATA_DIR/.decades.json"
    echo "$TODAY" > "$GENRE_CACHE"
fi

# Read genre/decade caches
genre_json=$(cat "$DATA_DIR/.genres.json" 2>/dev/null || echo '[]')
decade_json=$(cat "$DATA_DIR/.decades.json" 2>/dev/null || echo '[]')

# ===== CONTENT DATA (daily — upcoming/recently watched with poster lookups) =====

TMDB_KEY="6d32d887bcfd246d796970654c83b804"
CONTENT_CHECK="$DATA_DIR/.content-check-date"

_last_content_check=""
[ -f "$CONTENT_CHECK" ] && _last_content_check=$(cat "$CONTENT_CHECK")

if [ "$TODAY" != "$_last_content_check" ] || [ ! -f "$DATA_DIR/.upcoming.json" ]; then
    # Build a hash of current content to detect changes
    _plex_upcoming_ids=$(curl -s --max-time 5 "$PLEX_URL/library/sections/4/collections?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | select(.title | contains("Coming Soon")) | .ratingKey' | while read col; do curl -s --max-time 5 "$PLEX_URL/library/collections/$col/children?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[].ratingKey'; done)
    _plex_tv_upcoming_ids=$(curl -s --max-time 5 "$PLEX_URL/library/sections/5/collections?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | select(.title | contains("Coming Soon")) | .ratingKey' | while read col; do curl -s --max-time 5 "$PLEX_URL/library/collections/$col/children?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[].ratingKey'; done)
    _plex_recent_ids=$(curl -s --max-time 5 "$PLEX_URL/status/sessions/history/all?X-Plex-Token=$PLEX_TOKEN&sort=viewedAt:desc&limit=30" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[].ratingKey')
    _content_hash=$(echo "$_plex_upcoming_ids $_plex_tv_upcoming_ids $_plex_recent_ids" | md5sum | awk '{print $1}')
    _cached_hash=""
    [ -f "$DATA_DIR/.content-hash" ] && _cached_hash=$(cat "$DATA_DIR/.content-hash")

    echo "$TODAY" > "$CONTENT_CHECK"

    if [ "$_content_hash" != "$_cached_hash" ]; then
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
        [ -n "$_mov_col" ] && while IFS=$'\t' read -r title year rkey date; do
            [ -z "$rkey" ] && continue
            p=$(_get_poster "$rkey" "movie")
            _upcoming_json=$(echo "$_upcoming_json" | jq --arg n "$title ($year)" --arg p "${p:-}" --arg t "movie" --arg d "${date:-}" '. + [{name:$n,poster:$p,type:$t,date:$d}]')
        done < <(curl -s --max-time 5 "$PLEX_URL/library/collections/$_mov_col/children?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | "\(.title)\t\(.year)\t\(.ratingKey)\t\(.originallyAvailableAt // "")"')

        # Upcoming TV
        _tv_col=$(curl -s --max-time 5 "$PLEX_URL/library/sections/5/collections?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | select(.title | contains("Coming Soon")) | .ratingKey')
        [ -n "$_tv_col" ] && while IFS=$'\t' read -r title rkey date; do
            [ -z "$rkey" ] && continue
            p=$(_get_poster "$rkey" "tv")
            _upcoming_json=$(echo "$_upcoming_json" | jq --arg n "$title" --arg p "${p:-}" --arg t "tv" --arg d "${date:-}" '. + [{name:$n,poster:$p,type:$t,date:$d}]')
        done < <(curl -s --max-time 5 "$PLEX_URL/library/collections/$_tv_col/children?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | "\(.title)\t\(.ratingKey)\t\(.originallyAvailableAt // "")"')
        echo "$_upcoming_json" > "$DATA_DIR/.upcoming.json"

        # Recently Watched
        _recent_json="[]"
        _seen=""
        while IFS='§' read -r title type gp_title rkey; do
            [ -z "$rkey" ] && continue
            if [ "$type" = "episode" ]; then
                gp_rkey=$(curl -s --max-time 5 "$PLEX_URL/library/metadata/$rkey?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[0].grandparentRatingKey // empty')
                [ -z "$gp_rkey" ] && continue
                echo "$_seen" | grep -q "$gp_rkey" && continue
                _seen="$_seen $gp_rkey"
                p=$(_get_poster "$gp_rkey" "tv")
                _recent_json=$(echo "$_recent_json" | jq --arg n "$gp_title" --arg p "${p:-}" --arg t "tv" '. + [{name:$n,poster:$p,type:$t}]')
            else
                p=$(_get_poster "$rkey" "movie")
                _recent_json=$(echo "$_recent_json" | jq --arg n "$title" --arg p "${p:-}" --arg t "movie" '. + [{name:$n,poster:$p,type:$t}]')
            fi
        done < <(curl -s --max-time 5 "$PLEX_URL/status/sessions/history/all?X-Plex-Token=$PLEX_TOKEN&sort=viewedAt:desc&limit=30&accountID=1" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | "\(.title)§\(.type)§\(.grandparentTitle // "NONE")§\(.ratingKey)"')
        echo "$_recent_json" > "$DATA_DIR/.recent.json"

        echo "$_content_hash" > "$DATA_DIR/.content-hash"
    fi
fi

# ===== DAILY DATA =====

# Media disk
MEDIA_CACHE="$DATA_DIR/.media-disk.cache"
disk_media_total=0 disk_media_used=0 disk_media_pct=0

if cache_stale "$MEDIA_CACHE" 86400; then
    MEDIA_MOUNT=$(dirname "$MOVIES_DIR")
    if mountpoint -q "$MEDIA_MOUNT" 2>/dev/null; then
        df -BG "$MEDIA_MOUNT" | awk 'NR==2 {gsub("G",""); print $2, $3, $4, $5}' > "$MEDIA_CACHE"
    fi
fi
[ -f "$MEDIA_CACHE" ] && read -r disk_media_total disk_media_used _dmf disk_media_pct < "$MEDIA_CACHE" && disk_media_pct="${disk_media_pct%\%}"

# Disk growth (Movies + TV sizes from storage report)
GROWTH_FILE="$DATA_DIR/disk-growth.csv"
[ ! -f "$GROWTH_FILE" ] && echo "date,movies_gb,tv_gb" > "$GROWTH_FILE"

if ! grep -q "^$TODAY," "$GROWTH_FILE" 2>/dev/null; then
    _movies_gb=0 _tv_gb=0
    if [ -n "$tv_total_size" ]; then
        echo "$tv_total_size" | grep -q "TB" && _tv_gb=$(echo "$tv_total_size" | grep -oP '[0-9.]+' | awk '{printf "%.0f", $1 * 1024}') || _tv_gb=$(echo "$tv_total_size" | grep -oP '[0-9.]+' | awk '{printf "%.0f", $1}')
    fi
    if [ -n "$movies_total_size" ]; then
        echo "$movies_total_size" | grep -q "TB" && _movies_gb=$(echo "$movies_total_size" | grep -oP '[0-9.]+' | awk '{printf "%.0f", $1 * 1024}') || _movies_gb=$(echo "$movies_total_size" | grep -oP '[0-9.]+' | awk '{printf "%.0f", $1}')
    fi
    [ "$_movies_gb" -gt 0 ] || [ "$_tv_gb" -gt 0 ] && echo "$TODAY,$_movies_gb,$_tv_gb" >> "$GROWTH_FILE"
fi

growth_json=$(grep -v "^date," "$GROWTH_FILE" | awk -F',' '{printf "{\"date\":\"%s\",\"movies\":%s,\"tv\":%s}\n", $1, $2, $3}' | jq -s '.')

# ===== WRITE FINAL JSON (atomic) =====

jq -n \
    --arg timestamp "$(date -Iseconds)" \
    --argjson mem_total "$mem_total" \
    --argjson mem_used "$mem_used" \
    --argjson mem_available "${mem_available:-0}" \
    --argjson swap_total "${swap_total:-0}" \
    --argjson swap_used "${swap_used:-0}" \
    --argjson swap_free "${swap_free:-0}" \
    --arg load_1 "${load_1:-0}" \
    --arg load_5 "${load_5:-0}" \
    --arg load_15 "${load_15:-0}" \
    --argjson disk_root_total "${disk_root_total:-0}" \
    --argjson disk_root_used "${disk_root_used:-0}" \
    --argjson disk_root_pct "${disk_root_pct:-0}" \
    --argjson disk_media_total "${disk_media_total:-0}" \
    --argjson disk_media_used "${disk_media_used:-0}" \
    --argjson disk_media_pct "${disk_media_pct:-0}" \
    --argjson cpu_temp "${cpu_temp:-0}" \
    --arg uptime "$uptime_str" \
    --arg uptime_since "${uptime_since:-}" \
    --argjson top_procs "${top_procs:-[]}" \
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
    --argjson kometa_status "$kometa_status_json" \
    --argjson audit "$audit_json" \
    --argjson resolution_breakdown "$breakdown_json" \
    --argjson codec_breakdown "${codec_json:-[]}" \
    --argjson resolution_breakdown_movies "${breakdown_movies_json:-[]}" \
    --argjson codec_breakdown_movies "${codec_movies_json:-[]}" \
    --argjson upcoming "$(cat "$DATA_DIR/.upcoming.json" 2>/dev/null || echo '[]')" \
    --argjson recent "$(cat "$DATA_DIR/.recent.json" 2>/dev/null || echo '[]')" \
    --arg tv_total_size "${tv_total_size:-}" \
    --arg movies_total_size "${movies_total_size:-}" \
    --argjson genres "$genre_json" \
    --argjson decades "$decade_json" \
    '{
        timestamp: $timestamp,
        memory: { total_mb: $mem_total, used_mb: $mem_used, available_mb: $mem_available },
        swap: { total_mb: $swap_total, used_mb: $swap_used, free_mb: $swap_free },
        load: { avg_1: $load_1, avg_5: $load_5, avg_15: $load_15 },
        disk: {
            root: { total_gb: $disk_root_total, used_gb: $disk_root_used, percent: $disk_root_pct },
            media: { total_gb: $disk_media_total, used_gb: $disk_media_used, percent: $disk_media_pct }
        },
        cpu_temp_c: $cpu_temp,
        uptime: $uptime,
        uptime_since: $uptime_since,
        top_procs: $top_procs,
        services: $services,
        containers: $containers,
        last_runs: $last_runs,
        library: $library,
        network: { ip: $net_ip, gateway: $net_gateway, gateway_ok: $net_gateway_ok, internet_ms: $net_internet_ms },
        disk_growth: $disk_growth,
        plex: $plex,
        kometa_status: $kometa_status,
        audit: $audit,
        resolution_breakdown: $resolution_breakdown,
        codec_breakdown: $codec_breakdown,
        resolution_breakdown_movies: $resolution_breakdown_movies,
        codec_breakdown_movies: $codec_breakdown_movies,
        upcoming: $upcoming,
        recent: $recent,
        tv_total_size: $tv_total_size,
        movies_total_size: $movies_total_size,
        genres: $genres,
        decades: $decades
    }' > "$OUTPUT.tmp" && mv "$OUTPUT.tmp" "$OUTPUT"
