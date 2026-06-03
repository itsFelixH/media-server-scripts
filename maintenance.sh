#!/bin/bash
# Media Server Maintenance Script

####### HELP #######
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat <<'HELP'
Media Server Maintenance — Interactive maintenance menu for the Plex stack.

Usage: maintenance.sh [-h|--help] [--scheduled] [--no-discord]

Options:
  -h, --help        Show this help message
  --scheduled       Run unattended scheduled maintenance (system updates,
                    Docker updates, config validation, token check, disk cleanup)
  --no-discord      Skip Discord notifications

Interactive menu includes: system updates, Docker management, service restarts,
disk maintenance, health checks, network diagnostics, config validation.
HELP
    exit 0
fi

NO_DISCORD=false
for arg in "$@"; do
    [[ "$arg" == "--no-discord" ]] && NO_DISCORD=true
done

####### CONFIGURATION #######
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

LOG_FILE="${LOG_DIR}/maintenance/maintenance_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR/maintenance"

# Redirect all output to log file and terminal
exec > >(tee -a "$LOG_FILE") 2>&1

# Alias for Kometa config path (used by validate_configs and disk_maintenance)
BASE_PATH="$KOMETA_CONFIG"


######## DEPENDENCY CHECK ########

MISSING_DEPS=()

# Required - auto-install
if ! command -v jq &>/dev/null; then
    echo "Installing jq..."
    sudo apt-get install -y jq >/dev/null 2>&1
fi

if ! command -v bc &>/dev/null; then
    echo "Installing bc..."
    sudo apt-get install -y bc >/dev/null 2>&1
fi

# Optional - warn if missing
command -v curl &>/dev/null || MISSING_DEPS+=("curl (notifications, network checks)")
command -v nslookup &>/dev/null || MISSING_DEPS+=("nslookup (DNS check) - install dnsutils")
command -v python3 &>/dev/null || MISSING_DEPS+=("python3 (config validation)")
if command -v python3 &>/dev/null && ! python3 -c "import yaml" 2>/dev/null; then
    MISSING_DEPS+=("python3-yaml (config validation) - install python3-yaml")
fi
command -v lsb_release &>/dev/null || MISSING_DEPS+=("lsb_release (system info) - install lsb-release")

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "WARNING: Optional dependencies missing (some features may not work):"
    for dep in "${MISSING_DEPS[@]}"; do
        echo "  - $dep"
    done
    echo
fi

######## FUNCTIONS ########

# Initialize logging
init_logging() {
    echo "===== Maintenance Started: $(date) ====="
    echo "System: $(lsb_release -d | cut -f2-)"
    echo "Kernel: $(uname -r)"
    echo "======================================="
}

SCRIPT_NAME="maintenance.sh"

# Local notification wrapper — checks NOTIFY preferences, adds emoji/hostname prefix
notify() {
    local message="$1"
    local status="$2"

    [ "$NO_DISCORD" = true ] && return
    
    local webhook=""
    if [[ "$status" == "error" ]]; then
        webhook="$DISCORD_ALERTS"
    else
        webhook="$DISCORD_NOTIFICATIONS"
    fi
    
    # Skip if webhook is empty or placeholder
    [[ -z "$webhook" || "$webhook" == *"your_webhook_here"* ]] && return
    
    if [[ "$status" == "error" && "$NOTIFY_ON_FAILURE" == true ]] || [[ "$status" == "success" && "$NOTIFY_ON_SUCCESS" == true ]]; then
        local emoji="✅"
        [[ "$status" == "error" ]] && emoji="❌"
        local msg="$emoji [$SERVER_HOSTNAME] $message"
        discord_message "$webhook" "$msg"
    fi
}

