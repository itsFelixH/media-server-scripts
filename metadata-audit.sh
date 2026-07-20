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
REPORT_FILE="$REPORT_DIR/metadata-audit.json"
BASELINE_FILE="$REPORT_DIR/metadata-audit.baseline.json"
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
SCRIPT_NAME="metadata-audit.sh"

# Extract all TMDb IDs from movie files on disk
get_library_movie_ids() {
    find "$MOVIES_DIR" -maxdepth 2 -type f \( -name "*.mkv" -o -name "*.mp4" \) 2>/dev/null | \
        grep -oP '\{tmdb-\K[0-9]+' | sort -u
}

# Normalize a name for comparison:
#   - Strip filesystem-unsafe characters: : ? * " < > |
#   - Normalize dashes: en-dash (–), em-dash (—) → hyphen (-)
#   - Strip bracket suffixes like [B&W] or [Full Hue]
#   - Collapse multiple spaces
normalize_name() {
    echo "$1" | sed 's/[:\?\*"<>|]//g; s/\xE2\x80\x93/-/g; s/\xE2\x80\x94/-/g; s/ *\[.*\]//g; s/  */ /g; s/^ //; s/ $//'
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
TV_META_SOURCES=()
for yml in "$METADATA_DIR/shows.yml" "$METADATA_DIR/tv/"*.yml; do
    [ -f "$yml" ] || continue
    yml_basename=$(basename "$yml")
    while read -r id; do
        TV_META_IDS+=("$id")
    done < <(get_metadata_ids "$yml")
    while read -r name; do
        [ -n "$name" ] && TV_META_NAMES+=("$name") && TV_META_SOURCES+=("$yml_basename")
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
UPCOMING_MOVIES=0
CURRENT_YEAR=$(date +%Y)
for id in "${MOVIE_META_IDS[@]}"; do
    if ! printf '%s\n' "${LIBRARY_MOVIE_IDS[@]}" | grep -qx "$id"; then
        # Try to resolve the ID to a name from the metadata comment
        movie_name=$(grep -P "^\s+${id}:" "$METADATA_DIR/movies.yml" 2>/dev/null | grep -oP '#\s*\K.*' | sed 's/ Poster by.*//;s/ Set by.*//')
        [ -z "$movie_name" ] && movie_name="TMDb $id"
        # Check if this is an upcoming release (year >= current year)
        movie_year=$(echo "$movie_name" | grep -oP '\((\d{4})\)' | tail -1 | tr -d '()')
        if [ -n "$movie_year" ] && [ "$movie_year" -ge "$CURRENT_YEAR" ]; then
            WARNINGS+=("Upcoming movie metadata: $movie_name (TMDb $id)")
            ((UPCOMING_MOVIES++))
        else
            WARNINGS+=("Orphaned movie metadata: $movie_name (TMDb $id)")
            ((ORPHANED_MOVIES++))
        fi
    fi
done

ORPHANED_TV=0
# Build normalized library name list for comparison
LIBRARY_TV_NAMES_NORMALIZED=()
for lib_name in "${LIBRARY_TV_NAMES[@]}"; do
    LIBRARY_TV_NAMES_NORMALIZED+=("$(normalize_name "$lib_name" | tr '[:upper:]' '[:lower:]')")
done

for name in "${TV_META_NAMES[@]}"; do
    norm_meta="$(normalize_name "$name" | tr '[:upper:]' '[:lower:]')"
    found=false
    for norm_lib in "${LIBRARY_TV_NAMES_NORMALIZED[@]}"; do
        if [ "$norm_meta" = "$norm_lib" ]; then
            found=true
            break
        fi
    done
    if [ "$found" = false ]; then
        WARNINGS+=("Orphaned TV metadata: $name")
        ((ORPHANED_TV++))
    fi
done
echo "  Orphaned movie entries: $ORPHANED_MOVIES"
echo "  Upcoming movie entries: $UPCOMING_MOVIES"
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
# Build normalized metadata name list for comparison
TV_META_NAMES_NORMALIZED=()
for meta_name in "${TV_META_NAMES[@]}"; do
    TV_META_NAMES_NORMALIZED+=("$(normalize_name "$meta_name" | tr '[:upper:]' '[:lower:]')")
done

for name in "${LIBRARY_TV_NAMES[@]}"; do
    norm_lib="$(normalize_name "$name" | tr '[:upper:]' '[:lower:]')"
    found=false
    for norm_meta in "${TV_META_NAMES_NORMALIZED[@]}"; do
        if [ "$norm_lib" = "$norm_meta" ]; then
            found=true
            break
        fi
    done
    if [ "$found" = false ]; then
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

# Update weekly baseline (only if older than 7 days or doesn't exist)
BASELINE_STALE=false
if [ ! -f "$BASELINE_FILE" ]; then
    BASELINE_STALE=true
elif [ -f "$BASELINE_FILE" ]; then
    _baseline_age=$(( $(date +%s) - $(stat -c %Y "$BASELINE_FILE") ))
    [ "$_baseline_age" -gt 604800 ] && BASELINE_STALE=true
fi
if [ "$BASELINE_STALE" = true ] && [ -f "$REPORT_FILE" ]; then
    cp "$REPORT_FILE" "$BASELINE_FILE"
fi

# --- 9. Generate JSON Report with Comparison ---

# Build categorized warning arrays as structured JSON
ORPHANED_MOVIES_JSON="[]"
ORPHANED_TV_JSON="[]"
UPCOMING_MOVIES_JSON="[]"
MISSING_MOVIES_JSON="[]"
MISSING_TV_JSON="[]"
SEASON_ISSUES_JSON="[]"

for warning in "${WARNINGS[@]}"; do
    case "$warning" in
        "Orphaned movie metadata:"*)
            entry="${warning#Orphaned movie metadata: }"
            _name=$(echo "$entry" | sed 's/ (TMDb [0-9]*)$//')
            _year=$(echo "$_name" | grep -oP '\((\d{4})\)' | tail -1 | tr -d '()')
            _tmdb=$(echo "$entry" | grep -oP 'TMDb \K[0-9]+')
            _name_clean=$(echo "$_name" | sed 's/ ([0-9]\{4\})$//')
            _url=""
            [ -n "$_tmdb" ] && _url="https://www.themoviedb.org/movie/$_tmdb"
            ORPHANED_MOVIES_JSON=$(echo "$ORPHANED_MOVIES_JSON" | jq \
                --arg name "$_name_clean" --argjson year "${_year:-null}" --arg tmdb_id "${_tmdb:-}" \
                --arg source "movies.yml" --arg severity "warning" \
                --arg action "Remove from movies.yml" --arg url "$_url" \
                '. + [{"name": $name, "year": (if $year == null then null else $year end), "tmdb_id": $tmdb_id, "source": $source, "severity": $severity, "action": $action, "url": (if $url == "" then null else $url end)}]')
            ;;
        "Orphaned TV metadata:"*)
            entry="${warning#Orphaned TV metadata: }"
            _source="unknown"
            for _i in "${!TV_META_NAMES[@]}"; do
                if [ "${TV_META_NAMES[$_i]}" = "$entry" ]; then
                    _source="${TV_META_SOURCES[$_i]}"
                    break
                fi
            done
            ORPHANED_TV_JSON=$(echo "$ORPHANED_TV_JSON" | jq \
                --arg name "$entry" --arg source "$_source" --arg severity "warning" \
                --arg action "Remove from $_source" \
                '. + [{"name": $name, "source": $source, "severity": $severity, "action": $action}]')
            ;;
        "Upcoming movie metadata:"*)
            entry="${warning#Upcoming movie metadata: }"
            _name=$(echo "$entry" | sed 's/ (TMDb [0-9]*)$//')
            _year=$(echo "$_name" | grep -oP '\((\d{4})\)' | tail -1 | tr -d '()')
            _tmdb=$(echo "$entry" | grep -oP 'TMDb \K[0-9]+')
            _name_clean=$(echo "$_name" | sed 's/ ([0-9]\{4\})$//')
            _url=""
            [ -n "$_tmdb" ] && _url="https://www.themoviedb.org/movie/$_tmdb"
            UPCOMING_MOVIES_JSON=$(echo "$UPCOMING_MOVIES_JSON" | jq \
                --arg name "$_name_clean" --argjson year "${_year:-null}" --arg tmdb_id "${_tmdb:-}" \
                --arg source "movies.yml" --arg severity "info" \
                --arg action "Wait for release" --arg url "$_url" \
                '. + [{"name": $name, "year": (if $year == null then null else $year end), "tmdb_id": $tmdb_id, "source": $source, "severity": $severity, "action": $action, "url": (if $url == "" then null else $url end)}]')
            ;;
        "Missing movie metadata:"*)
            entry="${warning#Missing movie metadata: }"
            _name=$(echo "$entry" | sed 's/ (TMDb [0-9]*)$//')
            _year=$(echo "$_name" | grep -oP '\((\d{4})\)' | tail -1 | tr -d '()')
            _tmdb=$(echo "$entry" | grep -oP 'TMDb \K[0-9]+')
            _name_clean=$(echo "$_name" | sed 's/ ([0-9]\{4\})$//')
            _url=""
            [ -n "$_tmdb" ] && _url="https://www.themoviedb.org/movie/$_tmdb"
            MISSING_MOVIES_JSON=$(echo "$MISSING_MOVIES_JSON" | jq \
                --arg name "$_name_clean" --argjson year "${_year:-null}" --arg tmdb_id "${_tmdb:-}" \
                --arg severity "warning" --arg action "Add to movies.yml" --arg url "$_url" \
                '. + [{"name": $name, "year": (if $year == null then null else $year end), "tmdb_id": $tmdb_id, "severity": $severity, "action": $action, "url": (if $url == "" then null else $url end)}]')
            ;;
        "Missing TV metadata:"*)
            entry="${warning#Missing TV metadata: }"
            MISSING_TV_JSON=$(echo "$MISSING_TV_JSON" | jq \
                --arg name "$entry" --arg severity "warning" \
                --arg action "Add to shows.yml or tv/*.yml" \
                '. + [{"name": $name, "severity": $severity, "action": $action}]')
            ;;
        *"eps on disk"*|*"season folder missing"*|*"missing episodes"*)
            _severity="warning"
            [[ "$warning" == *"missing episodes"* ]] && _severity="error"
            [[ "$warning" == *"season folder missing"* ]] && _severity="error"
            SEASON_ISSUES_JSON=$(echo "$SEASON_ISSUES_JSON" | jq --arg e "$warning" --arg severity "$_severity" \
                '. + [{"message": $e, "severity": $severity}]')
            ;;
    esac
