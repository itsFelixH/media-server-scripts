#!/bin/bash
# Encode Queue
# Generates a prioritized re-encode list and optimization suggestions.
# Finds non-HEVC files, biggest TV shows, and HEVC files that could
# benefit from AV1 re-encode or resolution reduction.
#
# Usage:
#   ./encode-queue.sh [options] [directory]
#
# Options:
#   -h, --help        Show this help message
#   -q, --quiet       Suppress terminal output (log only)
#   --no-discord      Skip Discord notification
#   --limit=N         Limit output to N files (default: 50)
#   --min-size=N      Minimum file size in GB to include (default: 1)

####### HELP #######
show_help() {
    cat <<'HELP'
Encode Queue — Generates a prioritized re-encode list and optimization suggestions.

Usage: encode-queue.sh [options] [directory]

Scans video files and generates:
  1. Non-HEVC/AV1 files to re-encode (sorted by size, largest first)
  2. Biggest TV shows by total size
  3. Large HEVC files that could benefit from AV1 or resolution reduction

Does NOT perform any encoding — only generates the report.

Options:
  -h, --help        Show this help message
  -q, --quiet       Suppress terminal output (log only)
  --no-discord      Skip Discord notification
  --limit=N         Limit output to N files (default: 50)
  --min-size=N      Minimum file size in GB to include (default: 1)

Defaults to Movies + TV Shows if no directory is specified.
HELP
}

####### ARGUMENT PARSING #######
QUIET=false
NO_DISCORD=false
LIMIT=""
MIN_SIZE_GB=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        -q|--quiet) QUIET=true; shift ;;
        --no-discord) NO_DISCORD=true; shift ;;
        --limit=*) LIMIT="${1#--limit=}"; shift ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --min-size=*) MIN_SIZE_GB="${1#--min-size=}"; shift ;;
        --min-size) MIN_SIZE_GB="$2"; shift 2 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

####### CONFIGURATION #######
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/encode-queue/encode-queue_${TIMESTAMP}.log"
REPORT_FILE="$REPORT_DIR/encode-queue.md"
mkdir -p "$LOG_DIR/encode-queue"

LIMIT=${LIMIT:-$ENCODE_QUEUE_LIMIT}
MIN_SIZE_GB=${MIN_SIZE_GB:-$ENCODE_QUEUE_MIN_SIZE_GB}
MIN_SIZE_BYTES=$((MIN_SIZE_GB * 1073741824))

# Typical HEVC compression ratio vs h264 (40-60% size reduction)
HEVC_RATIO=$ENCODE_QUEUE_HEVC_RATIO

# Redirect output
if [ "$QUIET" = true ]; then
    exec > "$LOG_FILE" 2>&1
else
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

# Discord — webhooks and limits loaded from config.sh

####### DEPENDENCY CHECK #######
MISSING_DEPS=()
command -v ffprobe &>/dev/null || MISSING_DEPS+=("ffprobe (install ffmpeg)")
command -v jq &>/dev/null || MISSING_DEPS+=("jq")
command -v curl &>/dev/null || MISSING_DEPS+=("curl")

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "ERROR: Missing required dependencies:"
    for dep in "${MISSING_DEPS[@]}"; do echo "  - $dep"; done
    exit 1
fi

####### FUNCTIONS #######
SCRIPT_NAME="encode-queue.sh"

format_size() {
    local size=$1
    if [ "$size" -ge 1073741824 ]; then
        local gb_int=$((size / 1073741824))
        local remainder=$(( (size % 1073741824) * 100 / 1073741824 ))
        printf "%d.%02d GB" "$gb_int" "$remainder"
    elif [ "$size" -ge 1048576 ]; then
        local mb_int=$((size / 1048576))
        local remainder=$(( (size % 1048576) * 100 / 1048576 ))
        printf "%d.%02d MB" "$mb_int" "$remainder"
    else
        printf "%d KB" "$((size / 1024))"
    fi
}

####### MAIN #######
START_TIME=$(date +%s)
echo "=== Encode Queue Generator ==="