# System maintenance
system_maintenance() {
    echo "---- SYSTEM MAINTENANCE ----"
    local success=true
    
    # Update package lists
    if ! sudo apt-get update -y; then
        echo "ERROR: Failed to update package lists"
        notify "System maintenance failed at package update" "error"
        success=false
    fi
    
    # Upgrade packages
    if $success && ! sudo apt-get upgrade -y; then
        echo "ERROR: Failed to upgrade packages"
        notify "System maintenance failed at package upgrade" "error"
        success=false
    fi
    
    # Cleanup
    if $success; then
        sudo apt-get autoremove -y
        sudo apt-get autoclean -y
        sudo journalctl --vacuum-time=3d
        echo "System maintenance completed"
        notify "System maintenance completed successfully" "success"
    fi
}

# Update media tools
update_media_tools() {
    echo "---- MEDIA TOOLS UPDATE ----"
    
    # Update PlexTraktSync
    if command -v plextraktsync &>/dev/null; then
        if plextraktsync self-update; then
            echo "[✓] PlexTraktSync updated successfully"
        else
            echo "ERROR: Failed to update PlexTraktSync"
            notify "PlexTraktSync update failed" "error"
        fi
    else
        echo "WARNING: plextraktsync not found in PATH"
    fi
}

# Update Docker containers
# Check for available Docker image updates (without pulling)
check_docker_updates() {
    echo "---- DOCKER IMAGE UPDATE CHECK ----"
    local updates_available=0

    for container in "${DOCKER_CONTAINERS[@]}"; do
        local compose_dir="$HOME/docker/$container"
        if [ ! -f "$compose_dir/docker-compose.yml" ]; then
            continue
        fi

        # Get the image name from the compose file
        local image
        image=$(grep -oP '(?<=image: ).*' "$compose_dir/docker-compose.yml" 2>/dev/null | tr -d ' "'"'"'')
        [ -z "$image" ] && continue

        # Get local digest
        local local_digest
        local_digest=$(docker image inspect "$image" --format='{{index .RepoDigests 0}}' 2>/dev/null | cut -d'@' -f2)

        # Get remote digest (without pulling the image)
        local remote_digest
        remote_digest=$(docker manifest inspect "$image" 2>/dev/null | jq -r '.config.digest // .manifests[0].digest // empty' 2>/dev/null)

        if [ -z "$local_digest" ] || [ -z "$remote_digest" ]; then
            echo "  [?] $container ($image) — could not check"
        elif [ "$local_digest" != "$remote_digest" ]; then
            echo "  [↑] $container ($image) — update available"
            ((updates_available++))
        else
            echo "  [✓] $container ($image) — up to date"
        fi
    done

    echo
    if [ "$updates_available" -gt 0 ]; then
        echo "$updates_available update(s) available. Run 'Update Docker Containers' to apply."
    else
        echo "All containers are up to date."
    fi
}

update_containers() {
    echo "---- DOCKER CONTAINER UPDATES ----"
    local updated=0
    local failed=0

    for container in "${DOCKER_CONTAINERS[@]}"; do
        local compose_dir="$HOME/docker/$container"
        if [ -f "$compose_dir/docker-compose.yml" ]; then
            echo "Updating $container..."
            if cd "$compose_dir" && docker compose pull 2>&1 | grep -q "Downloaded newer image\|Pull complete"; then
                docker compose up -d
                echo "[✓] $container updated and restarted"
                ((updated++))
            else
                docker compose up -d >/dev/null 2>&1
                echo "[=] $container already up to date"
            fi
        else
            echo "[✗] $container compose file not found at $compose_dir"
            ((failed++))
        fi
    done

    echo
    echo "Summary: $updated updated, $failed failed, $((${#DOCKER_CONTAINERS[@]} - updated - failed)) already current"
    if [ "$updated" -gt 0 ]; then
        notify "Updated $updated Docker container(s)" "success"
    fi
    if [ "$failed" -gt 0 ]; then
        notify "Failed to update $failed container(s)" "error"
    fi
}