done

# Build issues JSON (structured with severity)
ISSUES_JSON="[]"
for issue in "${ISSUES[@]}"; do
    _severity="error"
    ISSUES_JSON=$(echo "$ISSUES_JSON" | jq --arg e "$issue" --arg severity "$_severity" \
        '. + [{"message": $e, "severity": $severity}]')
done

# Add season issues from ISSUES array
for issue in "${ISSUES[@]}"; do
    case "$issue" in
        *"season folder missing"*|*"missing episodes"*)
            SEASON_ISSUES_JSON=$(echo "$SEASON_ISSUES_JSON" | jq --arg e "$issue" --arg severity "error" \
                '. + [{"message": $e, "severity": $severity}]')
            ;;
    esac
done

# Calculate coverage percentages
MOVIE_COVERAGE=0
TV_COVERAGE=0
[ "${#LIBRARY_MOVIE_IDS[@]}" -gt 0 ] && MOVIE_COVERAGE=$(awk "BEGIN {printf \"%.1f\", (${#LIBRARY_MOVIE_IDS[@]} - $MISSING_MOVIES) / ${#LIBRARY_MOVIE_IDS[@]} * 100}")
[ "${#LIBRARY_TV_NAMES[@]}" -gt 0 ] && TV_COVERAGE=$(awk "BEGIN {printf \"%.1f\", (${#LIBRARY_TV_NAMES[@]} - $MISSING_TV) / ${#LIBRARY_TV_NAMES[@]} * 100}")

