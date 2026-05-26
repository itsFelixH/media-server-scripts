#!/bin/bash
# Kometa Docker Runner
# Interactive menu for running Kometa with different options

####### HELP #######
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat <<'HELP'
Kometa Docker Runner — Interactive menu for running Kometa.

Usage: runkometa.sh [-h|--help]

Provides a menu to run Kometa inside its Docker container with options:
  - Full run (all libraries)
  - Run both libraries (Movies + TV Shows in sequence)
  - Ignore schedules
  - Per-library runs (Movies / TV Shows)
  - Per-mode runs (metadata, collections, overlays)
  - Delete all collections
HELP
    exit 0
fi

CONTAINER="kometa"
MOVIE_LIBRARY="Movies"
SERIES_LIBRARY="TV Shows"

# Logging — only created when a command actually runs
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPTS_DIR/logs/runkometa"
mkdir -p "$LOG_DIR"
LOG_FILE=""

start_logging() {
    if [ -z "$LOG_FILE" ]; then
        LOG_FILE="$LOG_DIR/runkometa_$(date +%Y%m%d_%H%M%S).log"
        exec > >(tee -a "$LOG_FILE") 2>&1
    fi
}

####### STATUS #######
show_last_run() {
    # Find the most recent runkometa log
    local last_log
    last_log=$(ls -t "$LOG_DIR"/runkometa_*.log 2>/dev/null | head -1)

    if [ -n "$last_log" ]; then
        local log_date
        log_date=$(basename "$last_log" | sed 's/runkometa_//;s/\.log//')
        local formatted
        formatted=$(echo "$log_date" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')

        # Check if it ended with "Done."
        if grep -q "Done\." "$last_log" 2>/dev/null; then
            echo "  Last run: $formatted (success)"
        else
            echo "  Last run: $formatted (may have failed — no 'Done' found)"
        fi
    else
        echo "  Last run: never"
    fi

    # Also check Kometa's own log
    if [ -f "$HOME/kometa/config/logs/meta.log" ]; then
        local meta_age
        meta_age=$(stat -c%Y "$HOME/kometa/config/logs/meta.log" 2>/dev/null)
        local now
        now=$(date +%s)
        local hours_ago=$(( (now - meta_age) / 3600 ))
        echo "  Kometa last active: ${hours_ago}h ago"
    fi
    echo
}

####### KOMETA COMMANDS #######

run_kometa() {
    start_logging
    echo "[$(date +%H:%M:%S)] Running Kometa..."
    docker exec $CONTAINER python kometa.py -r
    echo "[$(date +%H:%M:%S)] Done."
}

run_all() {
    start_logging
    echo "[$(date +%H:%M:%S)] Running Kometa (ignore schedules)..."
    docker exec $CONTAINER python kometa.py -r -is
    echo "[$(date +%H:%M:%S)] Done."
}

run_both_libraries() {
    start_logging
    echo "[$(date +%H:%M:%S)] Running both libraries (Movies + TV Shows)..."
    echo "[$(date +%H:%M:%S)] Starting Movies..."
    docker exec $CONTAINER python kometa.py -r -rl "$MOVIE_LIBRARY" -is
    echo "[$(date +%H:%M:%S)] Starting TV Shows..."
    docker exec $CONTAINER python kometa.py -r -rl "$SERIES_LIBRARY" -is
    echo "[$(date +%H:%M:%S)] Done."
}

delete_collections() {
    start_logging
    echo "[$(date +%H:%M:%S)] Deleting all collections..."
    docker exec $CONTAINER python kometa.py -r -dc -co -is
    echo "[$(date +%H:%M:%S)] Done."
}

# TV Shows
run_series_complete() {
    start_logging
    echo "[$(date +%H:%M:%S)] Running TV Shows (full)..."
    docker exec $CONTAINER python kometa.py -r -rl "$SERIES_LIBRARY" -is
    echo "[$(date +%H:%M:%S)] Done."
}

run_series_metadata() {
    start_logging
    echo "[$(date +%H:%M:%S)] Running TV Shows (metadata)..."
    docker exec $CONTAINER python kometa.py -r -mo -rl "$SERIES_LIBRARY" -is
    echo "[$(date +%H:%M:%S)] Done."
}

run_series_collections() {
    start_logging
    echo "[$(date +%H:%M:%S)] Running TV Shows (collections)..."
    docker exec $CONTAINER python kometa.py -r -co -rl "$SERIES_LIBRARY" -is
    echo "[$(date +%H:%M:%S)] Done."
}

run_series_overlays() {
    start_logging
    echo "[$(date +%H:%M:%S)] Running TV Shows (overlays)..."
    docker exec $CONTAINER python kometa.py -r -ov -rl "$SERIES_LIBRARY" -is
    echo "[$(date +%H:%M:%S)] Done."
}

# Movies
run_movies_complete() {
    start_logging
    echo "[$(date +%H:%M:%S)] Running Movies (full)..."
    docker exec $CONTAINER python kometa.py -r -rl "$MOVIE_LIBRARY" -is
    echo "[$(date +%H:%M:%S)] Done."
}

run_movies_metadata() {
    start_logging
    echo "[$(date +%H:%M:%S)] Running Movies (metadata)..."
    docker exec $CONTAINER python kometa.py -r -mo -rl "$MOVIE_LIBRARY" -is
    echo "[$(date +%H:%M:%S)] Done."
}

run_movies_collections() {
    start_logging
    echo "[$(date +%H:%M:%S)] Running Movies (collections)..."
    docker exec $CONTAINER python kometa.py -r -co -rl "$MOVIE_LIBRARY" -is
    echo "[$(date +%H:%M:%S)] Done."
}

run_movies_overlays() {
    start_logging
    echo "[$(date +%H:%M:%S)] Running Movies (overlays)..."
    docker exec $CONTAINER python kometa.py -r -ov -rl "$MOVIE_LIBRARY" -is
    echo "[$(date +%H:%M:%S)] Done."
}

######## MENUS ########

show_series_menu() {
    clear
    echo "=== TV Shows ==="
    echo
    echo "1: Full Update"
    echo "2: Metadata Only"
    echo "3: Collections Only"
    echo "4: Overlays Only"
    echo
    echo "B: Back"
    echo "Q: Exit"
    echo

    read -p "Select: " selection

    case "$selection" in
        1) run_series_complete ;;
        2) run_series_metadata ;;
        3) run_series_collections ;;
        4) run_series_overlays ;;
        b|B) show_main_menu ;;
        q|Q) exit ;;
        *) echo "Invalid selection." && show_series_menu ;;
    esac
}