# Service management
manage_services() {
    echo "---- SERVICE MANAGEMENT ----"
    
    # Restart Plex Media Server
    sudo systemctl restart "$PLEX_SERVICE"
    echo "Plex Media Server restarted"
    
    # Restart *Arr services
    for service in "${ARR_SERVICES[@]}"; do
        if systemctl is-enabled --quiet "$service" 2>/dev/null; then
            sudo systemctl restart "$service"
            echo "$service restarted"
        fi
    done
    
    # Verify service status
    echo -e "\nService Status:"
    for service in "$PLEX_SERVICE" "${ARR_SERVICES[@]}"; do
        if systemctl is-active --quiet "$service"; then
            echo "[✓] $service is running"
        else
            echo "[✗] $service is NOT running"
            notify "Service $service is not running" "error"
        fi
    done
    
    # Restart Docker containers
    echo -e "\nDocker Containers:"
    for container in "${DOCKER_CONTAINERS[@]}"; do
        if [ -n "$(docker ps -q -f "name=^${container}$" 2>/dev/null)" ]; then
            docker restart "$container" >/dev/null 2>&1
            echo "[✓] $container restarted"
        else
            echo "[✗] $container not running"
            notify "Docker container $container not running" "error"
        fi
    done
}

# Disk space management
disk_maintenance() {
    echo "---- DISK MAINTENANCE ----"
    
    # Cleanup old script logs across all subdirectories (older than retention period)
    local deleted=$(find "$LOG_DIR" -type f -name "*.log" -mtime +$RETENTION_LOGS_DAYS -delete -print 2>/dev/null | wc -l)
    echo "[✓] Cleaned $deleted old script log file(s)"

    # Cleanup old PlexTraktSync daily logs (shorter retention)
    local pts_deleted=$(find "$LOG_DIR/plextraktsync" -type f -name "*.log" -mtime +$RETENTION_PTS_DAYS -delete -print 2>/dev/null | wc -l)
    echo "[✓] Cleaned $pts_deleted old PlexTraktSync log file(s)"

    # Cleanup old Kometa logs
    find "$BASE_PATH/logs" -type f -name "*.log" -mtime +$RETENTION_LOGS_DAYS -delete 2>/dev/null
    echo "[✓] Cleaned old Kometa log files"

    # Cleanup old UMTK logs
    local umtk_deleted=$(find "$UMTK_LOGS_DIR" -type f -name "UMTK_*.log" -mtime +$RETENTION_UMTK_LOGS_DAYS -delete -print 2>/dev/null | wc -l)
    echo "[✓] Cleaned $umtk_deleted old UMTK log file(s)"
    
    # Show disk usage
    echo -e "\nDisk Usage:"
    df -h / | awk 'NR>1 {print "  Root FS: " $5 " used (" $3 "/" $2 ")"}'
    df -h /mnt/Media 2>/dev/null | awk 'NR>1 {print "  Media:   " $5 " used (" $3 "/" $2 ")"}'
    echo -e "\n  Largest directories in config:"
    du -sh "$BASE_PATH"/* 2>/dev/null | sort -hr | head -n 5 | sed 's/^/  /'
}

# Health check
health_check() {
    echo "---- SYSTEM HEALTH CHECK ----"
    local issues=0
    
    # Check service status
    echo "Services:"
    for service in "$PLEX_SERVICE" "${ARR_SERVICES[@]}"; do
        if systemctl is-active "$service" >/dev/null 2>&1; then
            echo "  [✓] $service is running"
        else
            echo "  [✗] $service is DOWN"
            notify "Service $service is down" "error"
            ((issues++))
        fi
    done
    
    # Check Docker containers
    echo -e "\nDocker Containers:"
    for container in "${DOCKER_CONTAINERS[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            echo "  [✓] $container is running"
        else
            echo "  [✗] $container is DOWN"
            notify "Docker container $container is down" "error"
            ((issues++))
        fi
    done
    
    # Check disk space
    echo -e "\nDisk Space:"
    local disk_usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
    if [ "$disk_usage" -gt "$THRESH_DISK_ROOT_CRITICAL" ]; then
        echo "  [✗] WARNING: Root disk usage at ${disk_usage}%"
        notify "High disk usage: ${disk_usage}%" "error"
        ((issues++))
    elif [ "$disk_usage" -gt "$THRESH_DISK_ROOT_WARN" ]; then
        echo "  [!] CAUTION: Root disk usage at ${disk_usage}%"
    else
        echo "  [✓] Root disk usage: ${disk_usage}%"
    fi
    
    # Check memory usage
    echo -e "\nMemory:"
    local mem_info=$(free | awk '/Mem:/ {printf "%.0f", ($3/$2)*100}')
    if [ "$mem_info" -gt "$THRESH_DISK_ROOT_CRITICAL" ]; then
        echo "  [✗] WARNING: Memory usage at ${mem_info}%"
        notify "High memory usage: ${mem_info}%" "error"
        ((issues++))
    elif [ "$mem_info" -gt "$THRESH_DISK_ROOT_WARN" ]; then
        echo "  [!] CAUTION: Memory usage at ${mem_info}%"
    else
        echo "  [✓] Memory usage: ${mem_info}%"
    fi
    free -h | awk '/Mem:/{print "  Total: " $2 ", Used: " $3 ", Available: " $7}'
    
    # Check system load
    echo -e "\nSystem Load:"
    local load_1min=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    local cores=$(nproc)
    if (( $(echo "$load_1min > $cores" | bc -l 2>/dev/null || echo 0) )); then
        echo "  [✗] WARNING: High load average: $load_1min (cores: $cores)"
        notify "High system load: $load_1min" "error"
        ((issues++))
    else
        echo "  [✓] Load average: $load_1min (cores: $cores)"
    fi
    
    # Check internet connectivity
    echo -e "\nConnectivity:"
    if ping -c1 -W5 8.8.8.8 >/dev/null 2>&1; then
        echo "  [✓] Internet connectivity OK"
    else
        echo "  [✗] WARNING: No internet connectivity"
        notify "Internet connectivity lost" "error"
        ((issues++))
    fi
    
    # Check uptime
    echo -e "\nSystem Info:"
    echo "  Uptime: $(uptime -p)"
    echo "  Load: $(uptime | awk -F'load average:' '{print $2}')"
    
    # Summary
    echo -e "\n---- HEALTH SUMMARY ----"
    if [ "$issues" -eq 0 ]; then
        echo "[✓] All systems healthy"
        notify "Health check passed - all systems OK" "success"
    else
        echo "[✗] Found $issues issue(s) - check logs above"
        notify "Health check found $issues issues" "error"
    fi
}

# Temperature monitoring
check_temperature() {
    echo "---- TEMPERATURE CHECK ----"
    for thermal in /sys/class/thermal/thermal_zone*/temp; do
        if [ -r "$thermal" ]; then
            temp=$(cat "$thermal")
            zone=$(basename $(dirname "$thermal"))
            temp_c=$((temp / 1000))
            if [ "$temp_c" -gt "$THRESH_TEMP_CRITICAL" ]; then
                echo "[✗] $zone: ${temp_c}°C - HIGH TEMPERATURE"
                notify "High temperature: $zone ${temp_c}°C" "error"
            elif [ "$temp_c" -gt "$THRESH_TEMP_WARN" ]; then
                echo "[!] $zone: ${temp_c}°C - WARM"
            else
                echo "[✓] $zone: ${temp_c}°C"
            fi
        fi
    done
}