# Last clean tracking — read from current report (persists across runs), fall back to baseline
LAST_CLEAN="null"
if [ -f "$REPORT_FILE" ]; then
    LAST_CLEAN=$(jq '.data.last_clean // null' "$REPORT_FILE" 2>/dev/null)
    [ -z "$LAST_CLEAN" ] && LAST_CLEAN="null"
elif [ -f "$BASELINE_FILE" ]; then
    LAST_CLEAN=$(jq '.data.last_clean // null' "$BASELINE_FILE" 2>/dev/null)
    [ -z "$LAST_CLEAN" ] && LAST_CLEAN="null"
fi
if [ "$ISSUE_COUNT" -eq 0 ] && [ "$WARNING_COUNT" -eq 0 ]; then
    LAST_CLEAN="\"$(date +%Y-%m-%d)\""
fi

# By-source breakdown — count orphaned entries per source file
BY_SOURCE_JSON=$(echo "$ORPHANED_MOVIES_JSON" "$ORPHANED_TV_JSON" | jq -s '
    (.[0] + .[1]) | group_by(.source) | map({
        source: .[0].source,
        orphaned: length
    })
')

# Build comparison JSON (against weekly baseline)
COMPARISON_JSON="null"
if [ -f "$BASELINE_FILE" ]; then
    PREV_ISSUES=$(jq -r '.summary.issues // 0' "$BASELINE_FILE" 2>/dev/null || echo "0")
    PREV_WARNINGS=$(jq -r '.summary.warnings // 0' "$BASELINE_FILE" 2>/dev/null || echo "0")
    PREV_DUPLICATES=$(jq -r '.summary.duplicates // 0' "$BASELINE_FILE" 2>/dev/null || echo "0")

    [ -z "$PREV_ISSUES" ] || [ "$PREV_ISSUES" = "null" ] && PREV_ISSUES=0
    [ -z "$PREV_WARNINGS" ] || [ "$PREV_WARNINGS" = "null" ] && PREV_WARNINGS=0
    [ -z "$PREV_DUPLICATES" ] || [ "$PREV_DUPLICATES" = "null" ] && PREV_DUPLICATES=0

    CURRENT_DUPLICATES=$((DUPE_MOVIE_COUNT + DUPE_TV_COUNT))
    ISSUES_CHANGE=$((ISSUE_COUNT - PREV_ISSUES))
    WARNINGS_CHANGE=$((WARNING_COUNT - PREV_WARNINGS))
    DUPLICATES_CHANGE=$((CURRENT_DUPLICATES - PREV_DUPLICATES))

    COMPARISON_JSON=$(jq -n \
        --argjson prev_issues "$PREV_ISSUES" \
        --argjson prev_warnings "$PREV_WARNINGS" \
        --argjson prev_duplicates "$PREV_DUPLICATES" \
        --argjson issues_change "$ISSUES_CHANGE" \
        --argjson warnings_change "$WARNINGS_CHANGE" \
        --argjson duplicates_change "$DUPLICATES_CHANGE" \
        '{
            prev_issues: $prev_issues,
            prev_warnings: $prev_warnings,
            prev_duplicates: $prev_duplicates,
            issues_change: $issues_change,
            warnings_change: $warnings_change,
            duplicates_change: $duplicates_change
        }')
fi

# Determine health status
if [ "$ISSUE_COUNT" -gt 0 ]; then
    HEALTH_STATUS="error"
    HEALTH_MSG="$ISSUE_COUNT issue(s) require attention"
elif [ "$WARNING_COUNT" -gt 50 ]; then
    HEALTH_STATUS="warning"
    HEALTH_MSG="$WARNING_COUNT warnings"
else
    HEALTH_STATUS="ok"
    HEALTH_MSG="All metadata valid"
fi

# Write final JSON report
jq -n \
    --argjson version 1 \
    --arg type "metadata-audit" \
    --arg generated "$(date -Iseconds)" \
    --arg generated_by "$SCRIPT_NAME" \
    --argjson duration "$DURATION" \
    --arg health_status "$HEALTH_STATUS" \
    --arg health_msg "$HEALTH_MSG" \
    --argjson movies_on_disk "${#LIBRARY_MOVIE_IDS[@]}" \
    --argjson tv_on_disk "${#LIBRARY_TV_NAMES[@]}" \
    --argjson movie_metadata "${#MOVIE_META_IDS[@]}" \
    --argjson tv_metadata "${#TV_META_IDS[@]}" \
    --argjson issues "$ISSUE_COUNT" \
    --argjson warnings "$WARNING_COUNT" \
    --argjson orphaned "$((ORPHANED_MOVIES + ORPHANED_TV))" \
    --argjson upcoming "$UPCOMING_MOVIES" \
    --argjson duplicates "$((DUPE_MOVIE_COUNT + DUPE_TV_COUNT))" \
    --argjson movie_coverage "$MOVIE_COVERAGE" \
    --argjson tv_coverage "$TV_COVERAGE" \
    --argjson issues_list "$ISSUES_JSON" \
    --argjson orphaned_movies "$ORPHANED_MOVIES_JSON" \
    --argjson orphaned_tv "$ORPHANED_TV_JSON" \
    --argjson upcoming_movies "$UPCOMING_MOVIES_JSON" \
    --argjson missing_movies "$MISSING_MOVIES_JSON" \
    --argjson missing_tv "$MISSING_TV_JSON" \
    --argjson season_issues "$SEASON_ISSUES_JSON" \
    --argjson last_clean "$LAST_CLEAN" \
    --argjson by_source "$BY_SOURCE_JSON" \
    --argjson comparison "$COMPARISON_JSON" \
    '{
        version: $version,
        type: $type,
        generated: $generated,
        generated_by: $generated_by,
        duration_seconds: $duration,
        health: {status: $health_status, message: $health_msg},
        summary: {
            movies_on_disk: $movies_on_disk,
            tv_on_disk: $tv_on_disk,
            movie_metadata: $movie_metadata,
            tv_metadata: $tv_metadata,
            issues: $issues,
            warnings: $warnings,
            orphaned: $orphaned,
            upcoming: $upcoming,
            duplicates: $duplicates,
            movie_coverage_pct: $movie_coverage,
            tv_coverage_pct: $tv_coverage
        },
        data: {
            last_clean: $last_clean,
            by_source: $by_source,
            issues: $issues_list,
            orphaned: {
                movies: $orphaned_movies,
                tv: $orphaned_tv
            },
            upcoming_movies: $upcoming_movies,
            missing: {
                movies: $missing_movies,
                tv: $missing_tv
            },
            season_gaps: $season_issues
        },
        comparison: $comparison
    }' > "$REPORT_FILE"

