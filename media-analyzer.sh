#!/bin/bash
# Media Analyzer
# Analyzes video files in a media directory with different filter modes.
# Logs output and posts results to Discord.
#
# Usage:
#   ./media-analyzer.sh [options] [mode] [directory]
#
# Modes:
#   all         Full analysis of all video files (default)
#   non-hevc    Find files that are NOT HEVC/x265
#   hevc        Find files that ARE HEVC/x265
#   av1         Find AV1 encoded files
#   h264        Find H.264/x264 encoded files
#   non-hd      Find files below 720p (SD content, excludes unknown)
#   4k          Find 4K/2160p files
#   large       Find files larger than threshold (default 5GB, set THRESHOLD_GB=N)
#
# Options:
#   -h, --help           Show this help message
#   -q, --quiet          Suppress terminal output (log only)
#   --no-discord         Skip Discord notification
#   --include-unknown    Include files with unknown resolution in non-hd mode
#
# Examples:
#   ./media-analyzer.sh non-hevc "/mnt/Media/Movies"
#   ./media-analyzer.sh av1
#   ./media-analyzer.sh --quiet all "/mnt/Media/TV Shows"
#   THRESHOLD_GB=10 ./media-analyzer.sh large "/mnt/Media/TV Shows"

####### FUNCTIONS (early — needed by arg parsing) #######
show_help() {
    cat <<'HELP'
Media Analyzer — Analyzes video files with different filter modes.

Usage: media-analyzer.sh [options] [mode] [directory...]

Modes:
  all         Full analysis of all video files (default)
  non-hevc    Find files that are NOT HEVC/x265
  hevc        Find files that ARE HEVC/x265
  av1         Find AV1 encoded files
  h264        Find H.264/x264 encoded files
  non-hd      Find files below 720p (excludes unknown unless --include-unknown)
  4k          Find 4K/2160p files
  large       Find files larger than threshold (default 5GB, set THRESHOLD_GB=N)
  duplicates  Find files with the same name in different directories
  low-bitrate Find files with unusually low bitrate (<1 Mbps, set MIN_BITRATE_KBPS=N)

Options:
  -h, --help           Show this help message
  -q, --quiet          Suppress terminal output (log only)
  --no-discord         Skip Discord notification
  --include-unknown    Include files with unknown resolution in non-hd mode
  --sort=FIELD         Sort output by: size (default), name, codec, res

Multiple directories can be specified to scan them all in one run.
Defaults to /mnt/Media/TV Shows if no directory is given.
HELP
}

####### ARGUMENT PARSING #######
QUIET=false
NO_DISCORD=false
INCLUDE_UNKNOWN=false
SORT_BY="size"
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -q|--quiet)
            QUIET=true
            shift
            ;;
        --no-discord)
            NO_DISCORD=true
            shift
            ;;
        --include-unknown)
            INCLUDE_UNKNOWN=true
            shift
            ;;
        --sort=*)
            SORT_BY="${1#--sort=}"
            shift
            ;;
        --sort)
            SORT_BY="$2"
            shift 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

####### CONFIGURATION #######
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/media-analyzer/media-analyzer_${TIMESTAMP}.log"
REPORT_FILE="$REPORT_DIR/media-analysis.md"
mkdir -p "$LOG_DIR/media-analyzer"

