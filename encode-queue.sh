#!/bin/bash
# Encode Queue
# Generates a prioritized re-encode list from non-HEVC files.
# Largest files first, with estimated space savings.
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
Encode Queue — Generates a prioritized re-encode list.

Usage: encode-queue.sh [options] [directory]

Scans for non-HEVC video files and generates a prioritized list for
re-encoding to HEVC/x265. Sorted by size (largest first) for maximum
space savings. Estimates savings based on typical HEVC compression ratios.

Does NOT perform any encoding — only generates the queue.

Options:
  -h, --help        Show this help message
  -q, --quiet       Suppress terminal output (log only)
  --no-discord      Skip Discord notification
  --limit=N         Limit output to N files (default: 50)
  --min-size=N      Minimum file size in GB to include (default: 1)

Defaults to /mnt/Media/TV Shows if no directory is specified.
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
send_discord() {
    local webhook="$1" title="$2" description="$3" color="$4"
    [ "$NO_DISCORD" = true ] && return
    if [ ${#description} -gt $DISCORD_DESC_LIMIT ]; then
        description="${description:0:$((DISCORD_DESC_LIMIT - 20))}…

*(truncated)*"
    fi
    local payload
    payload=$(jq -n --arg title "$title" --arg desc "$description" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson color "$color" \
        '{embeds: [{title: $title, description: $desc, color: $color, footer: {text: "'"$FOOTER_PREFIX"' • encode-queue.sh"}, timestamp: $ts}]}')
    curl -s -H "Content-Type: application/json" -d "$payload" "$webhook" >/dev/null 2>&1
}

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
echo "Found $NUM_FILES video files. Filtering non-HEVC..."
echo

# Scan and collect non-HEVC files above minimum size
TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

COUNTER=0
NON_HEVC_COUNT=0

for file in "${VIDEO_FILES[@]}"; do
    COUNTER=$((COUNTER + 1))

    size_bytes=$(stat -c%s "$file" 2>/dev/null || echo 0)

    # Skip files below minimum size
    [ "$size_bytes" -lt "$MIN_SIZE_BYTES" ] && continue

    # Get codec and resolution in a single ffprobe call
    probe_output=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,height -of "csv=s=,:p=0" "$file" 2>/dev/null)
    codec=$(printf '%s' "$probe_output" | cut -d',' -f1 | tr -d '[:space:]')
    resolution=$(printf '%s' "$probe_output" | cut -d',' -f2 | tr -d '[:space:]')

    # Skip HEVC and AV1 (already efficient)
    [ "$codec" = "hevc" ] && continue
    [ "$codec" = "av1" ] && continue
    [ -z "$codec" ] && continue

    [ -n "$resolution" ] && resolution="${resolution}p" || resolution="N/A"

    NON_HEVC_COUNT=$((NON_HEVC_COUNT + 1))

    # Clean path for display
    rel_path="$file"
    for d in "${DIRECTORIES[@]}"; do
        rel_path="${rel_path#$d/}"
    done
    rel_path=$(printf '%s' "$rel_path" | sed 's/ {tmdb-[0-9]*}//g')

    printf "%s\t%s\t%s\t%s\t%s\n" "$rel_path" "$size_bytes" "$codec" "$resolution" "$file" >> "$TMP_FILE"

    # Progress
    if [ $((COUNTER % 50)) -eq 0 ]; then
        printf "\r  Progress: %d/%d" "$COUNTER" "$NUM_FILES"
    fi
done
printf "\r  Progress: %d/%d\n" "$NUM_FILES" "$NUM_FILES"
echo

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
    echo "---"
    echo ""
    echo "## 📂 Grouped by Show/Movie"
    echo ""
    echo "| Show/Movie | Files | Total Size | Est. Savings |"
    echo "|------------|-------|-----------|--------------|"
    awk -F'\t' '{
        split($1, parts, "/")
        name = parts[1]
        sizes[name] += $2
        counts[name]++
    } END {
        for (name in sizes) {
            printf "%s\t%.0f\t%d\n", name, sizes[name], counts[name]
        }
    }' "$TMP_FILE" | sort -t$'\t' -k2 -rn | while IFS=$'\t' read -r name total_bytes file_count; do
        size_h=$(format_size "$total_bytes")
        est_saved=$(format_size $((total_bytes * (100 - HEVC_RATIO) / 100)))
        name_escaped=$(printf '%s' "$name" | sed 's/|/\\|/g')
        printf "| %s | %d | %s | %s |\n" "$name_escaped" "$file_count" "$size_h" "$est_saved"
    done
    echo ""
} > "$REPORT_FILE"

echo "Report saved to: $REPORT_FILE"
echo "Log saved to: $LOG_FILE"

# Discord notification — grouped by show/movie
TOP_GROUPED=$(awk -F'\t' '{
    split($1, parts, "/")
    name = parts[1]
    sizes[name] += $2
    counts[name]++
} END {
    for (name in sizes) {
        printf "%s\t%.0f\t%d\n", name, sizes[name], counts[name]
    }
}' "$TMP_FILE" | sort -t$'\t' -k2 -rn | head -10 | while IFS=$'\t' read -r name total_bytes file_count; do
    size_h=$(format_size "$total_bytes")
    est_saved=$(format_size $((total_bytes * (100 - HEVC_RATIO) / 100)))
    printf "%s · %d files · %s · save ~%s\n" "$name" "$file_count" "$size_h" "$est_saved"
done)

DISCORD_DESC="🔄 **Encode Queue**

📂 \`$DIR_NAMES\`
⏱️ ${DURATION}s

**Summary:**
\`\`\`
Non-HEVC files (>${MIN_SIZE_GB}GB): $NON_HEVC_COUNT
Total size:    $(format_size "${TOTAL_NON_HEVC_BYTES:-0}")
Est. savings:  ~$(format_size "${ESTIMATED_SAVINGS:-0}")
\`\`\`

**Top candidates (by show/movie):**
\`\`\`
$TOP_GROUPED
\`\`\`"

send_discord "$DISCORD_NOTIFICATIONS" "🔄 Encode Queue" "$DISCORD_DESC" "3066993"
