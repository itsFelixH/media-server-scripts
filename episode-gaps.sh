#!/bin/bash
# episode-gaps.sh — Find TV shows with missing episodes
# Compares Plex episode counts against TMDB aired episodes.
# Reports shows where you have fewer episodes than have actually aired.
#
# Usage:
#   bash episode-gaps.sh [options]
#
# Options:
#   -q, --quiet       Suppress terminal output (for cron)
#   --no-discord      Skip Discord notifications
#   -h, --help        Show this help
#
# Output:
#   Report: ~/kometa/scripts/reports/episode-gaps.json
#   Log:    ~/kometa/scripts/logs/episode-gaps/episode-gaps_YYYYMMDD_HHMMSS.log
#
# Schedule suggestion: weekly (e.g. Sundays at 03:00)

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

SCRIPT_NAME="episode-gaps.sh"
START_TIME=$(date +%s)
TODAY=$(date +%Y-%m-%d)

# --- Options ---
QUIET=false
NO_DISCORD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -q|--quiet) QUIET=true; shift ;;
        --no-discord) NO_DISCORD=true; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) shift ;;
    esac
done

# --- Setup logging ---
SCRIPT_LOG_DIR="$LOG_DIR/episode-gaps"
mkdir -p "$SCRIPT_LOG_DIR"
LOG_FILE="$SCRIPT_LOG_DIR/episode-gaps_$(date +%Y%m%d_%H%M%S).log"

log() {
    local msg="$1"
    echo "$msg" >> "$LOG_FILE"
    [ "$QUIET" = false ] && echo "$msg"
}

# --- Dependencies ---
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        log "ERROR: $cmd is required but not installed."
        exit 1
    fi
done

# --- TMDB API ---
TMDB_KEY="6d32d887bcfd246d796970654c83b804"
TMDB_BASE="https://api.themoviedb.org/3"

# Rate limit: TMDB allows ~40 requests per 10 seconds
# We add a small delay between show lookups
TMDB_DELAY=0.3

tmdb_api() {
    local endpoint="$1"
    curl -s --max-time 10 "${TMDB_BASE}${endpoint}?api_key=${TMDB_KEY}" 2>/dev/null
}

# --- Plex API ---
plex_api() {
    local endpoint="$1"
    local separator="?"
    [[ "$endpoint" == *"?"* ]] && separator="&"
    curl -s --max-time 10 "${PLEX_URL}${endpoint}${separator}X-Plex-Token=${PLEX_TOKEN}" -H "Accept: application/json" 2>/dev/null
}

# --- Main ---
log "=== Episode Gaps Report ==="
log "Date: $(date '+%Y-%m-%d %H:%M:%S')"
log "Comparing Plex TV Shows against TMDB aired episodes"
log ""

# Get all TV shows from Plex
log "Fetching TV shows from Plex..."
PLEX_SHOWS=$(plex_api "/library/sections/5/all?includeGuids=1")

if [ -z "$PLEX_SHOWS" ] || ! echo "$PLEX_SHOWS" | jq . >/dev/null 2>&1; then
    log "ERROR: Failed to fetch TV shows from Plex"
    discord_notify "error" "❌ Episode Gaps Failed" "Could not connect to Plex API."
    exit 1
fi

TOTAL_SHOWS=$(echo "$PLEX_SHOWS" | jq '.MediaContainer.Metadata | length')
log "Found $TOTAL_SHOWS shows in Plex"
log ""