MODE="${POSITIONAL[0]:-all}"
# Support multiple directories (all positional args after mode)
if [ ${#POSITIONAL[@]} -gt 1 ]; then
    DIRECTORIES=("${POSITIONAL[@]:1}")
else
    DIRECTORIES=("$MEDIA_ANALYZER_DIR")
fi
THRESHOLD_GB=${THRESHOLD_GB:-$MEDIA_ANALYZER_THRESHOLD_GB}
THRESHOLD_BYTES=$((THRESHOLD_GB * 1073741824))
MIN_BITRATE_KBPS=${MIN_BITRATE_KBPS:-$MEDIA_ANALYZER_MIN_BITRATE}

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
    for dep in "${MISSING_DEPS[@]}"; do
        echo "  - $dep"
    done
    exit 1
fi

####### FUNCTIONS #######
send_discord() {
    local webhook="$1"
    local title="$2"
    local description="$3"
    local color="$4"

    [ "$NO_DISCORD" = true ] && return

    # Truncate description if it exceeds Discord's limit
    if [ ${#description} -gt $DISCORD_DESC_LIMIT ]; then
        description="${description:0:$((DISCORD_DESC_LIMIT - 20))}…

*(truncated)*"
    fi

    local payload
    payload=$(jq -n \
        --arg title "$title" \
        --arg desc "$description" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson color "$color" \
        '{embeds: [{title: $title, description: $desc, color: $color, footer: {text: "'"$FOOTER_PREFIX"' • media-analyzer.sh"}, timestamp: $ts}]}')

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
    elif [ "$size" -ge 1024 ]; then
        local kb_int=$((size / 1024))
        printf "%d KB" "$kb_int"
    else
        printf "%d bytes" "$size"
    fi
}

matches_filter() {
    local codec="$1"
    local resolution="$2"
    local size_bytes="$3"
    local res_num="${resolution%p}"

    case "$MODE" in
        all)      return 0 ;;
        non-hevc) [ "$codec" != "hevc" ] && return 0; return 1 ;;
        hevc)     [ "$codec" = "hevc" ] && return 0; return 1 ;;
        av1)      [ "$codec" = "av1" ] && return 0; return 1 ;;
        h264)     [ "$codec" = "h264" ] && return 0; return 1 ;;
        non-hd)
            if [ "$res_num" = "N/A" ] || [ -z "$res_num" ]; then
                [ "$INCLUDE_UNKNOWN" = true ] && return 0
                return 1
            fi
            [ "$res_num" -lt 720 ] && return 0
            return 1
            ;;
        4k)
            [ -n "$res_num" ] && [ "$res_num" != "N/A" ] && [ "$res_num" -ge 2160 ] && return 0
            return 1
            ;;
        large)
            [ "$size_bytes" -ge "$THRESHOLD_BYTES" ] && return 0
            return 1
            ;;
        duplicates|low-bitrate)
            # These modes are handled separately after scanning
            return 0
            ;;
        *)
            echo "ERROR: Unknown mode '$MODE'"
            echo
            show_help
            exit 1
            ;;
    esac
}

mode_label() {
    case "$MODE" in
        all)          echo "All Files" ;;
        non-hevc)     echo "Non-HEVC" ;;
        hevc)         echo "HEVC/x265" ;;
        av1)          echo "AV1" ;;
        h264)         echo "H.264/x264" ;;
        non-hd)       echo "Non-HD (<720p)" ;;
        4k)           echo "4K (2160p+)" ;;
        large)        echo "Large Files (>${THRESHOLD_GB}GB)" ;;
        duplicates)   echo "Duplicate Filenames" ;;
        low-bitrate)  echo "Low Bitrate (<${MIN_BITRATE_KBPS} kbps)" ;;
    esac
}

mode_emoji() {
    case "$MODE" in
        all)          echo "🎬" ;;
        non-hevc)     echo "⚠️" ;;
        hevc)         echo "✅" ;;
        av1)          echo "🆕" ;;
        h264)         echo "📼" ;;
        non-hd)       echo "📉" ;;
        4k)           echo "🔷" ;;
        large)        echo "💾" ;;
        duplicates)   echo "📋" ;;
        low-bitrate)  echo "🔉" ;;
    esac
}

####### MAIN #######
START_TIME=$(date +%s)
LABEL=$(mode_label)
EMOJI=$(mode_emoji)

