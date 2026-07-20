#!/bin/bash
# Storage Report
# Scans media directories and generates a detailed storage report.
# Reports folder sizes, resolution, codec, and file counts.
# Generates a JSON report, diffs against previous run, posts summary to Discord.
#
# Usage:
#   ./storage-report.sh [options] [directory]
#
# Options:
#   -h, --help        Show this help message
#   -q, --quiet       Suppress terminal output (log only)
#   --no-discord      Skip Discord notification
#
# Examples:
#   ./storage-report.sh
#   ./storage-report.sh "/mnt/Media/Movies"
#   ./storage-report.sh --quiet "/mnt/Media/TV Shows"

####### HELP #######
show_help() {
    cat <<'HELP'
Storage Report — Generates a detailed storage usage report.

Usage: storage-report.sh [options] [directory]

Scans media directories and reports:
  - Folder sizes with resolution and codec info
  - File counts per folder
  - Top 10 largest items
  - Total storage usage
  - Comparison with previous run (growth tracking)

Options:
  -h, --help        Show this help message
  -q, --quiet       Suppress terminal output (log only)
  --no-discord      Skip Discord notification

Defaults to /mnt/Media/TV Shows if no directory is specified.
Auto-detects TV (show/season) vs Movies (flat) structure.

Output: ~/kometa/scripts/reports/storage-report.json (overwritten each run)
Previous snapshot saved as storage-report.prev.json for diffing.
HELP
}

####### ARGUMENT PARSING #######
QUIET=false
NO_DISCORD=false
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        -q|--quiet) QUIET=true; shift ;;
        --no-discord) NO_DISCORD=true; shift ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

####### CONFIGURATION #######
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

LOG_FILE="$LOG_DIR/storage-report/storage-report_$(date +%Y%m%d_%H%M%S).log"
REPORT_FILE="$REPORT_DIR/storage-report.json"
REPORT_PREV="$REPORT_DIR/storage-report.prev.json"
mkdir -p "$LOG_DIR/storage-report"
BASE_PATH="${POSITIONAL[0]:-}"

# If no directory specified, scan both libraries sequentially
if [ -z "$BASE_PATH" ]; then
    echo "No directory specified — scanning both libraries..."
    SELF_ARGS=""
    [ "$QUIET" = true ] && SELF_ARGS="$SELF_ARGS --quiet"
    [ "$NO_DISCORD" = true ] && SELF_ARGS="$SELF_ARGS --no-discord"
    # Run self for TV Shows
    bash "$0" $SELF_ARGS "$TV_DIR"
    [ -f "$REPORT_FILE" ] && mv "$REPORT_FILE" "$REPORT_DIR/storage-report-tv.json"
    # Run self for Movies
    bash "$0" $SELF_ARGS "$MOVIES_DIR"
    [ -f "$REPORT_FILE" ] && mv "$REPORT_FILE" "$REPORT_DIR/storage-report-movies.json"
    # Combine into one report with root totals
    jq -n \
        --slurpfile tv "$REPORT_DIR/storage-report-tv.json" \
        --slurpfile movies "$REPORT_DIR/storage-report-movies.json" \
        '
        def format_bytes:
            if . >= 1099511627776 then "\(. / 1099511627776 * 100 | floor / 100) TB"
            elif . >= 1073741824 then "\(. / 1073741824 * 100 | floor / 100) GB"
            elif . >= 1048576 then "\(. / 1048576 | floor) MB"
            else "\(. / 1024 | floor) KB"
            end;
        ($tv[0].data.libraries[0]) as $t |
        ($movies[0].data.libraries[0]) as $m |
        ($t.summary.size_bytes + $m.summary.size_bytes) as $total_bytes |
        ($tv[0].summary.total_files + $movies[0].summary.total_files) as $total_files |
        ($tv[0].summary.folders_scanned + $movies[0].summary.folders_scanned) as $total_folders |
        ($tv[0].duration_seconds + $movies[0].duration_seconds) as $total_duration |
        ($t.summary.size_bytes / $total_bytes * 1000 | floor / 10) as $tv_pct |
        ($m.summary.size_bytes / $total_bytes * 1000 | floor / 10) as $mov_pct |
        {
            version: 1,
            type: "storage-report",
            generated: (now | strftime("%Y-%m-%dT%H:%M:%S+02:00")),
            generated_by: "storage-report.sh",
            duration_seconds: $total_duration,
            health: {status: "ok", message: "Scan completed successfully"},
            summary: {
                total_size_bytes: $total_bytes,
                total_size: ($total_bytes | format_bytes),
                total_files: $total_files,
                folders_scanned: $total_folders
            },
            data: {
                libraries: [
                    ($t + {pct_of_total: $tv_pct}),
                    ($m + {pct_of_total: $mov_pct})
                ]
            },
            comparison: null
        }' > "$REPORT_FILE"
    rm -f "$REPORT_DIR/storage-report-tv.json" "$REPORT_DIR/storage-report-movies.json"
    exit 0
