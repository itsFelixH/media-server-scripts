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
    # Script-based last runs (from log directories)
    for _sname in healthcheck backup archive-reports maintenance library-catalog metadata-audit encode-queue storage-report media-analyzer; do
        _sl=$(ls -t "$LOG_DIR/$_sname"/${_sname}_*.log 2>/dev/null | head -1)
        [ -n "$_sl" ] && {
            _t=$(stat -c '%Y' "$_sl")
            # Map directory names to SCHEDULE_DATA names
            case "$_sname" in
                healthcheck) _add_lr "Health Check" "$_t" ;;
                backup) _add_lr "Backup" "$_t" ;;
                archive-reports) _add_lr "Archive Reports" "$_t" ;;
                maintenance) _add_lr "Maintenance" "$_t" ;;
                library-catalog) _add_lr "Library Catalog" "$_t" ;;
                metadata-audit) _add_lr "Metadata Audit" "$_t" ;;
                encode-queue) _add_lr "Encode Queue" "$_t" ;;
                storage-report) _add_lr "Storage Report" "$_t" ;;
            esac
        }
    done

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
    if [ -f "$REPORT_DIR/library-catalog.json" ]; then
        _lib_json=$(jq '{movies: .summary.movies, shows: .summary.tv_shows, episodes: .summary.episodes}' "$REPORT_DIR/library-catalog.json" 2>/dev/null || echo '{}')
    fi

    # Audit
    _aud_json='{}'
    if [ -f "$REPORT_DIR/metadata-audit.json" ]; then
        _aud_ts=$(stat -c '%Y' "$REPORT_DIR/metadata-audit.json")
        _aud_json=$(jq --argjson ts "${_aud_ts:-0}" '{
            orphaned: .summary.orphaned,
            warnings: .summary.warnings,
            duplicates: .summary.duplicates,
            issues: .summary.issues,
            upcoming: .summary.upcoming,
            prev_warnings: (.comparison.prev_warnings // 0),
            prev_issues: (.comparison.prev_issues // 0),
            prev_duplicates: (.comparison.prev_duplicates // 0),
            generated: $ts
        }' "$REPORT_DIR/metadata-audit.json" 2>/dev/null || echo '{}')
    fi

    # Breakdown
    _res_json='[]'
    _cod_json='[]'
    _res_movies_json='[]'
    _cod_movies_json='[]'
    _tv_size=""
    _mov_size=""
    if [ -f "$REPORT_DIR/storage-report.json" ]; then
        # TV breakdown (first library)
        _res_json=$(jq '[.data.libraries[0].breakdowns.resolution[] | {resolution: .label, folders: (.folders | tostring), size: .size}]' "$REPORT_DIR/storage-report.json" 2>/dev/null || echo '[]')
        _cod_json=$(jq '[.data.libraries[0].breakdowns.codec[] | {codec: .label, folders: (.folders | tostring), size: .size}]' "$REPORT_DIR/storage-report.json" 2>/dev/null || echo '[]')
        # Movies breakdown (second library if exists)
        _res_movies_json=$(jq '[.data.libraries[1].breakdowns.resolution[] | {resolution: .label, folders: (.folders | tostring), size: .size}]' "$REPORT_DIR/storage-report.json" 2>/dev/null || echo '[]')
        _cod_movies_json=$(jq '[.data.libraries[1].breakdowns.codec[] | {codec: .label, folders: (.folders | tostring), size: .size}]' "$REPORT_DIR/storage-report.json" 2>/dev/null || echo '[]')
        # Total sizes
        _tv_size=$(jq -r '.data.libraries[0].breakdowns.resolution | [.[].size_bytes] | add | . as $b | if $b >= 1099511627776 then "\($b / 1099511627776 * 100 | floor / 100) TB" elif $b >= 1073741824 then "\($b / 1073741824 * 100 | floor / 100) GB" else "\($b / 1048576 | floor) MB" end' "$REPORT_DIR/storage-report.json" 2>/dev/null)
        _mov_size=$(jq -r '.data.libraries[1].breakdowns.resolution | [.[].size_bytes] | add | . as $b | if $b >= 1099511627776 then "\($b / 1099511627776 * 100 | floor / 100) TB" elif $b >= 1073741824 then "\($b / 1073741824 * 100 | floor / 100) GB" else "\($b / 1048576 | floor) MB" end' "$REPORT_DIR/storage-report.json" 2>/dev/null)
        # Simpler: use summary total_size if available (for single-library reports)
        [ -z "$_tv_size" ] || [ "$_tv_size" = "null" ] && _tv_size=$(jq -r '.summary.total_size // empty' "$REPORT_DIR/storage-report.json" 2>/dev/null)
    fi

    # Report file timestamps
    _storage_ts=0
    [ -f "$REPORT_DIR/storage-report.json" ] && _storage_ts=$(stat -c '%Y' "$REPORT_DIR/storage-report.json")
    _catalog_ts=0
    [ -f "$REPORT_DIR/library-catalog.json" ] && _catalog_ts=$(stat -c '%Y' "$REPORT_DIR/library-catalog.json")

    # Write JSON caches
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
storage_report_ts=$_storage_ts
catalog_ts=$_catalog_ts
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
            local tmdb_id poster plex_meta
            echo -n "" > "$DATA_DIR/.last_tmdb_url"
            plex_meta=$(curl -s --max-time 8 "$PLEX_URL/library/metadata/$rkey?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null)
            tmdb_id=$(echo "$plex_meta" | jq -r '.MediaContainer.Metadata[0].Guid[]?.id' | grep "tmdb://" | sed 's|tmdb://||')
            if [ -n "$tmdb_id" ]; then
                [ "$mtype" = "movie" ] && echo -n "https://www.themoviedb.org/movie/${tmdb_id}" > "$DATA_DIR/.last_tmdb_url" || echo -n "https://www.themoviedb.org/tv/${tmdb_id}" > "$DATA_DIR/.last_tmdb_url"
                poster=$(curl -s --max-time 5 "https://api.themoviedb.org/3/${mtype}/${tmdb_id}?api_key=$TMDB_KEY" 2>/dev/null | jq -r '.poster_path // empty')
                [ -n "$poster" ] && { echo "https://image.tmdb.org/t/p/w200${poster}"; return; }
            fi
            # Fallback: use Plex thumb directly
            local thumb=$(echo "$plex_meta" | jq -r '.MediaContainer.Metadata[0].thumb // empty')
            [ -n "$thumb" ] && echo "${PLEX_URL}${thumb}?X-Plex-Token=${PLEX_TOKEN}&width=200&height=300"
        }

        # Upcoming Movies
        _upcoming_json="[]"
        _mov_col=$(curl -s --max-time 5 "$PLEX_URL/library/sections/4/collections?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | select(.title | contains("Coming Soon")) | .ratingKey')
        [ -n "$_mov_col" ] && while IFS=$'\t' read -r title year rkey date; do
            [ -z "$rkey" ] && continue
            p=$(_get_poster "$rkey" "movie")
            u=$(cat "$DATA_DIR/.last_tmdb_url" 2>/dev/null)
            _upcoming_json=$(echo "$_upcoming_json" | jq --arg n "$title ($year)" --arg p "${p:-}" --arg t "movie" --arg d "${date:-}" --arg u "${u:-}" '. + [{name:$n,poster:$p,type:$t,date:$d,url:$u}]')
        done < <(curl -s --max-time 5 "$PLEX_URL/library/collections/$_mov_col/children?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | "\(.title)\t\(.year)\t\(.ratingKey)\t\(.originallyAvailableAt // "")"')

        # Upcoming TV
        _tv_col=$(curl -s --max-time 5 "$PLEX_URL/library/sections/5/collections?X-Plex-Token=$PLEX_TOKEN" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | select(.title | contains("Coming Soon")) | .ratingKey')
        [ -n "$_tv_col" ] && while IFS=$'\t' read -r title rkey date; do
            [ -z "$rkey" ] && continue
            p=$(_get_poster "$rkey" "tv")
            u=$(cat "$DATA_DIR/.last_tmdb_url" 2>/dev/null)
            _upcoming_json=$(echo "$_upcoming_json" | jq --arg n "$title" --arg p "${p:-}" --arg t "tv" --arg d "${date:-}" --arg u "${u:-}" '. + [{name:$n,poster:$p,type:$t,date:$d,url:$u}]')
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
                u=$(cat "$DATA_DIR/.last_tmdb_url" 2>/dev/null)
                _recent_json=$(echo "$_recent_json" | jq --arg n "$gp_title" --arg p "${p:-}" --arg t "tv" --arg u "${u:-}" '. + [{name:$n,poster:$p,type:$t,url:$u}]')
            else
                p=$(_get_poster "$rkey" "movie")
                u=$(cat "$DATA_DIR/.last_tmdb_url" 2>/dev/null)
                _recent_json=$(echo "$_recent_json" | jq --arg n "$title" --arg p "${p:-}" --arg t "movie" --arg u "${u:-}" '. + [{name:$n,poster:$p,type:$t,url:$u}]')
            fi
        done < <(curl -s --max-time 5 "$PLEX_URL/status/sessions/history/all?X-Plex-Token=$PLEX_TOKEN&sort=viewedAt:desc&limit=30&accountID=1" -H "Accept: application/json" 2>/dev/null | jq -r '.MediaContainer.Metadata[] | "\(.title)§\(.type)§\(.grandparentTitle // "NONE")§\(.ratingKey)"')
        echo "$_recent_json" > "$DATA_DIR/.recent.json"

        echo "$_content_hash" > "$DATA_DIR/.content-hash"
    fi
fi

# ===== DAILY DATA =====

# Healthcheck aggregation (every 5 min — produces a single JSON for the frontend)
HC_AGG_CACHE="$DATA_DIR/.healthcheck-agg.cache"
if cache_stale "$HC_AGG_CACHE" 300; then
    _hc_json='[]'
    _hc_dir="$LOG_DIR/healthcheck"
    if [ -d "$_hc_dir" ]; then
        _hc_files=$(ls -r "$_hc_dir"/healthcheck_*.log 2>/dev/null | head -30)
        for _hcf in $_hc_files; do
            _fname=$(basename "$_hcf")
            _entries=$(awk '/^\[/{
                t=substr($0,2,16)
                s=index($0,"] ")>0 ? substr($0,index($0,"] ")+2) : ""
                if(s~/^OK/) printf "{\"time\":\"%s\",\"status\":\"ok\",\"detail\":null},", t
                else if(s~/^FAIL/) { gsub(/^FAIL[^:]*: /,"",s); gsub(/"/,"\\\"",s); printf "{\"time\":\"%s\",\"status\":\"fail\",\"detail\":\"%s\"},", t, s }
            }' "$_hcf" | sed 's/,$//')
            _hc_json=$(echo "$_hc_json" | jq --arg f "$_fname" --argjson e "[${_entries}]" '. + [{filename:$f,entries:$e}]')
        done
    fi
    echo "$_hc_json" > "$DATA_DIR/healthcheck-summary.json"
    touch "$HC_AGG_CACHE"
fi

# Schedule JSON (every 5 min — parsed from actual crontab + docker compose env vars)
SCHED_CACHE="$DATA_DIR/.schedule.cache"
if cache_stale "$SCHED_CACHE" 300; then
    _sched_json='[]'

    _add_sched() {
        local name="$1" label="$2" hour="$3" min="$4" interval="$5" days="$6" cat="$7" desc="$8"
        _sched_json=$(echo "$_sched_json" | jq \
            --arg name "$name" \
            --arg label "$label" \
            --argjson hour "$hour" \
            --argjson min "$min" \
            --argjson interval "$interval" \
            --arg days "$days" \
            --arg cat "$cat" \
            --arg desc "$desc" \
            '. + [{name:$name,label:$label,hour:$hour,min:$min,interval:$interval,days:$days,cat:$cat,desc:$desc}]')
    }

    # --- Parse crontab entries ---
    # Map script filenames to display names, categories, and descriptions
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#|^$ ]] && continue
        [[ "$line" =~ ^MAILTO|^PATH ]] && continue

        # Extract cron fields
        read -r _min _hour _dom _mon _dow _rest <<< "$line"

        # Determine task name from command
        _task_name="" _cat="script" _desc=""
        case "$_rest" in
            *healthcheck.sh*)    _task_name="Health Check"; _cat="monitoring" ;;
            *plextraktsync*)     _task_name="Plex Trakt Sync"; _cat="sync" ;;
            *backup.sh*)         _task_name="Backup"; _desc="Backs up all configs to /mnt/Media/backups/" ;;
            *maintenance.sh*)    _task_name="Maintenance"; _desc="System updates, Docker updates, config validation, log rotation" ;;
            *library-catalog.sh*) _task_name="Library Catalog"; _desc="Snapshots library content, diffs against previous run" ;;
            *metadata-audit.sh*) _task_name="Metadata Audit"; _desc="Validates metadata files against library" ;;
            *encode-queue.sh*)   _task_name="Encode Queue"; _desc="Generates prioritized re-encode list from both libraries" ;;
            *storage-report.sh*) _task_name="Storage Report"; _desc="Storage usage report with resolution/codec breakdown" ;;
            *archive-reports.sh*) _task_name="Archive Reports"; _desc="Archives changed reports to /mnt/Media/reports/" ;;
            *piboard-data.sh*)   continue ;; # Skip self — runs every minute, not interesting
            *)                   continue ;; # Skip unrecognized entries
        esac
        [ -z "$_task_name" ] && continue

        # Determine schedule type and build label
        _s_hour="null" _s_min=0 _s_interval=0 _s_days="daily" _s_label=""

        if [[ "$_min" == "*/"* ]]; then
            # Interval: */30 * * * * → every 30 min
            _s_interval="${_min#*/}"
            _s_label="Every ${_s_interval} min"
        elif [[ "$_hour" == "*/"* ]]; then
            # Interval: 0 */2 * * * → every 2h
            _s_interval=$(( ${_hour#*/} * 60 ))
            _s_label="Every ${_hour#*/}h"
        else
            # Fixed time
            _s_min="$_min"
            _s_hour="$_hour"
            _time_str=$(printf "%02d:%02d" "$_hour" "$_min")

            if [ "$_dow" != "*" ]; then
                # Day of week (0=Sun, 1=Mon, etc)
                case "$_dow" in
                    0) _s_days="sun"; _s_label="Sun $_time_str" ;;
                    1) _s_days="mon"; _s_label="Mon $_time_str" ;;
                    2) _s_days="tue"; _s_label="Tue $_time_str" ;;
                    3) _s_days="wed"; _s_label="Wed $_time_str" ;;
                    4) _s_days="thu"; _s_label="Thu $_time_str" ;;
                    5) _s_days="fri"; _s_label="Fri $_time_str" ;;
                    6) _s_days="sat"; _s_label="Sat $_time_str" ;;
                    *) _s_days="daily"; _s_label="$_time_str" ;;
                esac
            elif [ "$_dom" != "*" ]; then
                # Day of month
                case "$_dom" in
                    1)  _s_days="1st"; _s_label="1st $_time_str" ;;
                    28) _s_days="28th"; _s_label="28th $_time_str" ;;
                    *)  _s_days="${_dom}th"; _s_label="${_dom}th $_time_str" ;;
                esac
            else
                _s_days="daily"
                _s_label="$_time_str"
            fi
        fi

        _add_sched "$_task_name" "$_s_label" "$_s_hour" "$_s_min" "$_s_interval" "$_s_days" "$_cat" "$_desc"
    done < <(crontab -l 2>/dev/null)

    # --- Docker container schedules (from compose env vars) ---

    # Kometa: KOMETA_TIMES env var
    _kometa_time=$(grep -oP 'KOMETA_TIMES=\K[0-9:]+' "$HOME/docker/kometa/docker-compose.yml" 2>/dev/null)
    if [ -n "$_kometa_time" ]; then
        _kh="${_kometa_time%%:*}"; _km="${_kometa_time##*:}"
        _add_sched "Kometa" "$_kometa_time" "$_kh" "$_km" 0 "daily" "docker" "Applies overlays, collections, and metadata to Plex"
    fi

    # UMTK: CRON env var (standard cron format)
    _umtk_cron=$(grep -oP 'CRON=\K[0-9* /]+' "$HOME/docker/umtk/docker-compose.yml" 2>/dev/null)
    if [ -n "$_umtk_cron" ]; then
        read -r _um _uh _rest <<< "$_umtk_cron"
        _add_sched "UMTK" "$(printf '%02d:%02d' "$_uh" "$_um")" "$_uh" "$_um" 0 "daily" "docker" "Generates overlays & placeholders from Radarr/Sonarr"
    fi

    # ImageMaid: SCHEDULE in .env (format: HH:MM|weekly(day))
    _im_sched=$(grep -oP 'SCHEDULE=\K.+' "$IMAGEMAID_CONFIG_DIR/.env" 2>/dev/null)
    if [ -n "$_im_sched" ]; then
        _im_time="${_im_sched%%|*}"
        _im_freq="${_im_sched##*|}"
        _im_h="${_im_time%%:*}"; _im_m="${_im_time##*:}"
        _im_day="daily"; _im_label="$_im_time"
        case "$_im_freq" in
            *sunday*)    _im_day="sun"; _im_label="Sun $_im_time" ;;
            *monday*)    _im_day="mon"; _im_label="Mon $_im_time" ;;
            *saturday*)  _im_day="sat"; _im_label="Sat $_im_time" ;;
            *daily*)     _im_day="daily"; _im_label="$_im_time" ;;
        esac
        _add_sched "ImageMaid" "$_im_label" "$_im_h" "$_im_m" 0 "$_im_day" "docker" "Removes bloated images, cleans PhotoTranscoder, optimizes DB"
    fi

    echo "$_sched_json" > "$DATA_DIR/schedule.json"
    touch "$SCHED_CACHE"