echo "=== Media Analyzer ==="
echo "Mode: $LABEL"
if [ ${#DIRECTORIES[@]} -eq 1 ]; then
    echo "Directory: ${DIRECTORIES[0]}"
    DIR_LABEL=$(basename "${DIRECTORIES[0]}")
else
    echo "Directories:"
    for d in "${DIRECTORIES[@]}"; do echo "  - $d"; done
    DIR_LABEL="Multiple"
fi
[ "$MODE" = "large" ] && echo "Threshold: ${THRESHOLD_GB} GB"
echo

# Validate directories
for d in "${DIRECTORIES[@]}"; do
    if [ ! -d "$d" ]; then
        echo "ERROR: Directory not found: $d"
        send_discord "$DISCORD_ALERTS" "❌ Media Analyzer Failed" "Directory not found: \`$d\`
Mode: $LABEL" "16711680"
        exit 1
    fi
done

# Find all video files across all directories
mapfile -t VIDEO_FILES < <(find "${DIRECTORIES[@]}" -type f \( -iname "*.mkv" -o -iname "*.mp4" \) 2>/dev/null | sort)
NUM_FILES=${#VIDEO_FILES[@]}

if [ "$NUM_FILES" -eq 0 ]; then
    echo "No video files found."
    send_discord "$DISCORD_ALERTS" "⚠️ Media Analyzer" "No video files found in \`$DIR_LABEL\`" "16776960"
    exit 0
fi

echo "Found $NUM_FILES video files. Scanning..."
echo

# Temp file for results: filename \t dirpath \t size_bytes \t resolution \t codec
TMP_ALL=$(mktemp)
TMP_MATCH=$(mktemp)
trap 'rm -f "$TMP_ALL" "$TMP_MATCH"' EXIT

COUNTER=0
PROBE_FAILURES=0

for file in "${VIDEO_FILES[@]}"; do
    COUNTER=$((COUNTER + 1))

    filename="${file##*/}"
    dirpath="${file%/*}"
    size_bytes=$(stat -c%s "$file" 2>/dev/null || echo 0)

    # Get codec and resolution in a single ffprobe call
    probe_output=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,height \
        -of "csv=s=,:p=0" "$file" 2>/dev/null)

    if [ -z "$probe_output" ]; then
        PROBE_FAILURES=$((PROBE_FAILURES + 1))
        codec="N/A"
        resolution="N/A"
    else
        codec=$(printf '%s' "$probe_output" | cut -d',' -f1 | tr -d '[:space:]')
        resolution=$(printf '%s' "$probe_output" | cut -d',' -f2 | tr -d '[:space:]')
        [ -z "$codec" ] && codec="N/A"
        if [ -n "$resolution" ]; then
            resolution="${resolution}p"
        else
            resolution="N/A"
        fi
    fi

    # Tab-separated: filename, dirpath, size_bytes, resolution, codec
    line=$(printf "%s\t%s\t%s\t%s\t%s" "$filename" "$dirpath" "$size_bytes" "$resolution" "$codec")
    echo "$line" >> "$TMP_ALL"

    if matches_filter "$codec" "$resolution" "$size_bytes"; then
        echo "$line" >> "$TMP_MATCH"
    fi

    # Progress indicator
    if [ $((COUNTER % 25)) -eq 0 ]; then
        PERCENT=$(( COUNTER * 100 / NUM_FILES ))
        printf "\r  Progress: %d/%d (%d%%)" "$COUNTER" "$NUM_FILES" "$PERCENT"
    fi
done

printf "\r  Progress: %d/%d (100%%)\n" "$NUM_FILES" "$NUM_FILES"
echo

# Special post-processing for duplicates and low-bitrate modes
if [ "$MODE" = "duplicates" ]; then
    # Find filenames that appear in multiple directories
    > "$TMP_MATCH"
    awk -F'\t' '{print $1}' "$TMP_ALL" | sort | uniq -d | while read -r dup_name; do
        grep "^${dup_name}	" "$TMP_ALL" >> "$TMP_MATCH"
    done
elif [ "$MODE" = "low-bitrate" ]; then
    # Re-scan matched files for bitrate (slower — only runs in this mode)
    echo "Checking bitrate for $NUM_FILES files..."
    > "$TMP_MATCH"
    while IFS=$'\t' read -r name dir size_b res codec; do
        local_file="$dir/$name"
        bitrate=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=s=,:p=0 "$local_file" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$bitrate" ] && [ "$bitrate" != "N/A" ] && [ "$bitrate" -gt 0 ] 2>/dev/null; then
            bitrate_kbps=$((bitrate / 1000))
            if [ "$bitrate_kbps" -lt "$MIN_BITRATE_KBPS" ]; then
                printf "%s\t%s\t%s\t%s\t%s\n" "$name" "$dir" "$size_b" "$res" "$codec" >> "$TMP_MATCH"
            fi
        fi
    done < "$TMP_ALL"
fi

# Stats
TOTAL_SCANNED=$NUM_FILES
MATCH_COUNT=$(wc -l < "$TMP_MATCH" 2>/dev/null || echo 0)
MATCH_BYTES=$(awk -F'\t' '{sum += $3} END {printf "%.0f", sum+0}' "$TMP_MATCH" 2>/dev/null)
MATCH_HUMAN=$(format_size "${MATCH_BYTES:-0}")
TOTAL_BYTES=$(awk -F'\t' '{sum += $3} END {printf "%.0f", sum+0}' "$TMP_ALL" 2>/dev/null)
TOTAL_HUMAN=$(format_size "${TOTAL_BYTES:-0}")

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Percentage
if [ "$TOTAL_SCANNED" -gt 0 ]; then
    PCT_INT=$(( MATCH_COUNT * 10000 / TOTAL_SCANNED ))
    PCT=$(printf "%d.%02d" $((PCT_INT / 100)) $((PCT_INT % 100)))
else
    PCT="0.00"
fi

# Determine sort command based on --sort flag
# Fields: filename(1) dirpath(2) size_bytes(3) resolution(4) codec(5)
case "$SORT_BY" in
    size) SORT_CMD="sort -t$'\t' -k3 -rn" ;;
    name) SORT_CMD="sort -t$'\t' -k1,1" ;;
    codec) SORT_CMD="sort -t$'\t' -k5,5 -k3 -rn" ;;
    res) SORT_CMD="sort -t$'\t' -k4,4 -rn" ;;
    *) SORT_CMD="sort -t$'\t' -k3 -rn" ;;