show_movie_menu() {
    clear
    echo "=== Movies ==="
    echo
    echo "1: Full Update"
    echo "2: Metadata Only"
    echo "3: Collections Only"
    echo "4: Overlays Only"
    echo
    echo "B: Back"
    echo "Q: Exit"
    echo

    read -p "Select: " selection

    case "$selection" in
        1) run_movies_complete ;;
        2) run_movies_metadata ;;
        3) run_movies_collections ;;
        4) run_movies_overlays ;;
        b|B) show_main_menu ;;
        q|Q) exit ;;
        *) echo "Invalid selection." && show_movie_menu ;;
    esac
}

show_main_menu() {
    clear
    echo "=== Kometa Runner ==="
    echo
    show_last_run
    echo "1: Run Kometa"
    echo "2: Run Kometa (ignore schedules)"
    echo "3: Run Both Libraries (Movies + TV)"
    echo
    echo "4: Movies submenu"
    echo "5: TV Shows submenu"
    echo
    echo "6: Delete ALL Collections"
    echo
    echo "Q: Exit"
    echo

    read -p "Select: " selection

    case "$selection" in
        1) run_kometa ;;
        2) run_all ;;
        3) run_both_libraries ;;
        4) show_movie_menu ;;
        5) show_series_menu ;;
        6) delete_collections ;;
        q|Q) exit ;;
        *) echo "Invalid selection." && show_main_menu ;;
    esac
}

######## MAIN ########

show_main_menu
