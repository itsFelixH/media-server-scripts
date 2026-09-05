#!/bin/bash
# Plex vs ARRs Comparison
# Compares Plex library content against Radarr/Sonarr to find mismatches.
# Shows movies/shows in Plex but not in ARRs and vice versa.
#
# Usage:
#   ./plex-vs-arrs.sh [options]
#
# Options:
#   -h, --help        Show this help message
#   -q, --quiet       Suppress terminal output (log only)
#   --no-discord      Skip Discord notification

VERSION="1.0"

####### HELP #######
show_help() {
    cat <<'HELP'
Plex vs ARRs Comparison — Finds mismatches between Plex and Radarr/Sonarr.

Usage: plex-vs-arrs.sh [options]

Compares the Plex library against Radarr (movies) and Sonarr (TV shows).
Reports items that exist in one system but not the other, finds duplicates,
and attempts fuzzy title matching for items with mismatched IDs.

Options:
  -h, --help        Show this help message
  -q, --quiet       Suppress terminal output (log only)
  --no-discord      Skip Discord notification

Output: ~/kometa/scripts/reports/plex-vs-arrs.json (overwritten each run)
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

SCRIPT_NAME="plex-vs-arrs.sh"
START_TIME=$(date +%s)
LOG_FILE="$LOG_DIR/plex-vs-arrs/plex-vs-arrs_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR/plex-vs-arrs"

REPORT_FILE="$REPORT_DIR/plex-vs-arrs.json"

# Redirect output
if [ "$QUIET" = true ]; then
    exec > "$LOG_FILE" 2>&1
else
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

####### DEPENDENCY CHECK #######
MISSING_DEPS=()
command -v jq &>/dev/null || MISSING_DEPS+=("jq")
command -v curl &>/dev/null || MISSING_DEPS+=("curl")

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "ERROR: Missing required dependencies:"
    for dep in "${MISSING_DEPS[@]}"; do echo "  - $dep"; done
    exit 1
fi

####### CONFIGURATION VALIDATION #######
if [ -z "$PLEX_TOKEN" ]; then
    echo "ERROR: Plex token not configured"
    exit 1
fi
if [ -z "$API_KEY_RADARR" ]; then
    echo "ERROR: Radarr API key not configured"
    exit 1
fi
if [ -z "$API_KEY_SONARR" ]; then
    echo "ERROR: Sonarr API key not configured"
    exit 1
fi

RADARR_URL="http://localhost:7878/api/v3"
SONARR_URL="http://localhost:8989/api/v3"

####### UTILITY FUNCTIONS #######

# Normalize a title for fuzzy comparison
# Lowercases, strips punctuation and common suffixes
normalize_title() {
    local title="$1"
    echo "$title" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[:\-\(\)&]//g' \
        | sed -E 's/\s+(us|uk|au|ca)$//g' \
        | sed -E 's/[[:space:]]+/ /g' \
        | sed 's/^ *//;s/ *$//'
}

# Strip {tmdb-XXXXX} and {tvdb-XXXXX} tags from titles
strip_tags() {
    echo "$1" | sed -E 's/\{(tmdb|tvdb|imdb)-[^}]+\}//g' | sed 's/^ *//;s/ *$//'
}

# Plex API helper — fetch JSON from Plex
plex_api() {
    local endpoint="$1"
    curl -s -H "X-Plex-Token: $PLEX_TOKEN" -H "Accept: application/json" \
        "${PLEX_URL}${endpoint}"
}

# Radarr API helper
radarr_api() {
    local endpoint="$1"
    curl -s "${RADARR_URL}${endpoint}?apikey=${API_KEY_RADARR}"
}

# Sonarr API helper
sonarr_api() {
    local endpoint="$1"
    curl -s "${SONARR_URL}${endpoint}?apikey=${API_KEY_SONARR}"
}

# Lookup TMDb ID from IMDb ID via Radarr
lookup_tmdb_from_imdb() {
    local imdb_id="$1"
    local result
    result=$(curl -s "${RADARR_URL}/movie/lookup/imdb?apikey=${API_KEY_RADARR}&imdbId=${imdb_id}")
    echo "$result" | jq -r '.tmdbId // empty' 2>/dev/null
}

# Lookup TVDb ID from IMDb ID via Sonarr
lookup_tvdb_from_imdb() {
    local imdb_id="$1"
    local result
    result=$(curl -s "${SONARR_URL}/series/lookup?apikey=${API_KEY_SONARR}&term=imdb:${imdb_id}")
    echo "$result" | jq -r '.[0].tvdbId // empty' 2>/dev/null
}

####### DATA FETCHING #######

# Fetch all Plex movies with their GUIDs (single bulk API call)
fetch_plex_movies() {
    echo ""
    echo "🎬 Fetching Plex movies..."

    # Get the Movies library section key
    local sections_json
    sections_json=$(plex_api "/library/sections")
    local movie_key
    movie_key=$(echo "$sections_json" | jq -r '.MediaContainer.Directory[] | select(.title == "Movies") | .key')

    if [ -z "$movie_key" ]; then
        echo "ERROR: Could not find Movies library in Plex"
        return 1
    fi

    # Fetch all movies with GUIDs in a single call
    local movies_json
    movies_json=$(plex_api "/library/sections/${movie_key}/all?includeGuids=1")

    local total_movies
    total_movies=$(echo "$movies_json" | jq '.MediaContainer.size // 0')
    echo "  Found $total_movies movies in Plex"

    # Arrays to hold results
    declare -gA PLEX_MOVIE_TMDB=()       # tmdb_id -> title
    declare -ga PLEX_MOVIE_NO_ID=()       # titles without usable IDs
    declare -gA PLEX_MOVIE_DUPES=()       # tmdb_id -> "title1|title2|..."
    TOTAL_PLEX_MOVIES=$total_movies

    # Parse all movies from the bulk response
    while IFS=$'\t' read -r title tmdb_id imdb_id; do
        [ -z "$title" ] && continue
        title=$(strip_tags "$title")

        # Fallback: lookup TMDb from IMDb if no TMDb ID
        if [ -z "$tmdb_id" ] && [ -n "$imdb_id" ]; then
            tmdb_id=$(lookup_tmdb_from_imdb "$imdb_id")
        fi

        if [ -n "$tmdb_id" ]; then
            if [ -n "${PLEX_MOVIE_TMDB[$tmdb_id]+_}" ]; then
                # Duplicate
                if [ -n "${PLEX_MOVIE_DUPES[$tmdb_id]+_}" ]; then
                    PLEX_MOVIE_DUPES[$tmdb_id]="${PLEX_MOVIE_DUPES[$tmdb_id]}|$title"
                else
                    PLEX_MOVIE_DUPES[$tmdb_id]="${PLEX_MOVIE_TMDB[$tmdb_id]}|$title"
                fi
            else
                PLEX_MOVIE_TMDB[$tmdb_id]="$title"
            fi
        else
            PLEX_MOVIE_NO_ID+=("$title")
        fi
    done < <(echo "$movies_json" | jq -r '.MediaContainer.Metadata[] | [
        .title,
        ([.Guid[]?.id // empty | select(startswith("tmdb://"))] | first // "" | ltrimstr("tmdb://")),
        ([.Guid[]?.id // empty | select(startswith("imdb://"))] | first // "" | ltrimstr("imdb://"))
    ] | @tsv')

    echo "  Movies with TMDb IDs: ${#PLEX_MOVIE_TMDB[@]}"
    echo "  Movies without usable IDs: ${#PLEX_MOVIE_NO_ID[@]}"
    echo "  Duplicate TMDb IDs: ${#PLEX_MOVIE_DUPES[@]}"
}

# Fetch all Plex TV shows with their GUIDs (single bulk API call)
fetch_plex_tv_shows() {
    echo ""
    echo "📺 Fetching Plex TV shows..."

    local sections_json
    sections_json=$(plex_api "/library/sections")
    local tv_key
    tv_key=$(echo "$sections_json" | jq -r '.MediaContainer.Directory[] | select(.title == "TV Shows") | .key')

    if [ -z "$tv_key" ]; then
        echo "ERROR: Could not find TV Shows library in Plex"
        return 1
    fi

    # Fetch all shows with GUIDs in a single call
    local shows_json
    shows_json=$(plex_api "/library/sections/${tv_key}/all?includeGuids=1")

    local total_shows
    total_shows=$(echo "$shows_json" | jq '.MediaContainer.size // 0')
    echo "  Found $total_shows TV shows in Plex"

    declare -gA PLEX_SHOW_TVDB=()         # tvdb_id -> title
    declare -ga PLEX_SHOW_NO_ID=()         # titles without usable IDs
    declare -gA PLEX_SHOW_DUPES=()         # tvdb_id -> "title1|title2|..."
    TOTAL_PLEX_SHOWS=$total_shows

    # Parse all shows from the bulk response
    while IFS=$'\t' read -r title tvdb_id imdb_id; do
        [ -z "$title" ] && continue
        title=$(strip_tags "$title")

        # Fallback: lookup TVDb from IMDb via Sonarr
        if [ -z "$tvdb_id" ] && [ -n "$imdb_id" ]; then
            tvdb_id=$(lookup_tvdb_from_imdb "$imdb_id")
        fi

        if [ -n "$tvdb_id" ]; then
            if [ -n "${PLEX_SHOW_TVDB[$tvdb_id]+_}" ]; then
                if [ -n "${PLEX_SHOW_DUPES[$tvdb_id]+_}" ]; then
                    PLEX_SHOW_DUPES[$tvdb_id]="${PLEX_SHOW_DUPES[$tvdb_id]}|$title"
                else
                    PLEX_SHOW_DUPES[$tvdb_id]="${PLEX_SHOW_TVDB[$tvdb_id]}|$title"
                fi
            else
                PLEX_SHOW_TVDB[$tvdb_id]="$title"
            fi
        else
            PLEX_SHOW_NO_ID+=("$title")
        fi
    done < <(echo "$shows_json" | jq -r '.MediaContainer.Metadata[] | [
        .title,
        ([.Guid[]?.id // empty | select(startswith("tvdb://"))] | first // "" | ltrimstr("tvdb://")),
        ([.Guid[]?.id // empty | select(startswith("imdb://"))] | first // "" | ltrimstr("imdb://"))
    ] | @tsv')

    echo "  TV shows with TVDb IDs: ${#PLEX_SHOW_TVDB[@]}"
    echo "  TV shows without usable IDs: ${#PLEX_SHOW_NO_ID[@]}"
    echo "  Duplicate TVDb IDs: ${#PLEX_SHOW_DUPES[@]}"
}

# Fetch Radarr movies (only those with files downloaded)
fetch_radarr_movies() {
    echo ""
    echo "🎞️  Fetching Radarr movies..."

    local radarr_json
    radarr_json=$(radarr_api "/movie")

    if [ $? -ne 0 ] || [ -z "$radarr_json" ]; then
        echo "ERROR: Failed to fetch Radarr movies"
        return 1
    fi

    # Filter to movies that have files and extract tmdbId + title
    declare -gA RADARR_MOVIES=()   # tmdb_id -> title
    local count=0

    while IFS=$'\t' read -r tmdb_id title; do
        [ -z "$tmdb_id" ] && continue
        RADARR_MOVIES[$tmdb_id]="$title"
        count=$((count + 1))
    done < <(echo "$radarr_json" | jq -r '.[] | select(.hasFile == true and .tmdbId != null) | [(.tmdbId | tostring), .title] | @tsv')

    echo "  Radarr movies (with files): $count"
}

# Fetch Sonarr TV shows (only those with downloaded episodes)
fetch_sonarr_tv_shows() {
    echo ""
    echo "📡 Fetching Sonarr TV shows..."

    local sonarr_json
    sonarr_json=$(sonarr_api "/series")

    if [ $? -ne 0 ] || [ -z "$sonarr_json" ]; then
        echo "ERROR: Failed to fetch Sonarr TV shows"
        return 1
    fi

    declare -gA SONARR_SHOWS=()    # tvdb_id -> title
    local count=0

    while IFS=$'\t' read -r tvdb_id title; do
        [ -z "$tvdb_id" ] && continue
        SONARR_SHOWS[$tvdb_id]="$title"
        count=$((count + 1))
    done < <(echo "$sonarr_json" | jq -r '.[] | select(.statistics.episodeFileCount > 0 and .tvdbId != null) | [(.tvdbId | tostring), .title] | @tsv')

    echo "  Sonarr TV shows (with episodes): $count"
}

####### COMPARISON FUNCTIONS #######

# Compare two associative arrays by key and produce sorted lists
# Results are stored in global arrays
compare_movies() {
    echo ""
    echo "=================================================="
    echo "🎬 MOVIE COMPARISON"
    echo "=================================================="

    # Find movies in Plex but not in Radarr
    declare -ga MOVIES_PLEX_ONLY=()      # "title (tmdbId: XXX)"
    declare -ga MOVIES_RADARR_ONLY=()    # "title (tmdbId: XXX)"
    declare -ga MOVIES_TITLE_MATCH=()    # "Plex: title (tmdbId: X) ↔ Radarr: title (tmdbId: Y)"

    for tmdb_id in "${!PLEX_MOVIE_TMDB[@]}"; do
        if [ -z "${RADARR_MOVIES[$tmdb_id]+_}" ]; then
            MOVIES_PLEX_ONLY+=("${PLEX_MOVIE_TMDB[$tmdb_id]}|tmdbId:${tmdb_id}")
        fi
    done

    for tmdb_id in "${!RADARR_MOVIES[@]}"; do
        if [ -z "${PLEX_MOVIE_TMDB[$tmdb_id]+_}" ]; then
            MOVIES_RADARR_ONLY+=("${RADARR_MOVIES[$tmdb_id]}|tmdbId:${tmdb_id}")
        fi
    done

    # Attempt fuzzy title matching between unmatched items
    local -A plex_unmatched_titles=()
    for entry in "${MOVIES_PLEX_ONLY[@]}"; do
        local title="${entry%%|*}"
        local id_part="${entry##*|}"
        local id="${id_part#tmdbId:}"
        plex_unmatched_titles[$id]="$title"
    done

    local -A radarr_unmatched_titles=()
    for entry in "${MOVIES_RADARR_ONLY[@]}"; do
        local title="${entry%%|*}"
        local id_part="${entry##*|}"
        local id="${id_part#tmdbId:}"
        radarr_unmatched_titles[$id]="$title"
    done

    # Find title matches
    local -A matched_plex_ids=()
    local -A matched_radarr_ids=()

    for plex_id in "${!plex_unmatched_titles[@]}"; do
        local plex_norm
        plex_norm=$(normalize_title "${plex_unmatched_titles[$plex_id]}")
        for radarr_id in "${!radarr_unmatched_titles[@]}"; do
            [ -n "${matched_radarr_ids[$radarr_id]+_}" ] && continue
            local radarr_norm
            radarr_norm=$(normalize_title "${radarr_unmatched_titles[$radarr_id]}")
            if [ "$plex_norm" = "$radarr_norm" ]; then
                MOVIES_TITLE_MATCH+=("${plex_unmatched_titles[$plex_id]} (tmdbId: $plex_id) ↔ ${radarr_unmatched_titles[$radarr_id]} (tmdbId: $radarr_id)")
                matched_plex_ids[$plex_id]=1
                matched_radarr_ids[$radarr_id]=1
                break
            fi
        done
    done

    # Also check movies without IDs against Radarr unmatched
    for no_id_title in "${PLEX_MOVIE_NO_ID[@]}"; do
        local plex_norm
        plex_norm=$(normalize_title "$no_id_title")
        for radarr_id in "${!radarr_unmatched_titles[@]}"; do
            [ -n "${matched_radarr_ids[$radarr_id]+_}" ] && continue
            local radarr_norm
            radarr_norm=$(normalize_title "${radarr_unmatched_titles[$radarr_id]}")
            if [ "$plex_norm" = "$radarr_norm" ]; then
                MOVIES_TITLE_MATCH+=("$no_id_title (no ID) ↔ ${radarr_unmatched_titles[$radarr_id]} (tmdbId: $radarr_id)")
                matched_radarr_ids[$radarr_id]=1
                break
            fi
        done
    done

    # Rebuild final lists without matched items
    local -a final_plex_only=()
    for entry in "${MOVIES_PLEX_ONLY[@]}"; do
        local id_part="${entry##*|}"
        local id="${id_part#tmdbId:}"
        [ -z "${matched_plex_ids[$id]+_}" ] && final_plex_only+=("$entry")
    done
    MOVIES_PLEX_ONLY=("${final_plex_only[@]}")

    local -a final_radarr_only=()
    for entry in "${MOVIES_RADARR_ONLY[@]}"; do
        local id_part="${entry##*|}"
        local id="${id_part#tmdbId:}"
        [ -z "${matched_radarr_ids[$id]+_}" ] && final_radarr_only+=("$entry")
    done
    MOVIES_RADARR_ONLY=("${final_radarr_only[@]}")

    # Sort and print results
    echo ""
    echo "Movies in Plex but not in Radarr (${#MOVIES_PLEX_ONLY[@]}):"
    if [ ${#MOVIES_PLEX_ONLY[@]} -gt 0 ]; then
        printf '%s\n' "${MOVIES_PLEX_ONLY[@]}" | sort -t'|' -k1 -f | while IFS='|' read -r title id; do
            echo "  - $title ($id)"
        done
    else
        echo "  (none)"
    fi

    echo ""
    echo "Movies in Radarr (downloaded) but not in Plex (${#MOVIES_RADARR_ONLY[@]}):"
    if [ ${#MOVIES_RADARR_ONLY[@]} -gt 0 ]; then
        printf '%s\n' "${MOVIES_RADARR_ONLY[@]}" | sort -t'|' -k1 -f | while IFS='|' read -r title id; do
            echo "  - $title ($id)"
        done
    else
        echo "  (none)"
    fi

    if [ ${#MOVIES_TITLE_MATCH[@]} -gt 0 ]; then
        echo ""
        echo "Movies matched by title — likely same content, different IDs (${#MOVIES_TITLE_MATCH[@]}):"
        printf '%s\n' "${MOVIES_TITLE_MATCH[@]}" | sort -f | while IFS= read -r line; do
            echo "  - $line"
        done
    fi
}

compare_tv_shows() {
    echo ""
    echo "=================================================="
    echo "📺 TV SHOW COMPARISON"
    echo "=================================================="

    declare -ga SHOWS_PLEX_ONLY=()
    declare -ga SHOWS_SONARR_ONLY=()
    declare -ga SHOWS_TITLE_MATCH=()

    for tvdb_id in "${!PLEX_SHOW_TVDB[@]}"; do
        if [ -z "${SONARR_SHOWS[$tvdb_id]+_}" ]; then
            SHOWS_PLEX_ONLY+=("${PLEX_SHOW_TVDB[$tvdb_id]}|tvdbId:${tvdb_id}")
        fi
    done

    for tvdb_id in "${!SONARR_SHOWS[@]}"; do
        if [ -z "${PLEX_SHOW_TVDB[$tvdb_id]+_}" ]; then
            SHOWS_SONARR_ONLY+=("${SONARR_SHOWS[$tvdb_id]}|tvdbId:${tvdb_id}")
        fi
    done

    # Fuzzy title matching
    local -A plex_unmatched_titles=()
    for entry in "${SHOWS_PLEX_ONLY[@]}"; do
        local title="${entry%%|*}"
        local id_part="${entry##*|}"
        local id="${id_part#tvdbId:}"
        plex_unmatched_titles[$id]="$title"
    done

    local -A sonarr_unmatched_titles=()
    for entry in "${SHOWS_SONARR_ONLY[@]}"; do
        local title="${entry%%|*}"
        local id_part="${entry##*|}"
        local id="${id_part#tvdbId:}"
        sonarr_unmatched_titles[$id]="$title"
    done

    local -A matched_plex_ids=()
    local -A matched_sonarr_ids=()

    for plex_id in "${!plex_unmatched_titles[@]}"; do
        local plex_norm
        plex_norm=$(normalize_title "${plex_unmatched_titles[$plex_id]}")
        for sonarr_id in "${!sonarr_unmatched_titles[@]}"; do
            [ -n "${matched_sonarr_ids[$sonarr_id]+_}" ] && continue
            local sonarr_norm
            sonarr_norm=$(normalize_title "${sonarr_unmatched_titles[$sonarr_id]}")
            if [ "$plex_norm" = "$sonarr_norm" ]; then
                SHOWS_TITLE_MATCH+=("${plex_unmatched_titles[$plex_id]} (tvdbId: $plex_id) ↔ ${sonarr_unmatched_titles[$sonarr_id]} (tvdbId: $sonarr_id)")
                matched_plex_ids[$plex_id]=1
                matched_sonarr_ids[$sonarr_id]=1
                break
            fi
        done
    done

    # Also check shows without IDs
    for no_id_title in "${PLEX_SHOW_NO_ID[@]}"; do
        local plex_norm
        plex_norm=$(normalize_title "$no_id_title")
        for sonarr_id in "${!sonarr_unmatched_titles[@]}"; do
            [ -n "${matched_sonarr_ids[$sonarr_id]+_}" ] && continue
            local sonarr_norm
            sonarr_norm=$(normalize_title "${sonarr_unmatched_titles[$sonarr_id]}")
            if [ "$plex_norm" = "$sonarr_norm" ]; then
                SHOWS_TITLE_MATCH+=("$no_id_title (no ID) ↔ ${sonarr_unmatched_titles[$sonarr_id]} (tvdbId: $sonarr_id)")
                matched_sonarr_ids[$sonarr_id]=1
                break
            fi
        done
    done

    # Rebuild final lists
    local -a final_plex_only=()
    for entry in "${SHOWS_PLEX_ONLY[@]}"; do
        local id_part="${entry##*|}"
        local id="${id_part#tvdbId:}"
        [ -z "${matched_plex_ids[$id]+_}" ] && final_plex_only+=("$entry")
    done
    SHOWS_PLEX_ONLY=("${final_plex_only[@]}")

    local -a final_sonarr_only=()
    for entry in "${SHOWS_SONARR_ONLY[@]}"; do
        local id_part="${entry##*|}"
        local id="${id_part#tvdbId:}"
        [ -z "${matched_sonarr_ids[$id]+_}" ] && final_sonarr_only+=("$entry")
    done
    SHOWS_SONARR_ONLY=("${final_sonarr_only[@]}")

    # Print results
    echo ""
    echo "TV Shows in Plex but not in Sonarr (${#SHOWS_PLEX_ONLY[@]}):"
    if [ ${#SHOWS_PLEX_ONLY[@]} -gt 0 ]; then
        printf '%s\n' "${SHOWS_PLEX_ONLY[@]}" | sort -t'|' -k1 -f | while IFS='|' read -r title id; do
            echo "  - $title ($id)"
        done
    else
        echo "  (none)"
    fi

    echo ""
    echo "TV Shows in Sonarr (downloaded) but not in Plex (${#SHOWS_SONARR_ONLY[@]}):"
    if [ ${#SHOWS_SONARR_ONLY[@]} -gt 0 ]; then
        printf '%s\n' "${SHOWS_SONARR_ONLY[@]}" | sort -t'|' -k1 -f | while IFS='|' read -r title id; do
            echo "  - $title ($id)"
        done
    else
        echo "  (none)"
    fi

    if [ ${#SHOWS_TITLE_MATCH[@]} -gt 0 ]; then
        echo ""
        echo "TV Shows matched by title — likely same content, different IDs (${#SHOWS_TITLE_MATCH[@]}):"
        printf '%s\n' "${SHOWS_TITLE_MATCH[@]}" | sort -f | while IFS= read -r line; do
            echo "  - $line"
        done
    fi
}

####### REPORT GENERATION #######

generate_report() {
    echo ""
    echo "📝 Generating report..."

    local elapsed=$(( $(date +%s) - START_TIME ))
    local total_mismatches=$(( ${#MOVIES_PLEX_ONLY[@]} + ${#MOVIES_RADARR_ONLY[@]} + ${#SHOWS_PLEX_ONLY[@]} + ${#SHOWS_SONARR_ONLY[@]} ))

    # Determine health status
    local health_status="ok" health_msg="All synced"
    if [ $total_mismatches -gt 20 ]; then
        health_status="warning"
        health_msg="$total_mismatches mismatches found"
    elif [ $total_mismatches -gt 0 ]; then
        health_status="ok"
        health_msg="$total_mismatches mismatches found"
    fi

    # Build JSON arrays for each category
    local movies_plex_only_json="[]"
    if [ ${#MOVIES_PLEX_ONLY[@]} -gt 0 ]; then
        movies_plex_only_json=$(printf '%s\n' "${MOVIES_PLEX_ONLY[@]}" | sort -t'|' -k1 -f | jq -R -s '
            split("\n") | map(select(length > 0)) | map(
                split("|") | {
                    title: .[0],
                    id: .[1],
                    url: (if .[1] | test("tmdbId:") then "https://www.themoviedb.org/movie/" + (.[1] | ltrimstr("tmdbId:")) else null end),
                    action: "Not tracked in Radarr — add or verify UMTK placeholder"
                }
            )')
    fi

    local movies_radarr_only_json="[]"
    if [ ${#MOVIES_RADARR_ONLY[@]} -gt 0 ]; then
        movies_radarr_only_json=$(printf '%s\n' "${MOVIES_RADARR_ONLY[@]}" | sort -t'|' -k1 -f | jq -R -s '
            split("\n") | map(select(length > 0)) | map(
                split("|") | {
                    title: .[0],
                    id: .[1],
                    url: (if .[1] | test("tmdbId:") then "https://www.themoviedb.org/movie/" + (.[1] | ltrimstr("tmdbId:")) else null end),
                    action: "File exists in Radarr but not in Plex — rescan Plex library"
                }
            )')
    fi

    local movies_title_match_json="[]"
    if [ ${#MOVIES_TITLE_MATCH[@]} -gt 0 ]; then
        movies_title_match_json=$(printf '%s\n' "${MOVIES_TITLE_MATCH[@]}" | sort -f | jq -R -s '
            split("\n") | map(select(length > 0)) | map({match: ., action: "Same title, different IDs — verify correct match in Radarr"})')
    fi

    local shows_plex_only_json="[]"
    if [ ${#SHOWS_PLEX_ONLY[@]} -gt 0 ]; then
        shows_plex_only_json=$(printf '%s\n' "${SHOWS_PLEX_ONLY[@]}" | sort -t'|' -k1 -f | jq -R -s '
            split("\n") | map(select(length > 0)) | map(
                split("|") | {
                    title: .[0],
                    id: .[1],
                    url: (if .[1] | test("tvdbId:") then "https://www.thetvdb.com/dereferrer/series/" + (.[1] | ltrimstr("tvdbId:")) else null end),
                    action: "Not tracked in Sonarr — add or verify UMTK placeholder"
                }
            )')
    fi

    local shows_sonarr_only_json="[]"
    if [ ${#SHOWS_SONARR_ONLY[@]} -gt 0 ]; then
        shows_sonarr_only_json=$(printf '%s\n' "${SHOWS_SONARR_ONLY[@]}" | sort -t'|' -k1 -f | jq -R -s '
            split("\n") | map(select(length > 0)) | map(
                split("|") | {
                    title: .[0],
                    id: .[1],
                    url: (if .[1] | test("tvdbId:") then "https://www.thetvdb.com/dereferrer/series/" + (.[1] | ltrimstr("tvdbId:")) else null end),
                    action: "Episodes in Sonarr but not in Plex — rescan Plex library"
                }
            )')
    fi

    local shows_title_match_json="[]"
    if [ ${#SHOWS_TITLE_MATCH[@]} -gt 0 ]; then
        shows_title_match_json=$(printf '%s\n' "${SHOWS_TITLE_MATCH[@]}" | sort -f | jq -R -s '
            split("\n") | map(select(length > 0)) | map({match: ., action: "Same title, different IDs — verify correct match in Sonarr"})')
    fi

    # Build duplicates JSON
    local movie_dupes_json="[]"
    if [ ${#PLEX_MOVIE_DUPES[@]} -gt 0 ]; then
        for tmdb_id in "${!PLEX_MOVIE_DUPES[@]}"; do
            movie_dupes_json=$(echo "$movie_dupes_json" | jq --arg id "$tmdb_id" --arg titles "${PLEX_MOVIE_DUPES[$tmdb_id]}" \
                '. + [{tmdb_id: $id, titles: ($titles | split("|"))}]')
        done
    fi

    local show_dupes_json="[]"
    if [ ${#PLEX_SHOW_DUPES[@]} -gt 0 ]; then
        for tvdb_id in "${!PLEX_SHOW_DUPES[@]}"; do
            show_dupes_json=$(echo "$show_dupes_json" | jq --arg id "$tvdb_id" --arg titles "${PLEX_SHOW_DUPES[$tvdb_id]}" \
                '. + [{tvdb_id: $id, titles: ($titles | split("|"))}]')
        done
    fi

    # Build no-ID items
    local movies_no_id_json="[]"
    if [ ${#PLEX_MOVIE_NO_ID[@]} -gt 0 ]; then
        movies_no_id_json=$(printf '%s\n' "${PLEX_MOVIE_NO_ID[@]}" | sort -f | jq -R -s 'split("\n") | map(select(length > 0))')
    fi

    local shows_no_id_json="[]"
    if [ ${#PLEX_SHOW_NO_ID[@]} -gt 0 ]; then
        shows_no_id_json=$(printf '%s\n' "${PLEX_SHOW_NO_ID[@]}" | sort -f | jq -R -s 'split("\n") | map(select(length > 0))')
    fi

    # Write final JSON report
    jq -n \
        --argjson version 1 \
        --arg type "plex-vs-arrs" \
        --arg generated "$(date -Iseconds)" \
        --arg generated_by "$SCRIPT_NAME" \
        --argjson duration "$elapsed" \
        --arg health_status "$health_status" \
        --arg health_msg "$health_msg" \
        --argjson plex_movies "$TOTAL_PLEX_MOVIES" \
        --argjson plex_movies_with_id "${#PLEX_MOVIE_TMDB[@]}" \
        --argjson plex_movies_no_id "${#PLEX_MOVIE_NO_ID[@]}" \
        --argjson plex_movie_dupes "${#PLEX_MOVIE_DUPES[@]}" \
        --argjson radarr_movies "${#RADARR_MOVIES[@]}" \
        --argjson plex_shows "$TOTAL_PLEX_SHOWS" \
        --argjson plex_shows_with_id "${#PLEX_SHOW_TVDB[@]}" \
        --argjson plex_shows_no_id "${#PLEX_SHOW_NO_ID[@]}" \
        --argjson plex_show_dupes "${#PLEX_SHOW_DUPES[@]}" \
        --argjson sonarr_shows "${#SONARR_SHOWS[@]}" \
        --argjson movies_plex_only_count "${#MOVIES_PLEX_ONLY[@]}" \
        --argjson movies_radarr_only_count "${#MOVIES_RADARR_ONLY[@]}" \
        --argjson movies_title_match_count "${#MOVIES_TITLE_MATCH[@]}" \
        --argjson shows_plex_only_count "${#SHOWS_PLEX_ONLY[@]}" \
        --argjson shows_sonarr_only_count "${#SHOWS_SONARR_ONLY[@]}" \
        --argjson shows_title_match_count "${#SHOWS_TITLE_MATCH[@]}" \
        --argjson movies_plex_only "$movies_plex_only_json" \
        --argjson movies_radarr_only "$movies_radarr_only_json" \
        --argjson movies_title_match "$movies_title_match_json" \
        --argjson shows_plex_only "$shows_plex_only_json" \
        --argjson shows_sonarr_only "$shows_sonarr_only_json" \
        --argjson shows_title_match "$shows_title_match_json" \
        --argjson movie_dupes "$movie_dupes_json" \
        --argjson show_dupes "$show_dupes_json" \
        --argjson movies_no_id "$movies_no_id_json" \
        --argjson shows_no_id "$shows_no_id_json" \
        '{
            version: $version,
            type: $type,
            generated: $generated,
            generated_by: $generated_by,
            duration_seconds: $duration,
            health: {status: $health_status, message: $health_msg},
            summary: {
                plex_movies: $plex_movies,
                plex_movies_with_id: $plex_movies_with_id,
                radarr_movies: $radarr_movies,
                plex_shows: $plex_shows,
                plex_shows_with_id: $plex_shows_with_id,
                sonarr_shows: $sonarr_shows,
                movies_plex_only: $movies_plex_only_count,
                movies_radarr_only: $movies_radarr_only_count,
                shows_plex_only: $shows_plex_only_count,
                shows_sonarr_only: $shows_sonarr_only_count,
                total_mismatches: ($movies_plex_only_count + $movies_radarr_only_count + $shows_plex_only_count + $shows_sonarr_only_count)
            },
            data: {
                movies: {
                    plex_only: $movies_plex_only,
                    radarr_only: $movies_radarr_only,
                    title_matches: $movies_title_match
                },
                shows: {
                    plex_only: $shows_plex_only,
                    sonarr_only: $shows_sonarr_only,
                    title_matches: $shows_title_match
                },
                duplicates: {
                    movies: $movie_dupes,
                    shows: $show_dupes
                },
                no_id: {
                    movies: $movies_no_id,
                    shows: $shows_no_id
                }
            }
        }' > "$REPORT_FILE"

    echo "  Report saved to: $REPORT_FILE"
}

####### SUMMARY #######

print_summary() {
    echo ""
    echo "=================================================="
    echo "📊 SUMMARY"
    echo "=================================================="
    echo "Total Movies in Plex: $TOTAL_PLEX_MOVIES"
    echo "  With usable IDs: ${#PLEX_MOVIE_TMDB[@]}"
    echo "  Without usable IDs: ${#PLEX_MOVIE_NO_ID[@]}"
    echo "  Duplicates: ${#PLEX_MOVIE_DUPES[@]}"
    echo "Total Movies in Radarr (downloaded): ${#RADARR_MOVIES[@]}"
    echo ""
    echo "Total TV Shows in Plex: $TOTAL_PLEX_SHOWS"
    echo "  With usable IDs: ${#PLEX_SHOW_TVDB[@]}"
    echo "  Without usable IDs: ${#PLEX_SHOW_NO_ID[@]}"
    echo "  Duplicates: ${#PLEX_SHOW_DUPES[@]}"
    echo "Total TV Shows in Sonarr (downloaded): ${#SONARR_SHOWS[@]}"
    echo ""
    echo "Movies only in Plex: ${#MOVIES_PLEX_ONLY[@]}"
    echo "Movies only in Radarr: ${#MOVIES_RADARR_ONLY[@]}"
    echo "Movies matched by title: ${#MOVIES_TITLE_MATCH[@]}"
    echo "TV Shows only in Plex: ${#SHOWS_PLEX_ONLY[@]}"
    echo "TV Shows only in Sonarr: ${#SHOWS_SONARR_ONLY[@]}"
    echo "TV Shows matched by title: ${#SHOWS_TITLE_MATCH[@]}"

    local elapsed=$(( $(date +%s) - START_TIME ))
    echo ""
    echo "Completed in ${elapsed}s"
}

####### DISCORD NOTIFICATION #######

send_discord_summary() {
    local elapsed=$(( $(date +%s) - START_TIME ))
    local plex_only_movies=${#MOVIES_PLEX_ONLY[@]}
    local radarr_only=${#MOVIES_RADARR_ONLY[@]}
    local plex_only_shows=${#SHOWS_PLEX_ONLY[@]}
    local sonarr_only=${#SHOWS_SONARR_ONLY[@]}
    local total_mismatches=$((plex_only_movies + radarr_only + plex_only_shows + sonarr_only))

    local desc="**Movies:** ${#PLEX_MOVIE_TMDB[@]} in Plex, ${#RADARR_MOVIES[@]} in Radarr
**TV Shows:** ${#PLEX_SHOW_TVDB[@]} in Plex, ${#SONARR_SHOWS[@]} in Sonarr

**Mismatches:**
• Movies only in Plex: $plex_only_movies
• Movies only in Radarr: $radarr_only
• TV Shows only in Plex: $plex_only_shows
• TV Shows only in Sonarr: $sonarr_only"

    if [ $total_mismatches -eq 0 ]; then
        discord_notify "success" "Plex vs ARRs — All Synced" "$desc"
    else
        discord_notify "warning" "Plex vs ARRs — $total_mismatches Mismatches" "$desc"
    fi
}

####### MAIN #######

main() {
    echo "Plex vs ARRs Check v${VERSION}"
    echo "$(date '+%Y-%m-%d %H:%M:%S')"

    # Fetch data
    fetch_plex_movies || exit 1
    fetch_plex_tv_shows || exit 1
    fetch_radarr_movies || exit 1
    fetch_sonarr_tv_shows || exit 1

    # Compare
    compare_movies
    compare_tv_shows

    # Report & summary
    generate_report
    print_summary
    send_discord_summary
}

main