# Extract show data: title, ratingKey, tmdb_id
SHOW_LIST=$(echo "$PLEX_SHOWS" | jq -r '
    .MediaContainer.Metadata[] |
    (.Guid // []) as $guids |
    ($guids | map(select(.id | startswith("tmdb://"))) | .[0].id // "" | sub("tmdb://"; "")) as $tmdb |
    select($tmdb != "") |
    "\(.ratingKey)\t\($tmdb)\t\(.title)\t\(.year // "")"
')

SHOWS_WITH_TMDB=$(echo "$SHOW_LIST" | wc -l)
log "Shows with TMDB ID: $SHOWS_WITH_TMDB"
log ""

# Process each show
GAPS_JSON="[]"
PROCESSED=0
SHOWS_WITH_GAPS=0
TOTAL_MISSING=0
SKIPPED=0
ERRORS=0

while IFS=$'\t' read -r rating_key tmdb_id title year; do
    [ -z "$tmdb_id" ] && continue
    ((PROCESSED++))

    [ "$QUIET" = false ] && printf "\r  Processing: %d/%d - %s          " "$PROCESSED" "$SHOWS_WITH_TMDB" "$title" >&2

    # Get Plex seasons for this show (skip season 0)
    plex_seasons=$(plex_api "/library/metadata/${rating_key}/children")
    if [ -z "$plex_seasons" ]; then
        ((ERRORS++))
        continue
    fi

    # Build a map of plex season_number -> episode_count (skip specials)
    plex_season_data=$(echo "$plex_seasons" | jq -r '
        .MediaContainer.Metadata[] |
        select(.index > 0) |
        "\(.index)\t\(.leafCount)"
    ')

    # Get TMDB show data
    tmdb_show=$(tmdb_api "/tv/${tmdb_id}")
    if [ -z "$tmdb_show" ] || ! echo "$tmdb_show" | jq -e '.seasons' >/dev/null 2>&1; then
        ((ERRORS++))
        sleep "$TMDB_DELAY"
        continue
    fi

    show_status=$(echo "$tmdb_show" | jq -r '.status // "Unknown"')

    # Get TMDB seasons (skip season 0)
    tmdb_seasons=$(echo "$tmdb_show" | jq -r '.seasons[] | select(.season_number > 0) | "\(.season_number)\t\(.episode_count)\t\(.air_date // "")"')

    # For each TMDB season, check if we need detailed air_date info
    show_has_gaps=false
    show_gaps="[]"

    while IFS=$'\t' read -r season_num tmdb_ep_count season_air_date; do
        [ -z "$season_num" ] && continue

        # Get Plex count for this season
        plex_ep_count=$(echo "$plex_season_data" | awk -F'\t' -v s="$season_num" '$1==s {print $2}')
        [ -z "$plex_ep_count" ] && plex_ep_count=0

        # Skip if Plex already has all or more
        [ "$plex_ep_count" -ge "$tmdb_ep_count" ] && continue

        # Season air date in the future — skip entirely
        if [ -n "$season_air_date" ] && [[ "$season_air_date" > "$TODAY" ]]; then
            continue
        fi

        # Need to check individual episode air dates for partially-aired seasons
        # Fetch season detail from TMDB
        sleep "$TMDB_DELAY"
        season_detail=$(tmdb_api "/tv/${tmdb_id}/season/${season_num}")

        if [ -z "$season_detail" ] || ! echo "$season_detail" | jq -e '.episodes' >/dev/null 2>&1; then
            # Fallback: use the total count from the show endpoint
            aired_count="$tmdb_ep_count"
        else
            # Count only episodes that have aired (air_date <= today)
            aired_count=$(echo "$season_detail" | jq --arg today "$TODAY" '
                [.episodes[] | select(.air_date != null and .air_date != "" and .air_date <= $today)] | length
            ')
        fi

        [ -z "$aired_count" ] || [ "$aired_count" = "null" ] && aired_count=0

        # Compare: only report if Plex has fewer than aired
        if [ "$plex_ep_count" -lt "$aired_count" ] && [ "$aired_count" -gt 0 ]; then
            missing=$(( aired_count - plex_ep_count ))
            ((TOTAL_MISSING += missing))
            show_has_gaps=true
            show_gaps=$(echo "$show_gaps" | jq \
                --argjson season "$season_num" \
                --argjson plex "$plex_ep_count" \
                --argjson aired "$aired_count" \
                --argjson missing "$missing" \
                '. + [{"season": $season, "plex_episodes": $plex, "aired_episodes": $aired, "missing": $missing}]')
        fi

    done <<< "$tmdb_seasons"

    if [ "$show_has_gaps" = true ]; then
        ((SHOWS_WITH_GAPS++))
        total_show_missing=$(echo "$show_gaps" | jq '[.[].missing] | add')
        GAPS_JSON=$(echo "$GAPS_JSON" | jq \
            --arg title "$title" \
            --arg year "${year:-}" \
            --arg tmdb_id "$tmdb_id" \
            --arg status "$show_status" \
            --argjson seasons "$show_gaps" \
            --argjson total_missing "$total_show_missing" \
            --arg url "https://www.themoviedb.org/tv/$tmdb_id" \
            '. + [{
                "title": $title,
                "year": $year,
                "tmdb_id": $tmdb_id,
                "status": $status,
                "url": $url,
                "total_missing": $total_missing,
                "seasons": $seasons
            }]')
    fi

    sleep "$TMDB_DELAY"

done <<< "$SHOW_LIST"

[ "$QUIET" = false ] && echo "" >&2

# Sort by most missing first
GAPS_JSON=$(echo "$GAPS_JSON" | jq 'sort_by(-.total_missing)')

# --- Build report ---
DURATION=$(( $(date +%s) - START_TIME ))

# Determine health status
HEALTH_STATUS="ok"
[ "$SHOWS_WITH_GAPS" -gt 10 ] && HEALTH_STATUS="warning"
[ "$SHOWS_WITH_GAPS" -gt 25 ] && HEALTH_STATUS="error"

REPORT=$(jq -n \
    --arg version "1.0" \
    --arg type "episode-gaps" \
    --arg generated "$(date -Iseconds)" \
    --arg generated_by "$SCRIPT_NAME" \
    --argjson duration_seconds "$DURATION" \
    --arg health_status "$HEALTH_STATUS" \
    --argjson total_shows "$TOTAL_SHOWS" \
    --argjson shows_checked "$SHOWS_WITH_TMDB" \
    --argjson shows_with_gaps "$SHOWS_WITH_GAPS" \
    --argjson total_missing_episodes "$TOTAL_MISSING" \
    --argjson errors "$ERRORS" \
    --arg date "$TODAY" \
    --argjson data "$GAPS_JSON" \
    '{
        version: $version,
        type: $type,
        generated: $generated,
        generated_by: $generated_by,
        duration_seconds: $duration_seconds,
        health: { status: $health_status },
        summary: {
            total_shows: $total_shows,
            shows_checked: $shows_checked,
            shows_with_gaps: $shows_with_gaps,
            total_missing_episodes: $total_missing_episodes,
            errors: $errors,
            date: $date
        },
        data: $data
    }')

# Write report
echo "$REPORT" > "$REPORT_DIR/episode-gaps.json"

log ""
log "=== Results ==="
log "  Shows checked: $SHOWS_WITH_TMDB"
log "  Shows with gaps: $SHOWS_WITH_GAPS"
log "  Total missing episodes: $TOTAL_MISSING"
log "  Errors/skipped: $ERRORS"
log "  Duration: ${DURATION}s"
log ""

# Top 10 shows with most missing
if [ "$SHOWS_WITH_GAPS" -gt 0 ]; then
    log "Top shows with missing episodes:"
    echo "$GAPS_JSON" | jq -r '.[0:10][] | "  \(.title) — \(.total_missing) missing (\(.seasons | map("S\(.season|tostring|if length<2 then "0"+. else . end): \(.missing)") | join(", ")))"' | while read -r line; do
        log "$line"
    done
    log ""
fi

# --- Discord notification ---
if [ "$SHOWS_WITH_GAPS" -gt 0 ]; then
    discord_desc="**${SHOWS_WITH_GAPS}** shows with missing episodes (**${TOTAL_MISSING}** total)\n\n"
    # Top 5 for Discord
    top_shows=$(echo "$GAPS_JSON" | jq -r '.[0:5][] | "• \(.title) — \(.total_missing) ep"')
    discord_desc+="$top_shows"
    [ "$SHOWS_WITH_GAPS" -gt 5 ] && discord_desc+="\n\n… and $((SHOWS_WITH_GAPS - 5)) more"

    discord_notify "warning" "📺 Episode Gaps Found" "$discord_desc"
else
    discord_notify "success" "📺 Episode Gaps — All Complete" "All $SHOWS_WITH_TMDB shows are up to date with TMDB."
fi

log "Report written to: $REPORT_DIR/episode-gaps.json"