esac

# Terminal report
echo "=== Results: $LABEL ==="
echo "Scanned: $TOTAL_SCANNED files ($TOTAL_HUMAN)"
echo "Matched: $MATCH_COUNT files ($MATCH_HUMAN)"
echo "Percentage: $PCT%"
echo "Duration: ${DURATION}s"
[ "$PROBE_FAILURES" -gt 0 ] && echo "Probe failures: $PROBE_FAILURES files (could not read codec/resolution)"
echo

# Show matched files (top 20 largest)
if [ "$MATCH_COUNT" -gt 0 ]; then
    echo "Top matches (by $SORT_BY):"
    echo "---"
    eval "$SORT_CMD" "$TMP_MATCH" | head -20 | while IFS=$'\t' read -r name dir size_b res codec; do
        # Strip any of the base directories from the path
        rel_dir="$dir"
        for d in "${DIRECTORIES[@]}"; do
            rel_dir="${rel_dir#$d/}"
        done
        rel_dir=$(printf '%s' "$rel_dir" | sed 's/ {tmdb-[0-9]*}//g')
        size_h=$(format_size "$size_b")
        printf "  %-55s %6s  %8s  %s\n" "$rel_dir/$name" "$res" "$size_h" "$codec"
    done
    echo "---"

    if [ "$MATCH_COUNT" -gt 20 ]; then
        echo "  ... and $((MATCH_COUNT - 20)) more (see log)"
    fi
fi

# Full breakdown
echo
echo "Overall Breakdown:"
echo "  Codecs:"
for c in hevc h264 av1 mpeg4 mpeg2video vp9; do
    count=$(awk -F'\t' -v c="$c" '$5 == c' "$TMP_ALL" | wc -l)
    [ "$count" -gt 0 ] && echo "    $c: $count"
done
OTHER_COUNT=$(awk -F'\t' '$5 != "hevc" && $5 != "h264" && $5 != "av1" && $5 != "mpeg4" && $5 != "mpeg2video" && $5 != "vp9" && $5 != "N/A"' "$TMP_ALL" | wc -l)
NA_COUNT=$(awk -F'\t' '$5 == "N/A"' "$TMP_ALL" | wc -l)
[ "$OTHER_COUNT" -gt 0 ] && echo "    other: $OTHER_COUNT"
[ "$NA_COUNT" -gt 0 ] && echo "    N/A: $NA_COUNT"

echo "  Resolutions:"
RES_4K=$(awk -F'\t' '{r=$4; sub(/p$/,"",r)} r+0 >= 2160' "$TMP_ALL" | wc -l)
RES_FHD=$(awk -F'\t' '{r=$4; sub(/p$/,"",r)} r+0 >= 1080 && r+0 < 2160' "$TMP_ALL" | wc -l)
RES_HD=$(awk -F'\t' '{r=$4; sub(/p$/,"",r)} r+0 >= 720 && r+0 < 1080' "$TMP_ALL" | wc -l)
RES_SD=$(awk -F'\t' '{r=$4; sub(/p$/,"",r)} r+0 > 0 && r+0 < 720' "$TMP_ALL" | wc -l)
RES_NA=$(awk -F'\t' '$4 == "N/A"' "$TMP_ALL" | wc -l)
[ "$RES_4K" -gt 0 ] && echo "    4K (2160p+): $RES_4K"
[ "$RES_FHD" -gt 0 ] && echo "    Full HD (1080p+): $RES_FHD"
[ "$RES_HD" -gt 0 ] && echo "    HD (720-1079p): $RES_HD"
[ "$RES_SD" -gt 0 ] && echo "    SD (<720p): $RES_SD"
[ "$RES_NA" -gt 0 ] && echo "    Unknown: $RES_NA"

