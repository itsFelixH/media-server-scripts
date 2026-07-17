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
Previous snapshot saved as library-catalog.prev.json for diffing.
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
PREV_CATALOG="$REPORT_DIR/library-catalog.prev.json"

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

# Save previous catalog for diffing
if [ -f "$CATALOG_FILE" ]; then
    cp "$CATALOG_FILE" "$PREV_CATALOG"
fi

# --- Build movie list ---
echo "Scanning movies..."
MOVIE_LIST=()
while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    clean=$(clean_name "$name")
    MOVIE_LIST+=("$clean")
done < <(find "$MOVIES_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
MOVIE_COUNT=${#MOVIE_LIST[@]}
echo "  Found: $MOVIE_COUNT movies"

# --- Build TV show list with season/episode counts ---
echo "Scanning TV shows..."
TV_LIST=()
TV_DETAILS=()
TOTAL_SEASONS=0
TOTAL_EPISODES=0

while IFS= read -r show_dir; do
    [ -d "$show_dir" ] || continue
    show_name=$(clean_name "$(basename "$show_dir")")

    # Count seasons and episodes
    season_count=0
    episode_count=0
    season_info=""

    while IFS= read -r season_dir; do
        [ -d "$season_dir" ] || continue
        season_name=$(basename "$season_dir")
        eps=$(find "$season_dir" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" \) 2>/dev/null | wc -l)
        season_count=$((season_count + 1))
        episode_count=$((episode_count + eps))
        season_info+="    - $season_name ($eps episodes)\n"
    done < <(find "$show_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

    TOTAL_SEASONS=$((TOTAL_SEASONS + season_count))
    TOTAL_EPISODES=$((TOTAL_EPISODES + episode_count))
    TV_LIST+=("$show_name")
    TV_DETAILS+=("$show_name|$season_count|$episode_count|$season_info")
done < <(find "$TV_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
TV_COUNT=${#TV_LIST[@]}
echo "  Found: $TV_COUNT shows, $TOTAL_SEASONS seasons, $TOTAL_EPISODES episodes"
echo

# --- Generate JSON catalog ---
echo "Generating catalog..."

# Build movies JSON array
MOVIES_JSON=$(printf '%s\n' "${MOVIE_LIST[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')

# Build TV shows JSON array
TV_JSON="[]"
for detail in "${TV_DETAILS[@]}"; do
    IFS='|' read -r name seasons eps info <<< "$detail"
    TV_JSON=$(echo "$TV_JSON" | jq --arg name "$name" --argjson seasons "$seasons" --argjson episodes "$eps" \
        '. + [{"name": $name, "seasons": $seasons, "episodes": $episodes}]')
done

# Write catalog JSON
jq -n \
    --argjson version 1 \
    --arg type "library-catalog" \
    --arg generated "$(date -Iseconds)" \
    --argjson movie_count "$MOVIE_COUNT" \
    --argjson tv_count "$TV_COUNT" \
    --argjson total_seasons "$TOTAL_SEASONS" \
    --argjson total_episodes "$TOTAL_EPISODES" \
    --argjson movies "$MOVIES_JSON" \
    --argjson shows "$TV_JSON" \
    '{
        version: $version,
        type: $type,
        generated: $generated,
        duration_seconds: 0,
        summary: {
            movies: $movie_count,
            tv_shows: $tv_count,
            seasons: $total_seasons,
            episodes: $total_episodes
        },
        data: {
            movies: $movies,
            shows: $shows
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

if [ -f "$PREV_CATALOG" ]; then
    echo "Comparing with previous catalog..."

    # Extract movie lists from both catalogs using jq
    PREV_MOVIES=$(jq -r '(.data.movies // .movies)[]' "$PREV_CATALOG" 2>/dev/null | sort)
    CURR_MOVIES=$(printf '%s\n' "${MOVIE_LIST[@]}" | sort)

    while IFS= read -r movie; do
        [ -z "$movie" ] && continue
        ADDED_MOVIES+=("$movie")
    done < <(comm -13 <(echo "$PREV_MOVIES") <(echo "$CURR_MOVIES"))

    while IFS= read -r movie; do
        [ -z "$movie" ] && continue
        REMOVED_MOVIES+=("$movie")
    done < <(comm -23 <(echo "$PREV_MOVIES") <(echo "$CURR_MOVIES"))

    # Extract TV show names
    PREV_SHOWS=$(jq -r '(.data.shows // .shows)[].name' "$PREV_CATALOG" 2>/dev/null | sort)
    CURR_SHOWS=$(printf '%s\n' "${TV_LIST[@]}" | sort)

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
        for detail in "${TV_DETAILS[@]}"; do
            IFS='|' read -r curr_name curr_seasons curr_eps curr_info <<< "$detail"
            if [ "$curr_name" = "$prev_name" ]; then
                if [ "$curr_seasons" -gt "$prev_seasons" ]; then
                    new_count=$((curr_seasons - prev_seasons))
                    NEW_SEASONS+=("$curr_name (+$new_count season(s), now $curr_seasons)")
                elif [ "$curr_eps" -gt "$prev_episodes" ]; then
                    new_eps=$((curr_eps - prev_episodes))
                    NEW_EPISODES+=("$curr_name (+$new_eps episode(s), now $curr_eps)")
                fi
                break
            fi
        done
    done < <(jq -r '(.data.shows // .shows)[] | "\(.name)\t\(.seasons)\t\(.episodes)"' "$PREV_CATALOG" 2>/dev/null)

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

if [ -f "$PREV_CATALOG" ]; then
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
if [ -f "$PREV_CATALOG" ]; then
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

# Only notify if there were changes or no previous catalog
if [ ! -f "$PREV_CATALOG" ] || [ -n "$CHANGES" ]; then
    HAS_REMOVALS=false
    [ ${#REMOVED_MOVIES[@]} -gt 0 ] && HAS_REMOVALS=true
    [ ${#REMOVED_SHOWS[@]} -gt 0 ] && HAS_REMOVALS=true

    if [ "$HAS_REMOVALS" = true ]; then
        discord_notify "warning" "📚 Library Catalog" "$DISCORD_DESC"
    else
        discord_notify "success" "📚 Library Catalog" "$DISCORD_DESC"
    fi
fi