fi

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

# Calculate cache ages for frontend "last updated" display
_age_medium=0
[ -f "$SERVICES_CACHE" ] && _age_medium=$(( NOW - $(stat -c %Y "$SERVICES_CACHE") ))
_age_slow=0
[ -f "$REPORTS_CACHE" ] && _age_slow=$(( NOW - $(stat -c %Y "$REPORTS_CACHE") ))
_age_genre=0
[ -f "$DATA_DIR/.genres.json" ] && _age_genre=$(( NOW - $(stat -c %Y "$DATA_DIR/.genres.json") ))
_age_content=0
[ -f "$DATA_DIR/.upcoming.json" ] && _age_content=$(( NOW - $(stat -c %Y "$DATA_DIR/.upcoming.json") ))

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
    --argjson age_medium "$_age_medium" \
    --argjson age_slow "$_age_slow" \
    --argjson age_genre "$_age_genre" \
    --argjson age_content "$_age_content" \
    --argjson storage_report_ts "${storage_report_ts:-0}" \
    --argjson catalog_ts "${catalog_ts:-0}" \
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
        decades: $decades,
        cache_ages: { medium_s: $age_medium, slow_s: $age_slow, genre_s: $age_genre, content_s: $age_content },
        storage_report_ts: $storage_report_ts,
        catalog_ts: $catalog_ts
    }' > "$OUTPUT.tmp" && mv "$OUTPUT.tmp" "$OUTPUT"