fi

# Redirect output
if [ "$QUIET" = true ]; then
    exec > "$LOG_FILE" 2>&1
else
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

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
SCRIPT_NAME="storage-report.sh"

format_size() {
    local bytes=$1
    if [ "$bytes" -ge 1099511627776 ]; then
        local tb_int=$((bytes / 1099511627776))
        local remainder=$(( (bytes % 1099511627776) * 100 / 1099511627776 ))
        printf "%d.%02d TB" "$tb_int" "$remainder"
    elif [ "$bytes" -ge 1073741824 ]; then
        local gb_int=$((bytes / 1073741824))
        local remainder=$(( (bytes % 1073741824) * 100 / 1073741824 ))
        printf "%d.%02d GB" "$gb_int" "$remainder"
    elif [ "$bytes" -ge 1048576 ]; then
        local mb_int=$((bytes / 1048576))
        printf "%d MB" "$mb_int"
    else
        printf "%d KB" "$((bytes / 1024))"
    fi
}

get_media_info() {
    local dir="$1"
    local sample_file
    sample_file=$(find "$dir" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" \) 2>/dev/null | head -n 1)
    if [ -z "$sample_file" ]; then
        sample_file=$(find "$dir" -maxdepth 2 -type f \( -iname "*.mkv" -o -iname "*.mp4" \) 2>/dev/null | head -n 1)
    fi

    if [ -n "$sample_file" ]; then
        local probe_output
        probe_output=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name,height \
            -of "csv=s=,:p=0" "$sample_file" 2>/dev/null)

        local codec height
        codec=$(printf '%s' "$probe_output" | cut -d',' -f1 | tr -d '[:space:]')
        height=$(printf '%s' "$probe_output" | cut -d',' -f2 | tr -d '[:space:]')

        [ -z "$codec" ] && codec="N/A"
        [ -n "$height" ] && height="${height}p" || height="N/A"

        printf "%s\t%s" "$height" "$codec"
    else
        printf "N/A\tN/A"
    fi
}