# Network connectivity
check_network() {
    echo "---- NETWORK CONNECTIVITY ----"
    # Test specific services
    curl -s --max-time 5 https://api.themoviedb.org >/dev/null && echo "[✓] TMDB API reachable" || echo "[✗] TMDB API unreachable"
    curl -s --max-time 5 https://api.trakt.tv >/dev/null && echo "[✓] Trakt API reachable" || echo "[✗] Trakt API unreachable"
    nslookup example.com >/dev/null 2>&1 && echo "[✓] DNS resolution OK" || echo "[✗] DNS resolution failed"
}

# Process monitoring
check_processes() {
    echo "---- PROCESS MONITORING ----"
    # Check for zombie processes
    zombies=$(ps aux | awk '$8 ~ /^Z/ { count++ } END { print count+0 }')
    [ "$zombies" -gt 0 ] && echo "[✗] WARNING: $zombies zombie processes" || echo "[✓] No zombie processes"
    
    # Show top CPU processes
    echo "Top CPU processes:"
    ps aux --sort=-%cpu | head -4 | tail -3
}

# Configuration validation
validate_configs() {
    echo "---- CONFIGURATION VALIDATION ----"
    
    # Check Kometa config exists and validate YAML syntax
    if [ -f "$BASE_PATH/config.yml" ]; then
        if python3 -c "import yaml; yaml.safe_load(open('$BASE_PATH/config.yml'))" 2>/dev/null; then
            echo "[✓] Kometa config.yml is valid YAML"
        else
            echo "[✗] Kometa config.yml has YAML syntax errors"
            notify "Kometa config.yml has YAML syntax errors" "error"
        fi
    else
        echo "[✗] Kometa config.yml not found"
    fi

    # Check Kometa movies.yml
    if [ -f "$BASE_PATH/movies.yml" ]; then
        if python3 -c "import yaml; yaml.safe_load(open('$BASE_PATH/movies.yml'))" 2>/dev/null; then
            echo "[✓] Kometa movies.yml is valid YAML"
        else
            echo "[✗] Kometa movies.yml has YAML syntax errors"
            notify "Kometa movies.yml has YAML syntax errors" "error"
        fi
    fi

    # Check Kometa tv.yml
    if [ -f "$BASE_PATH/tv.yml" ]; then
        if python3 -c "import yaml; yaml.safe_load(open('$BASE_PATH/tv.yml'))" 2>/dev/null; then
            echo "[✓] Kometa tv.yml is valid YAML"
        else
            echo "[✗] Kometa tv.yml has YAML syntax errors"
            notify "Kometa tv.yml has YAML syntax errors" "error"
        fi
    fi
    
    # Check UMTK config
    local umtk_config="$UMTK_CONFIG_DIR/config.yml"
    if [ -f "$umtk_config" ]; then
        if python3 -c "import yaml; yaml.safe_load(open('$umtk_config'))" 2>/dev/null; then
            echo "[✓] UMTK config.yml is valid YAML"
        else
            echo "[✗] UMTK config.yml has YAML syntax errors"
            notify "UMTK config.yml has YAML syntax errors" "error"
        fi
    else
        echo "[✗] UMTK config.yml not found"
    fi
    
    # Check UMTK TSSK config
    local tssk_config="$UMTK_CONFIG_DIR/tssk_config.yml"
    if [ -f "$tssk_config" ]; then
        if python3 -c "import yaml; yaml.safe_load(open('$tssk_config'))" 2>/dev/null; then
            echo "[✓] UMTK tssk_config.yml is valid YAML"
        else
            echo "[✗] UMTK tssk_config.yml has YAML syntax errors"
            notify "UMTK tssk_config.yml has YAML syntax errors" "error"
        fi
    else
        echo "[✗] UMTK tssk_config.yml not found"
    fi
    
    # Check ImageMaid config
    local imagemaid_env="$IMAGEMAID_CONFIG_DIR/.env"
    if [ -f "$imagemaid_env" ]; then
        echo "[✓] ImageMaid .env exists"
    else
        echo "[✗] ImageMaid .env not found"
    fi
    
    # Check log directory
    [ -d "$LOG_DIR" ] && echo "[✓] Log directory exists" || echo "[✗] Log directory missing"
}