echo
echo "Log saved to: $LOG_FILE"

# --- Generate Markdown Report ---
{
    echo "# 🎬 Media Analysis"
    echo ""
    echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "---"
    echo ""
    echo "## Summary"
    echo ""
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Mode | $LABEL |"
    echo "| Directory | \`$DIR_LABEL\` |"
    echo "| Duration | ${DURATION}s |"
    echo "| Files scanned | $TOTAL_SCANNED |"
    echo "| Total size | $TOTAL_HUMAN |"
    echo "| Files matched | $MATCH_COUNT |"
    echo "| Matched size | $MATCH_HUMAN |"
    echo "| Match rate | $PCT% |"
    [ "$PROBE_FAILURES" -gt 0 ] && echo "| Probe failures | $PROBE_FAILURES |"
    echo ""
    echo "---"
    echo ""
    echo "## Codec Distribution"
    echo ""
    echo "| Codec | Count | % of Total |"
    echo "|-------|-------|-----------|"
    for c in hevc h264 av1 mpeg4 mpeg2video vp9; do
        count=$(awk -F'\t' -v c="$c" '$5 == c' "$TMP_ALL" | wc -l)
        if [ "$count" -gt 0 ]; then
            pct_int=$((count * 10000 / TOTAL_SCANNED))
            pct_fmt=$(printf "%d.%02d%%" $((pct_int / 100)) $((pct_int % 100)))
            echo "| $c | $count | $pct_fmt |"
        fi
    done
    other_count=$(awk -F'\t' '$5 != "hevc" && $5 != "h264" && $5 != "av1" && $5 != "mpeg4" && $5 != "mpeg2video" && $5 != "vp9" && $5 != "N/A"' "$TMP_ALL" | wc -l)
    na_count=$(awk -F'\t' '$5 == "N/A"' "$TMP_ALL" | wc -l)
    [ "$other_count" -gt 0 ] && echo "| Other | $other_count | $(printf "%d.%02d%%" $((other_count * 100 / TOTAL_SCANNED)) 0) |"
    [ "$na_count" -gt 0 ] && echo "| Unknown | $na_count | $(printf "%d.%02d%%" $((na_count * 100 / TOTAL_SCANNED)) 0) |"
    echo ""
    echo "---"
    echo ""
    echo "## Resolution Distribution"
    echo ""
    echo "| Resolution | Count | % of Total |"
    echo "|-----------|-------|-----------|"
    for label_res in "4K (2160p+):2160:99999" "Full HD (1080p):1080:2159" "HD (720p):720:1079" "SD (<720p):1:719"; do
        IFS=':' read -r rlabel rmin rmax <<< "$label_res"
        rcount=$(awk -F'\t' -v mn="$rmin" -v mx="$rmax" '{r=$4; sub(/p$/,"",r)} r+0 >= mn && r+0 <= mx' "$TMP_ALL" | wc -l)
        if [ "$rcount" -gt 0 ]; then
            rpct_int=$((rcount * 10000 / TOTAL_SCANNED))
            rpct_fmt=$(printf "%d.%02d%%" $((rpct_int / 100)) $((rpct_int % 100)))
            echo "| $rlabel | $rcount | $rpct_fmt |"
        fi
    done
    rna=$(awk -F'\t' '$4 == "N/A"' "$TMP_ALL" | wc -l)
    [ "$rna" -gt 0 ] && echo "| Unknown | $rna | $(printf "%d.%02d%%" $((rna * 100 / TOTAL_SCANNED)) 0) |"
    echo ""

    # Only list matched files when using a filter mode (not "all")
    if [ "$MODE" != "all" ] && [ "$MATCH_COUNT" -gt 0 ]; then
        echo "---"
        echo ""
        echo "## Matched Files ($MATCH_COUNT)"
        echo ""
        echo "| File | Resolution | Codec | Size |"
        echo "|------|------------|-------|------|"
        eval "$SORT_CMD" "$TMP_MATCH" | while IFS=$'\t' read -r name dir size_b res codec; do
            rel_dir="$dir"
            for d in "${DIRECTORIES[@]}"; do
                rel_dir="${rel_dir#$d/}"
            done
            rel_dir=$(printf '%s' "$rel_dir" | sed 's/ {tmdb-[0-9]*}//g')
            size_h=$(format_size "$size_b")
            printf "| %s/%s | %s | %s | %s |\n" "$rel_dir" "$name" "$res" "$codec" "$size_h"
        done
        echo ""
    fi
} > "$REPORT_FILE"