# Build list of directories to scan
if [ ${#POSITIONAL[@]} -gt 0 ]; then
    DIRECTORIES=("${POSITIONAL[@]}")
else
    DIRECTORIES=("$MOVIES_DIR" "$TV_DIR")
fi

echo "Directories:"
for d in "${DIRECTORIES[@]}"; do echo "  - $d"; done
echo "Min size: ${MIN_SIZE_GB} GB"
echo "Limit: $LIMIT files"
echo

for d in "${DIRECTORIES[@]}"; do
    if [ ! -d "$d" ]; then
        echo "ERROR: Directory not found: $d"
        exit 1
    fi
done

# Find all video files across all directories
echo "Scanning for video files..."
mapfile -t VIDEO_FILES < <(find "${DIRECTORIES[@]}" -type f \( -iname "*.mkv" -o -iname "*.mp4" \) 2>/dev/null | sort)
NUM_FILES=${#VIDEO_FILES[@]}
echo "Found $NUM_FILES video files. Probing..."
echo

# Single pass: probe all files and cache results
# Format: rel_path \t size_bytes \t codec \t height \t full_path
PROBE_CACHE=$(mktemp)
TMP_FILE=$(mktemp)
OPT_TMP=$(mktemp)
TV_SIZES_TMP=$(mktemp)
cleanup() { rm -f "$PROBE_CACHE" "$TMP_FILE" "$OPT_TMP" "$TV_SIZES_TMP"; }
trap cleanup EXIT

COUNTER=0
for file in "${VIDEO_FILES[@]}"; do
    COUNTER=$((COUNTER + 1))

    size_bytes=$(stat -c%s "$file" 2>/dev/null || echo 0)

    # Skip very small files (not worth probing)
    [ "$size_bytes" -lt "$MIN_SIZE_BYTES" ] && continue

    # Get codec and height in a single ffprobe call
    probe_output=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,height -of "csv=s=,:p=0" "$file" 2>/dev/null)
    codec=$(printf '%s' "$probe_output" | cut -d',' -f1 | tr -d '[:space:]')
    height=$(printf '%s' "$probe_output" | cut -d',' -f2 | tr -d '[:space:]')

    [ -z "$codec" ] && continue

    # Clean path for display
    rel_path="$file"
    for d in "${DIRECTORIES[@]}"; do
        rel_path="${rel_path#$d/}"
    done
    rel_path=$(printf '%s' "$rel_path" | sed 's/ {tmdb-[0-9]*}//g; s/ {tvdb-[0-9]*}//g')

    printf "%s\t%s\t%s\t%s\t%s\n" "$rel_path" "$size_bytes" "$codec" "${height:-0}" "$file" >> "$PROBE_CACHE"

    # Progress
    if [ $((COUNTER % 50)) -eq 0 ]; then
        printf "\r  Progress: %d/%d" "$COUNTER" "$NUM_FILES"
    fi
done
printf "\r  Progress: %d/%d\n" "$NUM_FILES" "$NUM_FILES"
echo

# --- Extract non-HEVC/non-AV1 files for encode queue ---
NON_HEVC_COUNT=0
while IFS=$'\t' read -r rel_path size_bytes codec height full_path; do
    [ "$codec" = "hevc" ] && continue
    [ "$codec" = "av1" ] && continue
    resolution="${height}p"
    [ "$height" = "0" ] && resolution="N/A"
    printf "%s\t%s\t%s\t%s\t%s\n" "$rel_path" "$size_bytes" "$codec" "$resolution" "$full_path" >> "$TMP_FILE"
    NON_HEVC_COUNT=$((NON_HEVC_COUNT + 1))
done < "$PROBE_CACHE"

# Sort by size descending and limit
QUEUE=$(sort -t$'\t' -k2 -rn "$TMP_FILE" | head -"$LIMIT")
QUEUE_COUNT=$(echo "$QUEUE" | grep -c . 2>/dev/null || echo 0)

# Calculate totals using awk to avoid integer overflow
TOTAL_NON_HEVC_BYTES=$(awk -F'\t' '{sum += $2} END {printf "%.0f", sum+0}' "$TMP_FILE" 2>/dev/null)
ESTIMATED_SAVINGS=$(awk -F'\t' -v ratio="$HEVC_RATIO" '{sum += $2} END {printf "%.0f", sum * (100 - ratio) / 100}' "$TMP_FILE" 2>/dev/null)

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Terminal report
echo "=== Encode Queue ==="
echo "Non-HEVC files found: $NON_HEVC_COUNT (above ${MIN_SIZE_GB}GB)"
echo "Total non-HEVC size: $(format_size "$TOTAL_NON_HEVC_BYTES")"
echo "Estimated savings (HEVC): ~$(format_size "$ESTIMATED_SAVINGS")"
echo "Duration: ${DURATION}s"
echo
echo "Queue (top $QUEUE_COUNT by size):"
echo "---"
RANK=0
while IFS=$'\t' read -r rel_path size_bytes codec resolution full_path; do
    RANK=$((RANK + 1))
    size_h=$(format_size "$size_bytes")
    est_saved=$(format_size $((size_bytes * (100 - HEVC_RATIO) / 100)))
    printf "%3d. %-50s %8s  %-5s  %s  (save ~%s)\n" "$RANK" "$rel_path" "$size_h" "$codec" "$resolution" "$est_saved"
done <<< "$QUEUE"
echo "---"
echo

# Build directory label
DIR_NAMES=""
for d in "${DIRECTORIES[@]}"; do DIR_NAMES+="$(basename "$d"), "; done
DIR_NAMES="${DIR_NAMES%, }"

# Generate Markdown Report
{
    echo "# 🔄 Encode Queue Report"
    echo ""
    echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "---"
    echo ""
    echo "## 📊 Summary"
    echo ""
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Directory | \`$DIR_NAMES\` |"
    echo "| Scan Duration | ${DURATION}s |"
    echo "| Video Files Scanned | $NUM_FILES |"
    echo "| Non-HEVC Files Found | $NON_HEVC_COUNT |"
    echo "| Total Size | $(format_size "$TOTAL_NON_HEVC_BYTES") |"
    echo "| Estimated Savings | ~$(format_size "$ESTIMATED_SAVINGS") |"
    echo "| Compression Ratio | ~${HEVC_RATIO}% (HEVC) |"
    echo "| Min File Size Filter | ${MIN_SIZE_GB} GB |"
    echo ""
    echo "---"
    echo ""
    echo "## 📋 Encode Queue (Top $QUEUE_COUNT Files)"
    echo ""
    echo "| Rank | File | Size | Codec | Resolution | Est. Savings |"
    echo "|------|------|------|-------|------------|--------------|"
    RANK=0
    while IFS=$'\t' read -r rel_path size_bytes codec resolution full_path; do
        RANK=$((RANK + 1))
        size_h=$(format_size "$size_bytes")
        est_saved=$(format_size $((size_bytes * (100 - HEVC_RATIO) / 100)))
        rel_path_escaped=$(printf '%s' "$rel_path" | sed 's/|/\\|/g')
        printf "| %3d | \`%s\` | %s | %s | %s | %s |\n" "$RANK" "$rel_path_escaped" "$size_h" "$codec" "$resolution" "$est_saved"
    done <<< "$QUEUE"
    echo ""
} > "$REPORT_FILE"

# --- Additional analysis: biggest TV shows and optimization suggestions ---
echo "Analyzing TV show sizes..."

# Biggest TV shows by total size (from probe cache — only includes files >= min_size)
# Also check full filesystem for complete picture
if [ -d "$TV_DIR" ]; then
    for show_dir in "$TV_DIR"/*/; do
        [ -d "$show_dir" ] || continue
        show_name=$(basename "$show_dir")
        show_name_clean=$(printf '%s' "$show_name" | sed 's/ {tmdb-[0-9]*}//g; s/ {tvdb-[0-9]*}//g')
        total_bytes=$(find "$show_dir" -type f \( -iname "*.mkv" -o -iname "*.mp4" \) -printf '%s\n' 2>/dev/null | awk '{sum+=$1} END {printf "%.0f", sum+0}')
        [ "$total_bytes" -gt 0 ] && printf "%s\t%s\n" "$show_name_clean" "$total_bytes" >> "$TV_SIZES_TMP"
    done

    TOP_SHOWS=$(sort -t$'\t' -k2 -rn "$TV_SIZES_TMP" | head -20)

    {
        echo ""
        echo "---"
        echo ""
        echo "## 📺 Biggest TV Shows (Top 20)"
        echo ""
        echo "| Show | Total Size | Suggestion |"
        echo "|------|-----------|------------|"
        while IFS=$'\t' read -r name total_bytes; do
            size_h=$(format_size "$total_bytes")
            suggestion=""
            if [ "$total_bytes" -gt 53687091200 ]; then  # >50GB
                suggestion="Consider AV1 re-encode"
            elif [ "$total_bytes" -gt 21474836480 ]; then  # >20GB
                suggestion="Good AV1 candidate"
            fi
            name_escaped=$(printf '%s' "$name" | sed 's/|/\\|/g')
            printf "| %s | %s | %s |\n" "$name_escaped" "$size_h" "$suggestion"
        done <<< "$TOP_SHOWS"
        echo ""
    } >> "$REPORT_FILE"
fi

# Optimization suggestions: large HEVC files from probe cache
echo "Extracting optimization candidates from cache..."
OPT_COUNT=0
while IFS=$'\t' read -r rel_path size_bytes codec height full_path; do
    [ "$codec" != "hevc" ] && continue
    [ "$size_bytes" -lt 3221225472 ] && continue  # Skip < 3GB

    suggestion=""
    if [ "$height" -ge 2160 ]; then
        suggestion="4K → consider 1080p if not HDR"
    elif [ "$height" -ge 1080 ] && [ "$size_bytes" -gt 5368709120 ]; then
        suggestion="Large 1080p → AV1 re-encode"
    elif [ "$height" -ge 1080 ] && [ "$size_bytes" -gt 3221225472 ]; then
        suggestion="AV1 candidate"
    else
        continue
    fi

    printf "%s\t%s\t%sp\t%s\n" "$rel_path" "$size_bytes" "$height" "$suggestion" >> "$OPT_TMP"
    OPT_COUNT=$((OPT_COUNT + 1))
done < "$PROBE_CACHE"

echo "  Optimization candidates: $OPT_COUNT"

if [ "$OPT_COUNT" -gt 0 ]; then
    OPT_QUEUE=$(sort -t$'\t' -k2 -rn "$OPT_TMP" | head -20)
    OPT_TOTAL=$(awk -F'\t' '{sum += $2} END {printf "%.0f", sum+0}' "$OPT_TMP")
    OPT_SAVINGS=$(awk -F'\t' '{sum += $2} END {printf "%.0f", sum * 30 / 100}' "$OPT_TMP")

    {
        echo "---"
        echo ""
        echo "## 🚀 Optimization Suggestions (HEVC → AV1 / Resolution)"
        echo ""
        echo "Already encoded in HEVC but still large. Further savings possible with AV1 (~30% smaller) or resolution reduction."
        echo ""
        echo "| Metric | Value |"
        echo "|--------|-------|"
        echo "| Candidates | $OPT_COUNT |"
        echo "| Total size | $(format_size "$OPT_TOTAL") |"
        echo "| Est. savings (AV1) | ~$(format_size "$OPT_SAVINGS") |"
        echo ""
        echo "| File | Size | Resolution | Suggestion |"
        echo "|------|------|-----------|------------|"
        while IFS=$'\t' read -r rel_path size_bytes resolution suggestion; do
            size_h=$(format_size "$size_bytes")
            rel_path_escaped=$(printf '%s' "$rel_path" | sed 's/|/\\|/g')
            printf "| \`%s\` | %s | %s | %s |\n" "$rel_path_escaped" "$size_h" "$resolution" "$suggestion"
        done <<< "$OPT_QUEUE"
        echo ""
    } >> "$REPORT_FILE"
fi

echo "Report saved to: $REPORT_FILE"
echo "Log saved to: $LOG_FILE"

# Discord notification
TOP_FILES=$(echo "$QUEUE" | head -5 | while IFS=$'\t' read -r rel_path size_bytes codec resolution full_path; do
    name=$(echo "$rel_path" | cut -d'/' -f1)
    size_h=$(format_size "$size_bytes")
    est_saved=$(format_size $((size_bytes * (100 - HEVC_RATIO) / 100)))
    printf "%s · %s · save ~%s\n" "$name" "$size_h" "$est_saved"
done)

SAVINGS_PCT=$(( (ESTIMATED_SAVINGS * 100) / (TOTAL_NON_HEVC_BYTES > 0 ? TOTAL_NON_HEVC_BYTES : 1) ))
DISCORD_DESC="**$NON_HEVC_COUNT** files · $(format_size "${TOTAL_NON_HEVC_BYTES:-0}") → save ~$(format_size "${ESTIMATED_SAVINGS:-0}") (${SAVINGS_PCT}%)
\`\`\`
$TOP_FILES
\`\`\`"

discord_notify "success" "🔄 Encode Queue" "$DISCORD_DESC"