# Token consistency check
check_token_consistency() {
    echo "---- TOKEN CONSISTENCY CHECK ----"
    
    # Extract Plex tokens from all configs
    local kometa_token=$(grep -oP '(?<=token: ).*' "$BASE_PATH/config.yml" 2>/dev/null | head -1 | tr -d ' ')
    local umtk_token=$(grep -oP "(?<=plex_token.: ').*(?=')" "$UMTK_CONFIG_DIR/config.yml" 2>/dev/null)
    local imagemaid_token=$(grep -oP '(?<=PLEX_TOKEN=).*' "$IMAGEMAID_CONFIG_DIR/.env" 2>/dev/null)
    
    if [ -z "$kometa_token" ]; then
        echo "[✗] Could not read Plex token from Kometa config"
        return
    fi
    
    local mismatch=false
    
    if [ -n "$umtk_token" ] && [ "$umtk_token" != "$kometa_token" ]; then
        echo "[✗] UMTK token does not match Kometa token"
        notify "Plex token mismatch: UMTK token differs from Kometa" "error"
        mismatch=true
    fi
    
    if [ -n "$imagemaid_token" ] && [ "$imagemaid_token" != "$kometa_token" ]; then
        echo "[✗] ImageMaid token does not match Kometa token"
        notify "Plex token mismatch: ImageMaid token differs from Kometa" "error"
        mismatch=true
    fi
    
    if [ "$mismatch" == false ]; then
        echo "[✓] Plex token consistent across all configs"
    fi
}