echo "Report saved to: $REPORT_FILE"

# Discord notification
if [ "$MATCH_COUNT" -gt 0 ]; then
    # Build top 10 matched files list (code block for proper formatting)
    TOP_MATCHES=$(eval "$SORT_CMD" "$TMP_MATCH" | head -10 | while IFS=$'\t' read -r name dir size_b res codec; do
        rel_dir="$dir"
        for d in "${DIRECTORIES[@]}"; do
            rel_dir="${rel_dir#$d/}"
        done
        rel_dir=$(printf '%s' "$rel_dir" | sed 's/ {tmdb-[0-9]*}//g')
        size_h=$(format_size "$size_b")
        printf "%s · %s · %s · %s\n" "$rel_dir/$name" "$codec" "$res" "$size_h"
    done)

    # Build codec breakdown
    CODEC_BREAKDOWN=""
    for c in hevc h264 av1 mpeg4 mpeg2video vp9; do
        count=$(awk -F'\t' -v c="$c" '$5 == c' "$TMP_ALL" | wc -l)
        [ "$count" -gt 0 ] && CODEC_BREAKDOWN+="$c: $count · "
    done
    CODEC_BREAKDOWN="${CODEC_BREAKDOWN% · }"

    # Build resolution breakdown (bucketed)
    RES_BREAKDOWN=""
    r4k=$(awk -F'\t' '{r=$4; sub(/p$/,"",r)} r+0 >= 2160' "$TMP_ALL" | wc -l)
    rfhd=$(awk -F'\t' '{r=$4; sub(/p$/,"",r)} r+0 >= 1080 && r+0 < 2160' "$TMP_ALL" | wc -l)
    rhd=$(awk -F'\t' '{r=$4; sub(/p$/,"",r)} r+0 >= 720 && r+0 < 1080' "$TMP_ALL" | wc -l)
    rsd=$(awk -F'\t' '{r=$4; sub(/p$/,"",r)} r+0 > 0 && r+0 < 720' "$TMP_ALL" | wc -l)
    [ "$r4k" -gt 0 ] && RES_BREAKDOWN+="4K: $r4k · "
    [ "$rfhd" -gt 0 ] && RES_BREAKDOWN+="FHD: $rfhd · "
    [ "$rhd" -gt 0 ] && RES_BREAKDOWN+="HD: $rhd · "
    [ "$rsd" -gt 0 ] && RES_BREAKDOWN+="SD: $rsd · "
    RES_BREAKDOWN="${RES_BREAKDOWN% · }"

    # Compose Discord message (using code blocks instead of tables)
    DISCORD_DESC="$EMOJI **$LABEL**

📂 \`$DIR_LABEL\`
⏱️ ${DURATION}s

**Summary**
\`\`\`
Scanned:  $TOTAL_SCANNED files ($TOTAL_HUMAN)
Matched:  $MATCH_COUNT files ($MATCH_HUMAN)
Match %:  $PCT%
\`\`\`
**Codecs:** $CODEC_BREAKDOWN
**Resolutions:** $RES_BREAKDOWN"

    [ "$PROBE_FAILURES" -gt 0 ] && DISCORD_DESC+="
⚠️ $PROBE_FAILURES files failed to probe"

    DISCORD_DESC+="

**Top Matches (by size):**
\`\`\`
$TOP_MATCHES
\`\`\`"

    send_discord "$DISCORD_NOTIFICATIONS" "$EMOJI Media Analyzer: $LABEL" "$DISCORD_DESC" "3066993"
else
    DISCORD_DESC="$EMOJI **$LABEL**

📂 \`$DIR_LABEL\`
⏱️ ${DURATION}s

Scanned **$TOTAL_SCANNED files** ($TOTAL_HUMAN) — no matches found for this filter."

    [ "$PROBE_FAILURES" -gt 0 ] && DISCORD_DESC+="
⚠️ $PROBE_FAILURES files failed to probe"

    send_discord "$DISCORD_NOTIFICATIONS" "$EMOJI Media Analyzer: $LABEL" "$DISCORD_DESC" "3066993"
fi
