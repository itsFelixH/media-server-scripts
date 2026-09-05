#!/bin/bash
# Library Catalog
# Generates a snapshot of the media library content.
# Exports to JSON, diffs against previous snapshot, posts summary to Discord.
#
# Usage:
#   ./library-catalog.sh [options]
#
# Options:
#   -h, --help        Show this help message
#   -q, --quiet       Suppress terminal output (log only)
#   --no-discord      Skip Discord notification

####### HELP #######
show_help() {
    cat <<'HELP'
Library Catalog — Generates a snapshot of your media library.

Usage: library-catalog.sh [options]

Creates a JSON catalog of all movies and TV shows in your library.
Compares against the previous snapshot to show what was added/removed.
Posts a summary to Discord.

Options:
  -h, --help        Show this help message
  -q, --quiet       Suppress terminal output (log only)
  --no-discord      Skip Discord notification

Output: ~/kometa/scripts/reports/library-catalog.json (overwritten each run)
Weekly baseline saved as library-catalog.baseline.json for comparison.
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

LOG_FILE="$LOG_DIR/library-catalog/library-catalog_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR/library-catalog"

CATALOG_FILE="$REPORT_DIR/library-catalog.json"
BASELINE_FILE="$REPORT_DIR/library-catalog.baseline.json"

# Redirect output
if [ "$QUIET" = true ]; then
    exec > "$LOG_FILE" 2>&1
else
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

# Discord — webhooks and limits loaded from config.sh

####### DEPENDENCY CHECK #######
MISSING_DEPS=()
command -v jq &>/dev/null || MISSING_DEPS+=("jq")
command -v curl &>/dev/null || MISSING_DEPS+=("curl")

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "ERROR: Missing required dependencies:"
    for dep in "${MISSING_DEPS[@]}"; do echo "  - $dep"; done
    exit 1
fi

####### FUNCTIONS #######
SCRIPT_NAME="library-catalog.sh"

# Clean folder name (strip tmdb tags and quality info)
clean_name() {
    printf '%s' "$1" | sed 's/ {tmdb-[0-9]*}//g; s/ \[.*\]//g'
}

####### MAIN #######
START_TIME=$(date +%s)
echo "=== Library Catalog ==="
echo "Movies: $MOVIES_DIR"
echo "TV Shows: $TV_DIR"
echo

# Update weekly baseline (only if older than 7 days or doesn't exist)
BASELINE_STALE=false
if [ ! -f "$BASELINE_FILE" ]; then
    BASELINE_STALE=true
elif [ -f "$BASELINE_FILE" ]; then
    _baseline_age=$(( $(date +%s) - $(stat -c %Y "$BASELINE_FILE") ))
    [ "$_baseline_age" -gt 604800 ] && BASELINE_STALE=true
fi
if [ "$BASELINE_STALE" = true ] && [ -f "$CATALOG_FILE" ]; then
    cp "$CATALOG_FILE" "$BASELINE_FILE"
fi

# --- Build movie list ---
echo "Scanning movies..."
MOVIES_TMP=$(mktemp)
trap 'rm -f "$MOVIES_TMP"' EXIT

while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    clean=$(clean_name "$name")
    # Extract year from name pattern like "Movie Name (2024)"
    year=$(echo "$clean" | grep -oP '\((\d{4})\)' | tail -1 | tr -d '()')
    # Strip year from display name
    display_name=$(echo "$clean" | sed 's/ ([0-9]\{4\})$//')
    # Get size
    size_bytes=$(du -sb "$dir" 2>/dev/null | cut -f1)
    size_bytes=${size_bytes:-0}
    printf '%s\t%s\t%s\n' "$display_name" "${year:-0}" "$size_bytes" >> "$MOVIES_TMP"
done < <(find "$MOVIES_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
MOVIE_COUNT=$(wc -l < "$MOVIES_TMP" | tr -d ' ')
echo "  Found: $MOVIE_COUNT movies"

# --- Build TV show list with season/episode counts ---
echo "Scanning TV shows..."
TV_TMP=$(mktemp)
TV_SEASONS_TMP=$(mktemp)
trap 'rm -f "$MOVIES_TMP" "$TV_TMP" "$TV_SEASONS_TMP"' EXIT

TOTAL_SEASONS=0
TOTAL_EPISODES=0

while IFS= read -r show_dir; do
    [ -d "$show_dir" ] || continue
    show_name=$(clean_name "$(basename "$show_dir")")
    # Extract year
    year=$(echo "$show_name" | grep -oP '\((\d{4})\)' | tail -1 | tr -d '()')
    display_name=$(echo "$show_name" | sed 's/ ([0-9]\{4\})$//')

    # Count seasons and episodes, collect per-season data
    season_count=0
    episode_count=0

    while IFS= read -r season_dir; do
        [ -d "$season_dir" ] || continue
        season_name=$(basename "$season_dir")
        # Extract season number
        season_num=$(echo "$season_name" | grep -oP '[0-9]+' | head -1)
        [ -z "$season_num" ] && season_num="0"
        eps=$(find "$season_dir" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" \) 2>/dev/null | wc -l)
        season_count=$((season_count + 1))
        episode_count=$((episode_count + eps))
        # Record: show_name \t season_num \t episodes
        printf '%s\t%s\t%s\n' "$display_name" "$season_num" "$eps" >> "$TV_SEASONS_TMP"
    done < <(find "$show_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

    # Get total size
    size_bytes=$(du -sb "$show_dir" 2>/dev/null | cut -f1)
    size_bytes=${size_bytes:-0}

    TOTAL_SEASONS=$((TOTAL_SEASONS + season_count))
    TOTAL_EPISODES=$((TOTAL_EPISODES + episode_count))
    printf '%s\t%s\t%s\t%s\t%s\n' "$display_name" "${year:-0}" "$season_count" "$episode_count" "$size_bytes" >> "$TV_TMP"
done < <(find "$TV_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
TV_COUNT=$(wc -l < "$TV_TMP" | tr -d ' ')
echo "  Found: $TV_COUNT shows, $TOTAL_SEASONS seasons, $TOTAL_EPISODES episodes"
echo

# --- Generate JSON catalog ---
echo "Generating catalog..."

# Build movies JSON array (structured with name, year, size_bytes)
MOVIES_JSON=$(jq -R -s '
    split("\n") | map(select(length > 0)) | map(
        split("\t") | {
            name: .[0],
            year: (.[1] | tonumber | if . == 0 then null else . end),
            size_bytes: (.[2] | tonumber)
        }
    )' < "$MOVIES_TMP")

# Build TV shows JSON array with season_list
TV_JSON=$(jq -R -s '
    split("\n") | map(select(length > 0)) | map(
        split("\t") | {
            name: .[0],
            year: (.[1] | tonumber | if . == 0 then null else . end),
            seasons: (.[2] | tonumber),
            episodes: (.[3] | tonumber),
            size_bytes: (.[4] | tonumber)
        }
    )' < "$TV_TMP")

# Build season_list per show from TV_SEASONS_TMP
SEASON_LIST_JSON=$(jq -R -s '
    split("\n") | map(select(length > 0)) | map(split("\t") | {show: .[0], season: (.[1] | tonumber), episodes: (.[2] | tonumber)}) |
    group_by(.show) | map({key: .[0].show, value: (map({season: .season, episodes: .episodes}) | sort_by(.season))}) | from_entries
' < "$TV_SEASONS_TMP")

# Merge season_list into TV_JSON
TV_JSON=$(echo "$TV_JSON" | jq --argjson sl "$SEASON_LIST_JSON" '
    map(. + {season_list: ($sl[.name] // [])})
')

# Compute total_size_bytes (all movies + all shows)
TOTAL_SIZE_BYTES=$(echo "$MOVIES_JSON" "$TV_JSON" | jq -s '
    (.[0] | map(.size_bytes) | add // 0) + (.[1] | map(.size_bytes) | add // 0)
')

# Compute decade distribution
DECADES_JSON=$(echo "$MOVIES_JSON" "$TV_JSON" | jq -s '
    (.[0] + .[1]) | map(select(.year != null) | .year - (.year % 10)) |
    group_by(.) | map({decade: (.[0] | tostring + "s"), count: length}) | sort_by(.decade)
')

# --- Added date tracking ---
# Load existing added_dates from current report (persist across runs)
ADDED_DATES_JSON='{}'
if [ -f "$CATALOG_FILE" ]; then
    ADDED_DATES_JSON=$(jq -r '.data.added_dates // {}' "$CATALOG_FILE" 2>/dev/null || echo '{}')
    [ "$ADDED_DATES_JSON" = "null" ] && ADDED_DATES_JSON='{}'
elif [ -f "$BASELINE_FILE" ]; then
    ADDED_DATES_JSON=$(jq -r '.data.added_dates // {}' "$BASELINE_FILE" 2>/dev/null || echo '{}')
    [ "$ADDED_DATES_JSON" = "null" ] && ADDED_DATES_JSON='{}'
fi

# Add today's date for any new entries not already tracked
TODAY=$(date +%Y-%m-%d)
NEW_MOVIE_NAMES=$(echo "$MOVIES_JSON" | jq -r '.[].name')
NEW_SHOW_NAMES=$(echo "$TV_JSON" | jq -r '.[].name')

# Merge: keep existing dates, add today for new ones
ADDED_DATES_JSON=$(echo "$ADDED_DATES_JSON" | jq --arg today "$TODAY" --argjson movies "$(echo "$NEW_MOVIE_NAMES" | jq -R -s 'split("\n") | map(select(length > 0))')" --argjson shows "$(echo "$NEW_SHOW_NAMES" | jq -R -s 'split("\n") | map(select(length > 0))')" '
    . as $existing |
    ($movies + $shows) | reduce .[] as $name ($existing;
        if .[$name] then . else . + {($name): $today} end
    )
')

# Build recent additions (items added in the last 30 days)
RECENT_JSON=$(echo "$ADDED_DATES_JSON" | jq --arg cutoff "$(date -d '30 days ago' +%Y-%m-%d)" '
    to_entries | map(select(.value >= $cutoff)) | sort_by(.value) | reverse | map({name: .key, added: .value})
')

# Write catalog JSON
jq -n \
    --argjson version 1 \
    --arg type "library-catalog" \
    --arg generated "$(date -Iseconds)" \
    --arg generated_by "$SCRIPT_NAME" \
    --argjson movie_count "$MOVIE_COUNT" \
    --argjson tv_count "$TV_COUNT" \
    --argjson total_seasons "$TOTAL_SEASONS" \
    --argjson total_episodes "$TOTAL_EPISODES" \
    --argjson total_size_bytes "$TOTAL_SIZE_BYTES" \
    --argjson movies "$MOVIES_JSON" \
    --argjson shows "$TV_JSON" \
    --argjson decades "$DECADES_JSON" \
    --argjson added_dates "$ADDED_DATES_JSON" \
    --argjson recent "$RECENT_JSON" \
    '{
        version: $version,
        type: $type,
        generated: $generated,
        generated_by: $generated_by,
        duration_seconds: 0,
        health: {status: "ok", message: "Catalog generated successfully"},
        summary: {
            movies: $movie_count,
            tv_shows: $tv_count,
            seasons: $total_seasons,
            episodes: $total_episodes,
            total_size_bytes: $total_size_bytes
        },
        data: {
            movies: $movies,
            shows: $shows,
            decades: $decades,
            added_dates: $added_dates,
            recent: $recent
        },
        comparison: null
    }' > "$CATALOG_FILE"

echo "  Saved: $CATALOG_FILE"
echo

# --- Diff against previous snapshot ---
ADDED_MOVIES=()
REMOVED_MOVIES=()
ADDED_SHOWS=()
REMOVED_SHOWS=()
NEW_SEASONS=()
NEW_EPISODES=()

if [ -f "$BASELINE_FILE" ]; then
    echo "Comparing with weekly baseline..."

    # Extract movie names from baseline
    PREV_MOVIES=$(jq -r '(.data.movies // .movies)[] | if type == "object" then .name else . end' "$BASELINE_FILE" 2>/dev/null | sort)
    CURR_MOVIES=$(echo "$MOVIES_JSON" | jq -r '.[].name' | sort)

    while IFS= read -r movie; do
        [ -z "$movie" ] && continue
        ADDED_MOVIES+=("$movie")
    done < <(comm -13 <(echo "$PREV_MOVIES") <(echo "$CURR_MOVIES"))

    while IFS= read -r movie; do
        [ -z "$movie" ] && continue
        REMOVED_MOVIES+=("$movie")
    done < <(comm -23 <(echo "$PREV_MOVIES") <(echo "$CURR_MOVIES"))

    # Extract TV show names
    PREV_SHOWS=$(jq -r '(.data.shows // .shows)[].name' "$BASELINE_FILE" 2>/dev/null | sort)
    CURR_SHOWS=$(echo "$TV_JSON" | jq -r '.[].name' | sort)

    while IFS= read -r show; do
        [ -z "$show" ] && continue
        ADDED_SHOWS+=("$show")
    done < <(comm -13 <(echo "$PREV_SHOWS") <(echo "$CURR_SHOWS"))

    while IFS= read -r show; do
        [ -z "$show" ] && continue
        REMOVED_SHOWS+=("$show")
    done < <(comm -23 <(echo "$PREV_SHOWS") <(echo "$CURR_SHOWS"))

    # Detect new seasons and new episodes for existing shows
    while IFS=$'\t' read -r prev_name prev_seasons prev_episodes; do
        [ -z "$prev_name" ] && continue
        # Look up current show in TV_JSON
        curr_seasons=$(echo "$TV_JSON" | jq -r --arg name "$prev_name" '.[] | select(.name == $name) | .seasons')
        curr_eps=$(echo "$TV_JSON" | jq -r --arg name "$prev_name" '.[] | select(.name == $name) | .episodes')
        [ -z "$curr_seasons" ] || [ "$curr_seasons" = "null" ] && continue
        if [ "$curr_seasons" -gt "$prev_seasons" ] 2>/dev/null; then
            new_count=$((curr_seasons - prev_seasons))
            NEW_SEASONS+=("$prev_name (+$new_count season(s), now $curr_seasons)")
        elif [ "$curr_eps" -gt "$prev_episodes" ] 2>/dev/null; then
            new_eps=$((curr_eps - prev_episodes))
            NEW_EPISODES+=("$prev_name (+$new_eps episode(s), now $curr_eps)")
        fi
    done < <(jq -r '(.data.shows // .shows)[] | "\(.name)\t\(.seasons)\t\(.episodes)"' "$BASELINE_FILE" 2>/dev/null)

    echo "  Added movies: ${#ADDED_MOVIES[@]}"
    echo "  Removed movies: ${#REMOVED_MOVIES[@]}"
    echo "  Added shows: ${#ADDED_SHOWS[@]}"
    echo "  Removed shows: ${#REMOVED_SHOWS[@]}"
    echo "  New seasons: ${#NEW_SEASONS[@]}"
    echo "  New episodes: ${#NEW_EPISODES[@]}"

    if [ ${#ADDED_MOVIES[@]} -gt 0 ]; then
        echo "  New movies:"
        for m in "${ADDED_MOVIES[@]}"; do echo "    + $m"; done
    fi
    if [ ${#REMOVED_MOVIES[@]} -gt 0 ]; then
        echo "  Removed movies:"
        for m in "${REMOVED_MOVIES[@]}"; do echo "    - $m"; done
    fi
    if [ ${#ADDED_SHOWS[@]} -gt 0 ]; then
        echo "  New shows:"
        for s in "${ADDED_SHOWS[@]}"; do echo "    + $s"; done
    fi
    if [ ${#REMOVED_SHOWS[@]} -gt 0 ]; then
        echo "  Removed shows:"
        for s in "${REMOVED_SHOWS[@]}"; do echo "    - $s"; done
    fi
    if [ ${#NEW_SEASONS[@]} -gt 0 ]; then
        echo "  New seasons:"
        for s in "${NEW_SEASONS[@]}"; do echo "    ↑ $s"; done
    fi
    if [ ${#NEW_EPISODES[@]} -gt 0 ]; then
        echo "  New episodes:"
        for s in "${NEW_EPISODES[@]}"; do echo "    ↑ $s"; done
    fi
else
    echo "No previous catalog found (first run)."
fi
echo

# --- Summary and Discord ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "=== Catalog Complete ==="
echo "Duration: ${DURATION}s"
echo "Log saved to: $LOG_FILE"

# Append changes to JSON catalog
# First, update duration now that we know it
jq --argjson dur "$DURATION" '.duration_seconds = $dur' "$CATALOG_FILE" > "$CATALOG_FILE.tmp" && mv "$CATALOG_FILE.tmp" "$CATALOG_FILE"

if [ -f "$BASELINE_FILE" ]; then
    HAS_CHANGES=false
    [ ${#ADDED_MOVIES[@]} -gt 0 ] && HAS_CHANGES=true
    [ ${#REMOVED_MOVIES[@]} -gt 0 ] && HAS_CHANGES=true
    [ ${#ADDED_SHOWS[@]} -gt 0 ] && HAS_CHANGES=true
    [ ${#REMOVED_SHOWS[@]} -gt 0 ] && HAS_CHANGES=true
    [ ${#NEW_SEASONS[@]} -gt 0 ] && HAS_CHANGES=true
    [ ${#NEW_EPISODES[@]} -gt 0 ] && HAS_CHANGES=true

    if [ "$HAS_CHANGES" = true ]; then
        ADDED_MOVIES_JSON=$(printf '%s\n' "${ADDED_MOVIES[@]}" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))')
        REMOVED_MOVIES_JSON=$(printf '%s\n' "${REMOVED_MOVIES[@]}" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))')
        ADDED_SHOWS_JSON=$(printf '%s\n' "${ADDED_SHOWS[@]}" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))')
        REMOVED_SHOWS_JSON=$(printf '%s\n' "${REMOVED_SHOWS[@]}" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))')
        NEW_SEASONS_JSON=$(printf '%s\n' "${NEW_SEASONS[@]}" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))')
        NEW_EPISODES_JSON=$(printf '%s\n' "${NEW_EPISODES[@]}" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))')

        # Update the catalog file with comparison
        jq --argjson added_movies "${ADDED_MOVIES_JSON:-[]}" \
           --argjson removed_movies "${REMOVED_MOVIES_JSON:-[]}" \
           --argjson added_shows "${ADDED_SHOWS_JSON:-[]}" \
           --argjson removed_shows "${REMOVED_SHOWS_JSON:-[]}" \
           --argjson new_seasons "${NEW_SEASONS_JSON:-[]}" \
           --argjson new_episodes "${NEW_EPISODES_JSON:-[]}" \
           '.comparison = {
               has_changes: true,
               added_movies: $added_movies,
               removed_movies: $removed_movies,
               added_shows: $added_shows,
               removed_shows: $removed_shows,
               new_seasons: $new_seasons,
               new_episodes: $new_episodes
           }' "$CATALOG_FILE" > "$CATALOG_FILE.tmp" && mv "$CATALOG_FILE.tmp" "$CATALOG_FILE"
    fi
fi

echo "Catalog saved to: $CATALOG_FILE"

# Build Discord message
DISCORD_DESC="**$MOVIE_COUNT** movies · **$TV_COUNT** shows · **$TOTAL_EPISODES** episodes"

# Add diff info if available
if [ -f "$BASELINE_FILE" ]; then
    CHANGES=""
    [ ${#ADDED_MOVIES[@]} -gt 0 ] && CHANGES+="📥 ${#ADDED_MOVIES[@]} movies  "
    [ ${#ADDED_SHOWS[@]} -gt 0 ] && CHANGES+="📥 ${#ADDED_SHOWS[@]} shows  "
    [ ${#NEW_SEASONS[@]} -gt 0 ] && CHANGES+="📺 ${#NEW_SEASONS[@]} seasons  "
    [ ${#NEW_EPISODES[@]} -gt 0 ] && CHANGES+="🎞️ ${#NEW_EPISODES[@]} episodes  "
    [ ${#REMOVED_MOVIES[@]} -gt 0 ] && CHANGES+="📤 ${#REMOVED_MOVIES[@]} removed  "

    if [ -n "$CHANGES" ]; then
        DISCORD_DESC+="

$CHANGES"
        # Show new titles (combined, max 8 lines)
        NEW_TITLES=""
        [ ${#ADDED_MOVIES[@]} -gt 0 ] && NEW_TITLES+="$(printf '%s\n' "${ADDED_MOVIES[@]}" | head -4)"$'\n'
        [ ${#ADDED_SHOWS[@]} -gt 0 ] && NEW_TITLES+="$(printf '%s\n' "${ADDED_SHOWS[@]}" | head -4)"$'\n'
        if [ -n "$NEW_TITLES" ]; then
            DISCORD_DESC+="
\`\`\`
${NEW_TITLES%$'\n'}
\`\`\`"
        fi
    else
        DISCORD_DESC+="
No changes since last run."
    fi
fi

# Only notify if there were changes or no baseline
if [ ! -f "$BASELINE_FILE" ] || [ -n "$CHANGES" ]; then
    HAS_REMOVALS=false
    [ ${#REMOVED_MOVIES[@]} -gt 0 ] && HAS_REMOVALS=true
    [ ${#REMOVED_SHOWS[@]} -gt 0 ] && HAS_REMOVALS=true

    if [ "$HAS_REMOVALS" = true ]; then
        discord_notify "warning" "📚 Library Catalog" "$DISCORD_DESC"
    else
        discord_notify "success" "📚 Library Catalog" "$DISCORD_DESC"
    fi
fi