######## MENU ########
show_main_menu() {
    clear
    echo "==================================="
    echo "  Media Server Maintenance Script  "
    echo "==================================="
    echo
    echo "---------------------------------"
    echo " 1: System Maintenance"
    echo " 2: Update Media Tools"
    echo " 3: Update Docker Containers"
    echo " 4: Restart Services"
    echo " 5: Disk Maintenance"
    echo " 6: Health Check"
    echo " 7: Temperature Check"
    echo " 8: Network Check"
    echo " 9: Process Monitor"
    echo "10: Config Validation"
    echo "11: Token Consistency Check"
    echo "12: Check Docker Updates (no pull)"
    echo
    echo " C: Clean Screen"
    echo " L: View Logs"
    echo " Q: Quit"
    echo
}

######## MAIN ########

# Scheduled mode: run with --scheduled flag for unattended execution
if [[ "$1" == "--scheduled" ]]; then
    init_logging
    echo "Running in scheduled mode..."
    echo
    system_maintenance
    echo
    update_media_tools
    echo
    update_containers
    echo
    validate_configs
    echo
    check_token_consistency
    echo
    disk_maintenance
    echo "===== Scheduled maintenance complete: $(date) ====="
    notify "Scheduled maintenance complete" "success"
    exit 0
fi

init_logging

# Interactive mode
while true; do
    show_main_menu
    read -p "Enter selection: " selection
    
    case "$selection" in
        1) system_maintenance ;;
        2) update_media_tools ;;
        3) update_containers ;;
        4) manage_services ;;
        5) disk_maintenance ;;
        6) health_check ;;
        7) check_temperature ;;
        8) check_network ;;
        9) check_processes ;;
        10) validate_configs ;;
        11) check_token_consistency ;;
        12) check_docker_updates ;;
        c|C) clear ;;
        l|L) 
            if [ -f "$LOG_FILE" ]; then
                less "$LOG_FILE"
            else
                echo "No log file available"
            fi
            ;;
        q|Q) 
            echo "Exiting. Goodbye!"
            notify "Maintenance session ended" "success"
            exit 0
            ;;
        *) 
            echo "Invalid option: $selection"
            sleep 1
            ;;
    esac
    
    read -p "Operation complete. Press any key to continue..." -n1 -s
    echo
done
