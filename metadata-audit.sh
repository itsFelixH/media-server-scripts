#!/bin/bash
# Metadata Audit
# Checks Kometa metadata files against the actual library content.
# Reports missing entries, duplicates, orphaned metadata, and season/episode gaps.
#
# Usage:
#   ./metadata-audit.sh [options]
#
# Options:
#   -h, --help        Show this help message
#   -q, --quiet       Suppress terminal output (log only)
#   --no-discord      Skip Discord notification

####### HELP #######
show_help() {
    cat <<'HELP'
Metadata Audit — Checks Kometa metadata files against library content.

Usage: metadata-audit.sh [options]

Checks:
  - Entries referencing TMDb/TVDB IDs not in your library (orphaned metadata)
  - Movies/shows in library without metadata entries (missing metadata)
  - Duplicate entries across metadata files
  - Shows with missing seasons or episodes vs what's on disk

Options:
  -h, --help        Show this help message
  -q, --quiet       Suppress terminal output (log only)
  --no-discord      Skip Discord notification
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

TIMESTAMP=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/metadata-audit/metadata-audit_${TIMESTAMP}.log"
REPORT_FILE="$REPORT_DIR/metadata-audit.md"
REPORT_PREV="$REPORT_DIR/metadata-audit.prev.md"
mkdir -p "$LOG_DIR/metadata-audit"

# Log function - writes to both terminal and log file
log() {
    local msg="$1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# Redirect output to log file
if [ "$QUIET" = true ]; then
    exec >> "$LOG_FILE" 2>&1
else
    exec >> "$LOG_FILE" 2>&1
fi

# Discord — webhooks and limits loaded from config.sh

####### DEPENDENCY CHECK #######
MISSING_DEPS=()
command -v jq &>/dev/null || MISSING_DEPS+=("jq")
command -v curl &>/dev/null || MISSING_DEPS+=("curl")
if ! python3 -c "import yaml" 2>/dev/null; then
    MISSING_DEPS+=("python3-yaml (pip install pyyaml)")
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "ERROR: Missing required dependencies:"
    for dep in "${MISSING_DEPS[@]}"; do echo "  - $dep"; done
    exit 1
fi

####### FUNCTIONS #######
send_discord() {
    local webhook="$1" title="$2" description="$3" color="$4"
    [ "$NO_DISCORD" = true ] && return
    if [ ${#description} -gt $DISCORD_DESC_LIMIT ]; then
        description="${description:0:$((DISCORD_DESC_LIMIT - 20))}…

*(truncated)*"
    fi
    local payload
    payload=$(jq -n --arg title "$title" --arg desc "$description" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson color "$color" \
        '{embeds: [{title: $title, description: $desc, color: $color, footer: {text: "'"$FOOTER_PREFIX"' • metadata-audit.sh"}, timestamp: $ts}]}')
    curl -s -H "Content-Type: application/json" -d "$payload" "$webhook" >/dev/null 2>&1
}

# Extract all TMDb IDs from movie files on disk
get_library_movie_ids() {
    find "$MOVIES_DIR" -maxdepth 2 -type f \( -name "*.mkv" -o -name "*.mp4" \) 2>/dev/null | \
        grep -oP '\{tmdb-\K[0-9]+' | sort -u
}

# Extract TV show names from disk (lowercase for comparison, preserve original)
get_library_tv_names() {
    find "$TV_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while read -r dir; do
        basename "$dir" | sed 's/ {tmdb-[0-9]*}//g'
    done | sort -u
}

# Extract show names from metadata comments (preserve original case)
# Handles: "# TVDB id for ShowName. Set by..." and "# ShowName Poster by..."
get_metadata_tv_names() {
    local file="$1"
    grep -P '^\s+\d+:.*#' "$file" 2>/dev/null | \
        sed 's/.*# //;s/ Set by.*//;s/ Poster by.*//;s/TVDB id for //' | \
        sed 's/\. *$//;s/ ([0-9]*)$//' | sort -u
}

# Extract metadata IDs from a YAML file (top-level keys under 'metadata:')
get_metadata_ids() {
    local file="$1"
    python3 -c "
import yaml, sys
with open('$file', 'r') as f:
    data = yaml.safe_load(f)
if data and 'metadata' in data:
    for key in data['metadata']:
        print(key)
" 2>/dev/null
}

# Get episode count on disk for a season
get_disk_episode_count() {
    local season_dir="$1"
    find "$season_dir" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" \) 2>/dev/null | wc -l
}

####### MAIN #######
START_TIME=$(date +%s)
echo "=== Metadata Audit ==="
echo "Metadata dir: $METADATA_DIR"
echo "Movies: $MOVIES_DIR"
echo "TV Shows: $TV_DIR"
echo

ISSUES=()
WARNINGS=()

# --- 1. Collect library content ---
echo "Scanning library..."
mapfile -t LIBRARY_MOVIE_IDS < <(get_library_movie_ids)
mapfile -t LIBRARY_TV_NAMES < <(get_library_tv_names)
echo "  Movies on disk: ${#LIBRARY_MOVIE_IDS[@]}"
echo "  TV shows on disk: ${#LIBRARY_TV_NAMES[@]}"
echo

# --- 2. Collect metadata entries ---
echo "Parsing metadata files..."
MOVIE_META_IDS=()
mapfile -t MOVIE_META_IDS < <(get_metadata_ids "$METADATA_DIR/movies.yml")
echo "  Movie metadata entries: ${#MOVIE_META_IDS[@]}"

TV_META_IDS=()
TV_META_NAMES=()
for yml in "$METADATA_DIR/shows.yml" "$METADATA_DIR/tv/"*.yml; do
    [ -f "$yml" ] || continue
    while read -r id; do
        TV_META_IDS+=("$id")
    done < <(get_metadata_ids "$yml")
    while read -r name; do
        [ -n "$name" ] && TV_META_NAMES+=("$name")
    done < <(get_metadata_tv_names "$yml")
done
echo "  TV metadata entries: ${#TV_META_IDS[@]} (${#TV_META_NAMES[@]} names extracted)"
echo

# --- 3. Check for duplicates ---
echo "Checking for duplicates..."
MOVIE_DUPES=$(printf '%s\n' "${MOVIE_META_IDS[@]}" | sort | uniq -d)
if [ -n "$MOVIE_DUPES" ]; then
    while read -r id; do
        [ -n "$id" ] && ISSUES+=("Duplicate movie metadata: TMDb $id")
    done <<< "$MOVIE_DUPES"
fi

TV_DUPES=$(printf '%s\n' "${TV_META_NAMES[@]}" | sort | uniq -d)
if [ -n "$TV_DUPES" ]; then
    while read -r name; do
        [ -n "$name" ] && ISSUES+=("Duplicate TV metadata: $name")
    done <<< "$TV_DUPES"
fi
DUPE_MOVIE_COUNT=$(echo "$MOVIE_DUPES" | grep -c . 2>/dev/null | tr -d '\n' || echo 0)
DUPE_TV_COUNT=$(echo "$TV_DUPES" | grep -c . 2>/dev/null | tr -d '\n' || echo 0)
echo "  Movie duplicates: $DUPE_MOVIE_COUNT"
echo "  TV duplicates: $DUPE_TV_COUNT"
echo

# --- 4. Orphaned metadata (entries not in library) ---
echo "Checking for orphaned metadata..."
ORPHANED_MOVIES=0
for id in "${MOVIE_META_IDS[@]}"; do
    if ! printf '%s\n' "${LIBRARY_MOVIE_IDS[@]}" | grep -qx "$id"; then
        # Try to resolve the ID to a name from the metadata comment
        movie_name=$(grep -P "^\s+${id}:" "$METADATA_DIR/movies.yml" 2>/dev/null | grep -oP '#\s*\K.*' | sed 's/ Poster by.*//;s/ Set by.*//')
        [ -z "$movie_name" ] && movie_name="TMDb $id"
        WARNINGS+=("Orphaned movie metadata: $movie_name (TMDb $id)")
        ((ORPHANED_MOVIES++))
    fi
done

ORPHANED_TV=0
for name in "${TV_META_NAMES[@]}"; do
    if ! printf '%s\n' "${LIBRARY_TV_NAMES[@]}" | grep -iqxF "$name"; then
        WARNINGS+=("Orphaned TV metadata: $name")
        ((ORPHANED_TV++))
    fi
done
echo "  Orphaned movie entries: $ORPHANED_MOVIES"
echo "  Orphaned TV entries: $ORPHANED_TV"
echo

# --- 5. Missing metadata (library items without metadata) ---
echo "Checking for missing metadata..."
MISSING_MOVIES=0
for id in "${LIBRARY_MOVIE_IDS[@]}"; do
    if ! printf '%s\n' "${MOVIE_META_IDS[@]}" | grep -qx "$id"; then
        movie_name=$(find "$MOVIES_DIR" -maxdepth 2 -type f -name "*{tmdb-${id}}*" 2>/dev/null | head -1 | sed 's/.*\///;s/ {tmdb.*//')
        WARNINGS+=("Missing movie metadata: $movie_name (TMDb $id)")
        ((MISSING_MOVIES++))
    fi
done

MISSING_TV=0
for name in "${LIBRARY_TV_NAMES[@]}"; do
    if ! printf '%s\n' "${TV_META_NAMES[@]}" | grep -iqxF "$name"; then
        WARNINGS+=("Missing TV metadata: $name")
        ((MISSING_TV++))
    fi
done
echo "  Movies without metadata: $MISSING_MOVIES"
echo "  TV shows without metadata: $MISSING_TV"
echo

# --- 6. Check TV seasons/episodes on disk vs metadata ---
# Write results to a temp file to avoid subshell variable loss
echo "Checking TV season/episode coverage..."
SEASON_TMP=$(mktemp)
trap 'rm -f "$SEASON_TMP"' EXIT

# First pass: collect all shows with their metadata seasons
for yml in "$METADATA_DIR/shows.yml" "$METADATA_DIR/tv/"*.yml; do
    [ -f "$yml" ] || continue
    python3 -c "
import yaml, sys
with open('$yml', 'r') as f:
    data = yaml.safe_load(f)
if not data or 'metadata' not in data:
    sys.exit(0)
for show_id, show_data in data['metadata'].items():
    if not isinstance(show_data, dict) or 'seasons' not in show_data:
        continue
    meta_seasons = show_data['seasons']
    if not isinstance(meta_seasons, dict):
        continue
    # Output show_id and all season numbers
    season_nums = sorted([str(s) for s in meta_seasons.keys()])
    print(f'{show_id}|{\" \".join(season_nums)}')
" 2>/dev/null | while IFS='|' read -r show_id meta_season_list; do
        show_dir=$(find "$TV_DIR" -maxdepth 1 -type d -name "*{tmdb-${show_id}}*" 2>/dev/null | head -1)
        [ -z "$show_dir" ] && continue
        
        show_name=$(basename "$show_dir" | sed 's/ {tmdb.*//')
        
        # Get all season folders on disk
        disk_seasons=$(find "$show_dir" -maxdepth 1 -type d \( -name "Season *" -o -name "Staffel *" -o -name "Specials" \) 2>/dev/null | \
            sed 's/.*Season //' | sed 's/.*Staffel //' | sed 's/Specials/0/' | sort -n | uniq)
        
        # Check for missing seasons
        for meta_season in $meta_season_list; do
            if ! echo "$disk_seasons" | grep -qx "$meta_season"; then
                echo "ISSUE:$show_name S$(printf '%02d' "$meta_season") — season folder missing on disk" >> "$SEASON_TMP"
            fi
        done
    done
done

# Second pass: check episodes within seasons that exist
for yml in "$METADATA_DIR/shows.yml" "$METADATA_DIR/tv/"*.yml; do
    [ -f "$yml" ] || continue
    python3 -c "
import yaml, sys
with open('$yml', 'r') as f:
    data = yaml.safe_load(f)
if not data or 'metadata' not in data:
    sys.exit(0)
for show_id, show_data in data['metadata'].items():
    if not isinstance(show_data, dict) or 'seasons' not in show_data:
        continue
    meta_seasons = show_data['seasons']
    if not isinstance(meta_seasons, dict):
        continue
    for season_num, season_data in meta_seasons.items():
        if not isinstance(season_data, dict) or 'episodes' not in season_data:
            continue
        episodes = season_data['episodes']
        if not isinstance(episodes, dict):
            continue
        ep_nums = sorted([int(ep) for ep in episodes.keys() if isinstance(ep, (int, str)) and str(ep).isdigit()])
        meta_ep_list = ','.join(map(str, ep_nums))
        print(f'{show_id}\t{season_num}\t{meta_ep_list}')
" 2>/dev/null | while IFS=$'\t' read -r show_id season_num meta_ep_list; do
        # Find the show directory on disk (uses tmdb ID in folder name)
        show_dir=$(find "$TV_DIR" -maxdepth 1 -type d -name "*{tmdb-${show_id}}*" 2>/dev/null | head -1)
        [ -z "$show_dir" ] && continue

        # Find the season directory (try various naming patterns)
        season_dir=""
        for pattern in "Season $(printf '%02d' "$season_num")" "Season $season_num" "Staffel $(printf '%02d' "$season_num")" "Staffel $season_num" "Specials"; do
            found=$(find "$show_dir" -maxdepth 1 -type d -name "$pattern" 2>/dev/null | head -1)
            if [ -n "$found" ]; then
                season_dir="$found"
                break
            fi
        done

        show_name=$(basename "$show_dir" | sed 's/ {tmdb.*//')

        if [ -z "$season_dir" ]; then
            echo "ISSUE:$show_name S$(printf '%02d' "$season_num") — metadata exists but season folder missing" >> "$SEASON_TMP"
            continue
        fi

        # Extract episode numbers from disk files
        disk_ep_nums=$(find "$season_dir" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" \) 2>/dev/null | \
            grep -oP '(?:e|ep)\K[0-9]+' | sort -n | uniq)
        disk_ep_array=($disk_ep_nums)
        disk_ep_count=${#disk_ep_array[@]}
        
        # Convert metadata episode list to array
        meta_ep_array=(${meta_ep_list//,/ })
        meta_ep_count=${#meta_ep_array[@]}

        if [ "$disk_ep_count" -gt "$meta_ep_count" ]; then
            echo "WARNING:$show_name S$(printf '%02d' "$season_num") — $disk_ep_count eps on disk, only $meta_ep_count in metadata" >> "$SEASON_TMP"
        elif [ "$disk_ep_count" -lt "$meta_ep_count" ]; then
            # Find missing episodes
            declare -A disk_eps_map
            for ep in "${disk_ep_array[@]}"; do
                disk_eps_map[$ep]=1
            done
            
            missing_eps=()
            for ep in "${meta_ep_array[@]}"; do
                [ -z "${disk_eps_map[$ep]}" ] && missing_eps+=("$ep")
            done
            
            missing_str=$(IFS=, ; echo "${missing_eps[*]}")
            echo "ISSUE:$show_name S$(printf '%02d' "$season_num") — missing episodes: $missing_str (metadata has $meta_ep_count, disk has $disk_ep_count)" >> "$SEASON_TMP"
        fi
    done
done

# Read season results back into arrays (avoids subshell issue)
SEASON_ISSUE_COUNT=0
SEASON_WARNING_COUNT=0
if [ -s "$SEASON_TMP" ]; then
    while IFS= read -r line; do
        type="${line%%:*}"
        msg="${line#*:}"
        if [ "$type" = "ISSUE" ]; then
            ISSUES+=("$msg")
            ((SEASON_ISSUE_COUNT++))
        else
            WARNINGS+=("$msg")
            ((SEASON_WARNING_COUNT++))
        fi
        echo "  $msg"
    done < "$SEASON_TMP"
fi
echo "  Season issues: $SEASON_ISSUE_COUNT"
echo "  Episode gaps: $SEASON_WARNING_COUNT"
echo

# --- 7. Summary ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

ISSUE_COUNT=${#ISSUES[@]}
WARNING_COUNT=${#WARNINGS[@]}

echo "=== Audit Summary ==="
echo "Duration: ${DURATION}s"
echo "Issues (errors): $ISSUE_COUNT"
echo "Warnings: $WARNING_COUNT"
echo

if [ "$ISSUE_COUNT" -gt 0 ]; then
    echo "Issues:"
    for issue in "${ISSUES[@]}"; do
        echo "  $issue"
    done
    echo
fi

if [ "$WARNING_COUNT" -gt 0 ]; then
    echo "Warnings:"
    for warning in "${WARNINGS[@]}"; do
        echo "  $warning"
    done
    echo
fi

echo "Log saved to: $LOG_FILE"
echo "Report saved to: $REPORT_FILE"

# Backup previous report
if [ -f "$REPORT_FILE" ]; then
    cp "$REPORT_FILE" "$REPORT_PREV"
fi

# --- 9. Generate Markdown Report with Comparison ---
{
    echo "# 🔍 Metadata Audit Report"
    echo ""
    echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "---"
    echo ""
    echo "## Summary"
    echo ""
    echo "| Metric | Count |"
    echo "|--------|-------|"
    echo "| Duration | ${DURATION}s |"
    echo "| Movies on disk | ${#LIBRARY_MOVIE_IDS[@]} |"
    echo "| TV shows on disk | ${#LIBRARY_TV_NAMES[@]} |"
    echo "| Movie metadata entries | ${#MOVIE_META_IDS[@]} |"
    echo "| TV metadata entries | ${#TV_META_IDS[@]} |"
    echo "| Issues (errors) | $ISSUE_COUNT |"
    echo "| Warnings | $WARNING_COUNT |"
    echo "| Duplicates | $((DUPE_MOVIE_COUNT + DUPE_TV_COUNT)) |"
    echo ""

    if [ "$ISSUE_COUNT" -eq 0 ] && [ "$WARNING_COUNT" -eq 0 ]; then
        echo "---"
        echo ""
        echo "## Result ✅"
        echo ""
        echo "All metadata valid. No issues found."
        echo ""
    fi

    if [ "$ISSUE_COUNT" -gt 0 ]; then
        echo "---"
        echo ""
        echo "## Issues ❌"
        echo ""
        echo "| # | Issue |"
        echo "|---|-------|"
        IDX=0
        for issue in "${ISSUES[@]}"; do
            IDX=$((IDX + 1))
            echo "| $IDX | $issue |"
        done
        echo ""
    fi

    if [ "$ORPHANED_MOVIES" -gt 0 ] || [ "$ORPHANED_TV" -gt 0 ]; then
        echo "---"
        echo ""
        echo "## Orphaned Metadata"
        echo ""
        echo "Entries in metadata files that don't match anything in the library."
        echo ""
        if [ "$ORPHANED_MOVIES" -gt 0 ]; then
            echo "### Movies ($ORPHANED_MOVIES)"
            echo ""
            for warning in "${WARNINGS[@]}"; do
                [[ "$warning" == "Orphaned movie metadata:"* ]] && echo "- ${warning#Orphaned movie metadata: }"
            done
            echo ""
        fi
        if [ "$ORPHANED_TV" -gt 0 ]; then
            echo "### TV Shows ($ORPHANED_TV)"
            echo ""
            for warning in "${WARNINGS[@]}"; do
                [[ "$warning" == "Orphaned TV metadata:"* ]] && echo "- ${warning#Orphaned TV metadata: }"
            done
            echo ""
        fi
    fi

    if [ "$MISSING_MOVIES" -gt 0 ] || [ "$MISSING_TV" -gt 0 ]; then
        echo "---"
        echo ""
        echo "## Missing Metadata"
        echo ""
        echo "Library items without corresponding metadata entries."
        echo ""
        if [ "$MISSING_MOVIES" -gt 0 ]; then
            echo "### Movies ($MISSING_MOVIES)"
            echo ""
            for warning in "${WARNINGS[@]}"; do
                [[ "$warning" == "Missing movie metadata:"* ]] && echo "- ${warning#Missing movie metadata: }"
            done
            echo ""
        fi
        if [ "$MISSING_TV" -gt 0 ]; then
            echo "### TV Shows ($MISSING_TV)"
            echo ""
            for warning in "${WARNINGS[@]}"; do
                [[ "$warning" == "Missing TV metadata:"* ]] && echo "- ${warning#Missing TV metadata: }"
            done
            echo ""
        fi
    fi

    if [ "$DUPE_MOVIE_COUNT" -gt 0 ] || [ "$DUPE_TV_COUNT" -gt 0 ]; then
        echo "---"
        echo ""
        echo "## Duplicates"
        echo ""
        for issue in "${ISSUES[@]}"; do
            [[ "$issue" == "Duplicate"* ]] && echo "- $issue"
        done
        echo ""
    fi

    if [ "$SEASON_ISSUE_COUNT" -gt 0 ] || [ "$SEASON_WARNING_COUNT" -gt 0 ]; then
        echo "---"
        echo ""
        echo "## Season/Episode Gaps"
        echo ""
        echo "| Type | Detail |"
        echo "|------|--------|"
        for issue in "${ISSUES[@]}"; do
            [[ "$issue" == *"season folder missing"* ]] && echo "| ❌ Issue | $issue |"
            [[ "$issue" == *"missing episodes"* ]] && echo "| ❌ Issue | $issue |"
        done
        for warning in "${WARNINGS[@]}"; do
            [[ "$warning" == *"eps on disk"* ]] && echo "| ⚠️ Warning | $warning |"
        done
        echo ""
    fi

    # Comparison with previous report
    if [ -f "$REPORT_PREV" ]; then
        echo "---"
        echo ""
        echo "## Comparison with Previous Run"
        echo ""

        PREV_ISSUES=$(grep -oP 'Issues \(errors\) \| \K[0-9]+' "$REPORT_PREV" | head -1 || echo "0")
        PREV_WARNINGS=$(grep -oP 'Warnings \| \K[0-9]+' "$REPORT_PREV" | head -1 || echo "0")
        PREV_DUPLICATES=$(grep -oP 'Duplicates \| \K[0-9]+' "$REPORT_PREV" | head -1 || echo "0")

        [ -z "$PREV_ISSUES" ] && PREV_ISSUES=0
        [ -z "$PREV_WARNINGS" ] && PREV_WARNINGS=0
        [ -z "$PREV_DUPLICATES" ] && PREV_DUPLICATES=0

        CURRENT_DUPLICATES=$((DUPE_MOVIE_COUNT + DUPE_TV_COUNT))

        ISSUES_CHANGE=$((ISSUE_COUNT - PREV_ISSUES))
        WARNINGS_CHANGE=$((WARNING_COUNT - PREV_WARNINGS))
        DUPLICATES_CHANGE=$((CURRENT_DUPLICATES - PREV_DUPLICATES))

        format_change() {
            local change=$1
            if [ "$change" -gt 0 ]; then echo "**+${change}** ⬆️"
            elif [ "$change" -lt 0 ]; then echo "**${change}** ⬇️"
            else echo "No change ➡️"
            fi
        }

        echo "| Metric | Previous | Current | Change |"
        echo "|--------|----------|---------|--------|"
        echo "| Issues | $PREV_ISSUES | $ISSUE_COUNT | $(format_change "$ISSUES_CHANGE") |"
        echo "| Warnings | $PREV_WARNINGS | $WARNING_COUNT | $(format_change "$WARNINGS_CHANGE") |"
        echo "| Duplicates | $PREV_DUPLICATES | $CURRENT_DUPLICATES | $(format_change "$DUPLICATES_CHANGE") |"
        echo ""

        if [ "$ISSUE_COUNT" -lt "$PREV_ISSUES" ]; then
            RESOLVED=$((PREV_ISSUES - ISSUE_COUNT))
            echo "✅ **$RESOLVED issue(s) resolved since last run.**"
            echo ""
        fi
        if [ "$ISSUE_COUNT" -gt "$PREV_ISSUES" ]; then
            NEW_ISSUES=$((ISSUE_COUNT - PREV_ISSUES))
            echo "⚠️ **$NEW_ISSUES new issue(s) found since last run.**"
            echo ""
        fi
    fi
} > "$REPORT_FILE"

echo ""
echo "Files generated:"
echo "  Log:    $LOG_FILE"
echo "  Report: $REPORT_FILE"

# Discord notification
DISCORD_DESC="🔍 **Metadata Audit**

⏱️ ${DURATION}s

**Results:**
\`\`\`
Errors:       $ISSUE_COUNT
Warnings:     $WARNING_COUNT
Orphaned (movie): $ORPHANED_MOVIES
Orphaned (TV):    $ORPHANED_TV
Missing (movie):  $MISSING_MOVIES
Missing (TV):     $MISSING_TV
Duplicates:       $((DUPE_MOVIE_COUNT + DUPE_TV_COUNT))
Season issues:    $SEASON_ISSUE_COUNT
Episode gaps:     $SEASON_WARNING_COUNT
\`\`\`"

if [ "$ISSUE_COUNT" -gt 0 ]; then
    DISCORD_DESC+="
**Top Issues:**
\`\`\`
$(printf '%s\n' "${ISSUES[@]}" | head -5)
\`\`\`"
fi

if [ "$ISSUE_COUNT" -gt 0 ]; then
    send_discord "$DISCORD_ALERTS" "🔍 Metadata Validation" "$DISCORD_DESC" "16711680"
elif [ "$WARNING_COUNT" -gt 0 ]; then
    send_discord "$DISCORD_NOTIFICATIONS" "🔍 Metadata Validation" "$DISCORD_DESC" "16776960"
else
    send_discord "$DISCORD_NOTIFICATIONS" "🔍 Metadata Validation" "✅ All metadata valid. No issues found. (${DURATION}s)" "3066993"
fi