scan_folder() {
    local dir="$1"
    local display_name="$2"

    # Strip {tmdb-XXXXX} suffixes
    local clean_name
    clean_name=$(printf '%s' "$display_name" | sed 's/ {tmdb-[0-9]*}//g')

    local size_bytes
    size_bytes=$(du -sb "$dir" 2>/dev/null | cut -f1)
    size_bytes=${size_bytes:-0}

    local file_count
    file_count=$(find "$dir" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" \) 2>/dev/null | wc -l)

    local media_info resolution codec
    media_info=$(get_media_info "$dir")
    resolution=$(printf '%s' "$media_info" | cut -f1)
    codec=$(printf '%s' "$media_info" | cut -f2)

    FOLDER_COUNT=$((FOLDER_COUNT + 1))
    TOTAL_BYTES=$((TOTAL_BYTES + size_bytes))
    TOTAL_FILES=$((TOTAL_FILES + file_count))

    printf "%s\t%s\t%s\t%s\t%s\n" "$clean_name" "$resolution" "$codec" "$size_bytes" "$file_count" >> "$TMP_FILE"
}

####### MAIN #######
START_TIME=$(date +%s)
echo "=== Storage Report ==="
echo "Directory: $BASE_PATH"
echo

if [ ! -d "$BASE_PATH" ]; then
    echo "ERROR: Directory not found: $BASE_PATH"
    discord_notify "error" "❌ Storage Report Failed" "Directory not found: \`$BASE_PATH\`

See \`reports/storage-report.json\` for last successful run."
    exit 1
fi

TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

FOLDER_COUNT=0
TOTAL_BYTES=0
TOTAL_FILES=0

# Detect structure: TV (show/season) vs Movies (flat)
HAS_SUBFOLDERS=false
for folder in "$BASE_PATH"/*/; do
    [ -d "$folder" ] || continue
    for subfolder in "$folder"*/; do
        if [ -d "$subfolder" ]; then
            HAS_SUBFOLDERS=true
            break 2
        fi
    done
done

if [ "$HAS_SUBFOLDERS" = true ]; then
    SCAN_MODE="TV Shows"
    echo "Mode: TV (show/season structure)"

    TOTAL_FOLDERS=0
    for folder in "$BASE_PATH"/*/; do
        [ -d "$folder" ] || continue
        has_subs=false
        for subfolder in "$folder"*/; do
            [ -d "$subfolder" ] || continue
            has_subs=true
            TOTAL_FOLDERS=$((TOTAL_FOLDERS + 1))
        done
        [ "$has_subs" = false ] && TOTAL_FOLDERS=$((TOTAL_FOLDERS + 1))
    done
    echo "Found $TOTAL_FOLDERS folders to scan."
    echo

    for folder in "$BASE_PATH"/*/; do
        [ -d "$folder" ] || continue
        folder_name="${folder%/}"
        folder_name="${folder_name##*/}"

        has_subs=false
        for subfolder in "$folder"*/; do
            [ -d "$subfolder" ] || continue
            has_subs=true
            subfolder_name="${subfolder%/}"
            subfolder_name="${subfolder_name##*/}"
            scan_folder "$subfolder" "$folder_name/$subfolder_name"
            if [ $((FOLDER_COUNT % 10)) -eq 0 ]; then
                printf "\r  Progress: %d/%d (%d%%)" "$FOLDER_COUNT" "$TOTAL_FOLDERS" "$((FOLDER_COUNT * 100 / TOTAL_FOLDERS))"
            fi
        done

        if [ "$has_subs" = false ]; then
            scan_folder "$folder" "$folder_name"
        fi
    done
    printf "\r  Progress: %d/%d (100%%)\n" "$TOTAL_FOLDERS" "$TOTAL_FOLDERS"
else
    SCAN_MODE="Movies"
    echo "Mode: Movies (flat structure)"

    TOTAL_FOLDERS=0
    for folder in "$BASE_PATH"/*/; do
        [ -d "$folder" ] || continue
        TOTAL_FOLDERS=$((TOTAL_FOLDERS + 1))
    done
    echo "Found $TOTAL_FOLDERS folders to scan."
    echo

    for folder in "$BASE_PATH"/*/; do
        [ -d "$folder" ] || continue
        folder_name="${folder%/}"
        folder_name="${folder_name##*/}"
        scan_folder "$folder" "$folder_name"
        if [ $((FOLDER_COUNT % 10)) -eq 0 ]; then
            printf "\r  Progress: %d/%d (%d%%)" "$FOLDER_COUNT" "$TOTAL_FOLDERS" "$((FOLDER_COUNT * 100 / TOTAL_FOLDERS))"
        fi
    done
    printf "\r  Progress: %d/%d (100%%)\n" "$TOTAL_FOLDERS" "$TOTAL_FOLDERS"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
TOTAL_HUMAN=$(format_size "$TOTAL_BYTES")

echo
echo "Scan complete."
echo

# Resolution breakdown
declare -A RES_COUNTS
declare -A RES_SIZES
while IFS=$'\t' read -r name resolution codec size_bytes file_count; do
    bucket="Other"
    case "$resolution" in
        2160p) bucket="4K" ;;
        1080p) bucket="FHD" ;;
        720p)  bucket="HD" ;;
        480p|360p|240p) bucket="SD" ;;
        N/A)   bucket="Unknown" ;;
        *)
            height="${resolution%p}"
            if [ "$height" -ge 2160 ] 2>/dev/null; then bucket="4K"
            elif [ "$height" -ge 1080 ] 2>/dev/null; then bucket="FHD"
            elif [ "$height" -ge 720 ] 2>/dev/null; then bucket="HD"
            elif [ "$height" -ge 1 ] 2>/dev/null; then bucket="SD"
            fi
            ;;
    esac
    RES_COUNTS[$bucket]=$(( ${RES_COUNTS[$bucket]:-0} + 1 ))
    RES_SIZES[$bucket]=$(( ${RES_SIZES[$bucket]:-0} + size_bytes ))
done < "$TMP_FILE"

# Codec breakdown
declare -A CODEC_COUNTS
declare -A CODEC_SIZES
while IFS=$'\t' read -r name resolution codec size_bytes file_count; do
    codec_upper=$(echo "$codec" | tr '[:lower:]' '[:upper:]')
    case "$codec_upper" in
        HEVC|H265) codec_upper="HEVC" ;;
        H264|AVC) codec_upper="H264" ;;
        AV1) codec_upper="AV1" ;;
        N/A) codec_upper="Unknown" ;;
    esac
    CODEC_COUNTS[$codec_upper]=$(( ${CODEC_COUNTS[$codec_upper]:-0} + 1 ))
    CODEC_SIZES[$codec_upper]=$(( ${CODEC_SIZES[$codec_upper]:-0} + size_bytes ))
done < "$TMP_FILE"

# Print summary to terminal
echo "=== Storage Report Summary ==="
echo "Directory: $BASE_PATH"
echo "Mode: $SCAN_MODE"
echo "Folders scanned: $FOLDER_COUNT"
echo "Total files: $TOTAL_FILES"
echo "Total size: $TOTAL_HUMAN"
echo "Duration: ${DURATION}s"
echo

echo "Resolution Breakdown:"
for bucket in "4K" "FHD" "HD" "SD" "Unknown" "Other"; do
    count=${RES_COUNTS[$bucket]:-0}
    [ "$count" -eq 0 ] && continue
    size=$(format_size "${RES_SIZES[$bucket]:-0}")
    printf "  %-8s %4d folders  %s\n" "$bucket" "$count" "$size"
done
echo

echo "Codec Breakdown:"
for codec in "HEVC" "H264" "AV1" "Unknown"; do
    count=${CODEC_COUNTS[$codec]:-0}
    [ "$count" -eq 0 ] && continue
    size=$(format_size "${CODEC_SIZES[$codec]:-0}")
    printf "  %-8s %4d folders  %s\n" "$codec" "$count" "$size"
done
for codec in "${!CODEC_COUNTS[@]}"; do
    case "$codec" in HEVC|H264|AV1|Unknown) continue ;; esac
    count=${CODEC_COUNTS[$codec]}
    size=$(format_size "${CODEC_SIZES[$codec]:-0}")
    printf "  %-8s %4d folders  %s\n" "$codec" "$count" "$size"
done
echo

echo "Log saved to: $LOG_FILE"
echo "Report saved to: $REPORT_FILE"

# --- Generate JSON Report ---

# Backup previous report for diffing
if [ -f "$REPORT_FILE" ]; then
    cp "$REPORT_FILE" "$REPORT_PREV"
fi

# Build resolution breakdown JSON (with human-readable sizes)
RES_JSON="[]"
for bucket in "4K" "FHD" "HD" "SD" "Unknown" "Other"; do
    count=${RES_COUNTS[$bucket]:-0}
    [ "$count" -eq 0 ] && continue
    size_bytes=${RES_SIZES[$bucket]:-0}
    size_human=$(format_size "$size_bytes")
    RES_JSON=$(echo "$RES_JSON" | jq --arg lbl "$bucket" --argjson folders "$count" --argjson sb "$size_bytes" --arg sz "$size_human" \
        '. + [{"label": $lbl, "folders": $folders, "size_bytes": $sb, "size": $sz}]')
done

# Build codec breakdown JSON (with human-readable sizes)
CODEC_JSON="[]"
for codec in "HEVC" "H264" "AV1" "Unknown"; do
    count=${CODEC_COUNTS[$codec]:-0}
    [ "$count" -eq 0 ] && continue
    size_bytes=${CODEC_SIZES[$codec]:-0}
    size_human=$(format_size "$size_bytes")
    CODEC_JSON=$(echo "$CODEC_JSON" | jq --arg lbl "$codec" --argjson folders "$count" --argjson sb "$size_bytes" --arg sz "$size_human" \
        '. + [{"label": $lbl, "folders": $folders, "size_bytes": $sb, "size": $sz}]')
done
for codec in "${!CODEC_COUNTS[@]}"; do
    case "$codec" in HEVC|H264|AV1|Unknown) continue ;; esac
    count=${CODEC_COUNTS[$codec]}
    size_bytes=${CODEC_SIZES[$codec]:-0}
    size_human=$(format_size "$size_bytes")
    CODEC_JSON=$(echo "$CODEC_JSON" | jq --arg lbl "$codec" --argjson folders "$count" --argjson sb "$size_bytes" --arg sz "$size_human" \
        '. + [{"label": $lbl, "folders": $folders, "size_bytes": $sb, "size": $sz}]')
done

# Resolution bucket helper for items
resolve_bucket() {
    local resolution="$1"
    local height="${resolution%p}"
    case "$resolution" in
        2160p) echo "4K" ;;
        1080p) echo "FHD" ;;
        720p)  echo "HD" ;;
        480p|360p|240p) echo "SD" ;;
        N/A)   echo "Unknown" ;;
        *)
            if [ "$height" -ge 2160 ] 2>/dev/null; then echo "4K"
            elif [ "$height" -ge 1080 ] 2>/dev/null; then echo "FHD"
            elif [ "$height" -ge 720 ] 2>/dev/null; then echo "HD"
            elif [ "$height" -ge 1 ] 2>/dev/null; then echo "SD"
            else echo "Unknown"
            fi
            ;;
    esac
}

# Build items array from TMP_FILE (with resolution_bucket and human size)
ITEMS_JSON=$(sort -t$'\t' -k1 "$TMP_FILE" | while IFS=$'\t' read -r name resolution codec size_bytes file_count; do
    bucket=$(resolve_bucket "$resolution")
    size_human=$(format_size "$size_bytes")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$resolution" "$bucket" "$codec" "$size_bytes" "$size_human" "$file_count"
done | jq -R -s '
    split("\n") | map(select(length > 0)) | map(
        split("\t") | {
            name: .[0],
            resolution: .[1],
            resolution_bucket: .[2],
            codec: .[3],
            size_bytes: (.[4] | tonumber),
            size: .[5],
            files: (.[6] | tonumber)
        }
    )')

# Build top_by_size (top 10 largest items)
TOP_JSON=$(echo "$ITEMS_JSON" | jq '[sort_by(-.size_bytes) | limit(10; .[])]')

# Build comparison JSON
COMPARISON_JSON="null"
if [ -f "$REPORT_PREV" ]; then
    PREV_FOLDERS=$(jq -r '.summary.folders_scanned // 0' "$REPORT_PREV" 2>/dev/null || echo "0")
    PREV_FILES=$(jq -r '.summary.total_files // 0' "$REPORT_PREV" 2>/dev/null || echo "0")
    PREV_SIZE=$(jq -r '.summary.total_size_bytes // 0' "$REPORT_PREV" 2>/dev/null || echo "0")

    [ -z "$PREV_FOLDERS" ] || [ "$PREV_FOLDERS" = "null" ] && PREV_FOLDERS=0
    [ -z "$PREV_FILES" ] || [ "$PREV_FILES" = "null" ] && PREV_FILES=0
    [ -z "$PREV_SIZE" ] || [ "$PREV_SIZE" = "null" ] && PREV_SIZE=0

    FOLDERS_CHANGE=$((FOLDER_COUNT - PREV_FOLDERS))
    FILES_CHANGE=$((TOTAL_FILES - PREV_FILES))
    SIZE_CHANGE=$((TOTAL_BYTES - PREV_SIZE))

    COMPARISON_JSON=$(jq -n \
        --argjson prev_folders "$PREV_FOLDERS" \
        --argjson prev_files "$PREV_FILES" \
        --argjson prev_size_bytes "$PREV_SIZE" \
        --argjson folders_change "$FOLDERS_CHANGE" \
        --argjson files_change "$FILES_CHANGE" \
        --argjson size_change "$SIZE_CHANGE" \
        --arg size_change_human "$(format_size "${SIZE_CHANGE#-}")" \
        '{
            prev_folders: $prev_folders,
            prev_files: $prev_files,
            prev_size_bytes: $prev_size_bytes,
            folders_change: $folders_change,
            files_change: $files_change,
            size_change: $size_change,
            size_change_human: $size_change_human
        }')
fi

# Write final JSON report
jq -n \
    --argjson version 1 \
    --arg type "storage-report" \
    --arg generated "$(date -Iseconds)" \
    --arg generated_by "$SCRIPT_NAME" \
    --argjson duration "$DURATION" \
    --arg directory "$(basename "$BASE_PATH")" \
    --arg mode "$SCAN_MODE" \
    --argjson folders_scanned "$FOLDER_COUNT" \
    --argjson total_files "$TOTAL_FILES" \
    --argjson total_size_bytes "$TOTAL_BYTES" \
    --arg total_size "$(format_size "$TOTAL_BYTES")" \
    --argjson resolution "$RES_JSON" \
    --argjson codec "$CODEC_JSON" \
    --argjson items "$ITEMS_JSON" \
    --argjson top_by_size "$TOP_JSON" \
    --argjson comparison "$COMPARISON_JSON" \
    '{
        version: $version,
        type: $type,
        generated: $generated,
        generated_by: $generated_by,
        duration_seconds: $duration,
        health: {status: "ok", message: "Scan completed successfully"},
        summary: {
            total_size_bytes: $total_size_bytes,
            total_size: $total_size,
            total_files: $total_files,
            folders_scanned: $folders_scanned
        },
        data: {
            libraries: [{
                directory: $directory,
                mode: $mode,
                summary: {
                    size_bytes: $total_size_bytes,
                    size: $total_size,
                    files: $total_files,
                    folders: $folders_scanned
                },
                breakdowns: {
                    resolution: $resolution,
                    codec: $codec
                },
                top_by_size: $top_by_size,
                items: $items
            }]
        },
        comparison: $comparison
    }' > "$REPORT_FILE"

# --- Discord Notification ---
# Build resolution summary for Discord
RES_SUMMARY=""
for bucket in "4K" "FHD" "HD" "SD"; do
    count=${RES_COUNTS[$bucket]:-0}
    [ "$count" -eq 0 ] && continue
    RES_SUMMARY+="$bucket: $count  "
done

CODEC_SUMMARY=""
for c in "HEVC" "H264" "AV1"; do
    count=${CODEC_COUNTS[$c]:-0}
    [ "$count" -gt 0 ] && CODEC_SUMMARY+="$c: $count  "
done

DISCORD_DESC="**$TOTAL_FILES** files · **$TOTAL_HUMAN**
📐 $RES_SUMMARY
🎞️ $CODEC_SUMMARY"

# Add comparison info if available
if [ -f "$REPORT_PREV" ] && [ "${FILES_CHANGE:-0}" -ne 0 ] 2>/dev/null; then
    if [ "$FILES_CHANGE" -gt 0 ]; then
        DISCORD_DESC+="
📈 +$FILES_CHANGE files since last run"
    else
        DISCORD_DESC+="
📉 -${FILES_CHANGE#-} files since last run"
    fi
fi

discord_notify "success" "📊 Storage Report" "$DISCORD_DESC"