echo ""
echo "Files generated:"
echo "  Log:    $LOG_FILE"
echo "  Report: $REPORT_FILE"

# Discord notification
DISCORD_DESC="\`\`\`
Errors:    $ISSUE_COUNT
Warnings:  $WARNING_COUNT
Orphaned:  $((ORPHANED_MOVIES + ORPHANED_TV))
Missing:   $((MISSING_MOVIES + MISSING_TV))
Duplicates: $((DUPE_MOVIE_COUNT + DUPE_TV_COUNT))
\`\`\`"

if [ "$ISSUE_COUNT" -gt 0 ]; then
    DISCORD_DESC+="
**Top Issues:**
\`\`\`
$(printf '%s\n' "${ISSUES[@]}" | head -5)
\`\`\`"
fi

if [ "$ISSUE_COUNT" -gt 0 ]; then
    DISCORD_DESC+="

See \`reports/metadata-audit.json\` for details."
    discord_notify "error" "🔍 Metadata Audit" "$DISCORD_DESC"
elif [ "$WARNING_COUNT" -gt 0 ]; then
    DISCORD_DESC+="

See \`reports/metadata-audit.json\` for details."
    discord_notify "warning" "🔍 Metadata Audit" "$DISCORD_DESC"
else
    discord_notify "success" "🔍 Metadata Audit" "No issues found."
fi
