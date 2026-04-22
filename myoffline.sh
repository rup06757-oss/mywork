#!/bin/bash
################################################################################
# RMEYE Environment Setup Script (OFFLINE / AIR-GAPPED)
#
# Usage:  ./RMEYE_env_setup.sh [--precheck|--test] [--help]
#
# Requirements:
#   - Ubuntu 20.04 or 24.04 LTS
#   - sudo access
#   - Pre-staged .deb packages in ./debs/ (see Bundle Layout below)
#
# This script performs NO outbound network access.  All packages must be staged
# locally before execution.  The installation order and application versions
# match the original online RMEYE_env_setup.sh exactly.
#
# Bundle Layout (next to this script):
#
#   ./debs/
#       common/     - Shared system prerequisites
#                     (gnupg2, ca-certificates, lsb-release, ubuntu-keyring,
#                      apt-transport-https, locales, wget, curl stubs, etc.)
#       nginx/      - nginx and nginx-specific transitive dependencies
#       dotnet/     - dotnet-sdk-6.0, dotnet-sdk-8.0 and transitive deps
#       postgres/   - postgresql-13, postgresql-client-13,
#                     timescaledb-2-postgresql-13  (=2.15.*),
#                     timescaledb-2-loader-postgresql-13 (=2.15.*),
#                     postgresql-13-pgagent,
#                     and ALL transitive dependencies
#       node/       - nodejs (20.x from NodeSource), jq,
#                     browser/headless runtime libraries,
#                     and ALL transitive dependencies
#
#   ./default.conf          - Nginx site configuration
#   ./pgagent.service       - pgagent systemd unit file
#   ./pg_job_scripts/       - SQL files for pgAgent scheduled jobs
#   ./security_scripts/     - Security hardening scripts
#
# Each subdirectory must contain .deb files AND every transitive dependency
# required by those packages.  Use  apt-get install --download-only  on a
# connected staging host (same Ubuntu release) to collect them.
################################################################################
# check version info by cat rmeye_deployement/VERSION

# ---------- strict error handling ----------
set -euo pipefail

# ---------- resolve script location ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEBS_DIR="${SCRIPT_DIR}/debs"

# ---------- CLI parsing ----------
PRECHECK_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --precheck|--test)
            PRECHECK_ONLY=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --precheck, --test    Run pre-checks only and exit"
            echo "  --help, -h            Show this help message"
            echo ""
            echo "Pre-checks include:"
            echo "  - Disk space verification"
            echo "  - RAM verification"
            echo "  - Port availability (80, 443, 5432)"
            echo "  - Offline .deb bundle verification"
            echo "  - Filesystem permissions"
            echo "  - Sudo access"
            exit 0
            ;;
        *)
            echo -e "\033[1;33mUnknown option: $arg (use --help for usage)\033[0m"
            ;;
    esac
done

# ---------- colour codes ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- run command with sudo permission ----------
run_with_sudo() {
    refreshPermissions "$$" &
    local refresh_pid=$!
    if ! sudo "$@"; then
        kill "$refresh_pid" 2>/dev/null || true
        return 1
    fi
    kill "$refresh_pid" 2>/dev/null || true
    return 0
}

# ---------- messaging helpers ----------
error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

success_msg() {
    echo -e "${GREEN}$1${NC}"
}

warning_msg() {
    echo -e "${YELLOW}$1${NC}"
}

info_msg() {
    echo -e "${BLUE}$1${NC}"
}

command_exists() {
    command -v "$1" &>/dev/null
}

# ---------- background sudo refresher ----------
refreshPermissions() {
    local pid="${1}"
    while kill -0 "${pid}" 2>/dev/null; do
        sudo -v
        sleep 10
    done
}

################################################################################
# Offline Package Installation Helpers
################################################################################

validate_debs_subdir() {
    local label="$1"
    local dir="$2"

    if [[ ! -d "$dir" ]]; then
        echo -e "${RED}    Missing package directory: ${dir}${NC}" >&2
        return 1
    fi

    shopt -s nullglob
    local deb_files=("${dir}"/*.deb)
    shopt -u nullglob

    if [[ ${#deb_files[@]} -eq 0 ]]; then
        echo -e "${RED}    No .deb files in ${dir}${NC}" >&2
        return 1
    fi

    return 0
}

# Install all .deb files from a directory with automatic dependency resolution.
# Acquire::Retries=0 + short timeouts guarantee no blocking on a missing network.
install_debs_from_dir() {
    local label="$1"
    local dir="$2"

    if [[ ! -d "$dir" ]]; then
        error_exit "Required package directory missing: ${dir}"
    fi

    shopt -s nullglob
    local deb_files=("${dir}"/*.deb)
    shopt -u nullglob

    if [[ ${#deb_files[@]} -eq 0 ]]; then
        error_exit "No .deb packages found in ${dir}"
    fi

    info_msg "Installing ${#deb_files[@]} packages (${label})..."

    export DEBIAN_FRONTEND=noninteractive

    if ! run_with_sudo dpkg -i "${deb_files[@]}" 2>&1; then
        warning_msg "dpkg initial pass for ${label} has unresolved deps, fixing..."

        if ! run_with_sudo apt-get install -f -y \
                -o Acquire::Retries=0 \
                -o Acquire::http::Timeout=5 \
                -o Acquire::https::Timeout=5 2>&1; then
            error_exit "Dependency resolution failed for ${label}. Ensure ALL transitive .deb files are staged in ${dir}/"
        fi

        if ! run_with_sudo dpkg --configure -a 2>&1; then
            error_exit "dpkg --configure -a failed for ${label}. Run: dpkg --audit"
        fi
    fi

    success_msg "Package installation completed: ${label}"
}

# Best-effort variant that never aborts the script.
install_debs_best_effort() {
    local label="$1"
    local dir="$2"

    if [[ ! -d "$dir" ]]; then
        warning_msg "Best-effort install skipped (${label}): directory ${dir} missing"
        return 0
    fi

    shopt -s nullglob
    local deb_files=("${dir}"/*.deb)
    shopt -u nullglob

    [[ ${#deb_files[@]} -eq 0 ]] && return 0

    export DEBIAN_FRONTEND=noninteractive
    set +e
    run_with_sudo dpkg -i "${deb_files[@]}" 2>&1 || true
    run_with_sudo apt-get install -f -y -o Acquire::Retries=0 2>&1 || true
    run_with_sudo dpkg --configure -a 2>&1 || true
    set -e
    return 0
}

# Check if a named package is installed.
pkg_installed() {
    dpkg -s "$1" &>/dev/null
}

################################################################################
# System Pre-Checks Functions
################################################################################

check_port_available() {
    local port="$1"
    local service_name="${2:-unknown}"

    if command_exists netstat; then
        if netstat -tuln 2>/dev/null | grep -q ":$port "; then
            echo -e "${RED}    FAILED: Port $port in use (needed for $service_name)${NC}" >&2
            return 1
        fi
    elif command_exists ss; then
        if ss -tuln 2>/dev/null | grep -q ":$port "; then
            echo -e "${RED}    FAILED: Port $port in use (needed for $service_name)${NC}" >&2
            return 1
        fi
    else
        warning_msg "Cannot check port $port (netstat/ss unavailable)"
        return 1
    fi

    success_msg "Port $port: Available for $service_name"
    return 0
}

check_disk_space() {
    local required_gb="${1:-10}"
    local mount_point="${2:-/}"

    local available_kb
    available_kb=$(df -k "$mount_point" 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
    local available_gb=$((available_kb / 1024 / 1024))

    if [[ $available_gb -lt $required_gb ]]; then
        echo -e "${RED}    FAILED: Insufficient disk space. Required: ${required_gb}GB, Available: ${available_gb}GB${NC}" >&2
        return 1
    fi

    success_msg "Disk Space: ${available_gb}GB available (min: ${required_gb}GB)"
    return 0
}

check_ram() {
    local required_gb="${1:-2}"
    local required_mb=$((required_gb * 1024))

    local total_ram_kb
    total_ram_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    local total_ram_mb=$((total_ram_kb / 1024))
    local total_ram_gb
    total_ram_gb=$(awk "BEGIN {printf \"%.1f\", $total_ram_mb / 1024}")

    if [[ $total_ram_mb -lt $required_mb ]]; then
        echo -e "${RED}    FAILED: Insufficient RAM. Required: ${required_gb}GB, Available: ${total_ram_gb}GB${NC}" >&2
        return 1
    fi

    success_msg "RAM: ${total_ram_gb}GB available (min: ${required_gb}GB)"
    return 0
}

check_dependency() {
    local cmd="$1"
    if ! command_exists "$cmd"; then
        warning_msg "Command '$cmd' not found. It will be installed during setup."
        return 1
    fi
    return 0
}

check_required_dependencies() {
    local missing_deps=()
    local optional_deps=()

    local critical_deps=("dpkg" "gpg" "apt-get")
    local optional_cmds=("gzip" "tar" "sed" "awk" "grep" "find")

    for dep in "${critical_deps[@]}"; do
        if ! command_exists "$dep"; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${RED}    FAILED: Critical dependencies missing: ${missing_deps[*]}${NC}" >&2
        return 1
    fi

    for dep in "${optional_cmds[@]}"; do
        if ! command_exists "$dep"; then
            optional_deps+=("$dep")
        fi
    done

    if [[ ${#optional_deps[@]} -gt 0 ]]; then
        warning_msg "Optional dependencies missing (will install later): ${optional_deps[*]}"
    fi

    success_msg "Dependencies: All critical offline tools available (dpkg, gpg, apt-get)"
    return 0
}

check_filesystem_permissions() {
    local test_dir="/tmp"
    local test_file

    test_file=$(mktemp "$test_dir/rmeye_test_XXXXXX" 2>/dev/null)
    if [[ -z "$test_file" ]]; then
        echo -e "${RED}    FAILED: Cannot write to $test_dir${NC}" >&2
        return 1
    fi

    if ! rm -f "$test_file" 2>/dev/null; then
        echo -e "${RED}    FAILED: Cannot remove files from $test_dir${NC}" >&2
        return 1
    fi

    if [[ ! -w "." ]]; then
        echo -e "${RED}    FAILED: Current directory is not writable${NC}" >&2
        echo -e "\e[33mHint: Run [chmod -R 755 .] if that doesn't work, try [sudo chmod -R 755 .] \e[0m"
        return 1
    fi

    success_msg "Filesystem: Write permissions OK"
    return 0
}

# Replaces the online network-connectivity check with offline bundle validation.
check_offline_bundle() {
    local all_ok=true

    if [[ ! -d "$DEBS_DIR" ]]; then
        echo -e "${RED}    FAILED: Offline bundle root missing: ${DEBS_DIR}${NC}" >&2
        return 1
    fi

    local required_dirs=("common" "nginx" "dotnet" "postgres" "node")
    for subdir in "${required_dirs[@]}"; do
        if ! validate_debs_subdir "$subdir" "${DEBS_DIR}/${subdir}"; then
            all_ok=false
        else
            shopt -s nullglob
            local count
            count=$(set -- "${DEBS_DIR}/${subdir}"/*.deb; echo $#)
            shopt -u nullglob
            success_msg "  ${subdir}/: ${count} .deb file(s)"
        fi
    done

    if [[ "$all_ok" != "true" ]]; then
        echo -e "${RED}    FAILED: Offline bundle incomplete. Stage all required .deb files.${NC}" >&2
        return 1
    fi

    success_msg "Offline bundle: All required package directories present"
    return 0
}

check_sudo_access() {
    if [[ $EUID -eq 0 ]]; then
        success_msg "Sudo: Running as root"
        return 0
    fi

    if ! command_exists sudo; then
        echo -e "${RED}    FAILED: sudo command not found${NC}" >&2
        return 1
    fi

    if ! sudo -n true 2>/dev/null; then
        info_msg "Requesting sudo access..."
        if ! sudo -v; then
            echo -e "${RED}    FAILED: Cannot obtain sudo privileges${NC}" >&2
            return 1
        fi
    fi

    success_msg "Sudo: Access confirmed"
    return 0
}

check_existing_services() {
    local services_to_check=("nginx" "postgresql")
    local running_services=()

    for service in "${services_to_check[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            running_services+=("$service")
        fi
    done

    if [[ ${#running_services[@]} -gt 0 ]]; then
        success_msg "Services: ${running_services[*]} already running (will reconfigure)"
    else
        success_msg "Services: No existing services found"
    fi

    return 0
}

# ---------- comprehensive pre-checks ----------
run_system_prechecks() {
    local precheck_only="${1:-false}"

    echo ""
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo -e "${BLUE}${BOLD}  RMEYE Deployment Pre-Checks (Offline)${NC}"
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo ""

    local checks_passed=0
    local checks_failed=0

    set +e

    if check_sudo_access; then
        ((checks_passed++)) || true
    else
        ((checks_failed++)) || true
    fi

    if check_disk_space 10 "/"; then
        ((checks_passed++)) || true
    else
        ((checks_failed++)) || true
    fi

    if check_ram 2; then
        ((checks_passed++)) || true
    else
        ((checks_failed++)) || true
    fi

    if check_required_dependencies; then
        ((checks_passed++)) || true
    else
        ((checks_failed++)) || true
    fi

    if check_filesystem_permissions; then
        ((checks_passed++)) || true
    else
        ((checks_failed++)) || true
    fi

    if check_offline_bundle; then
        ((checks_passed++)) || true
    else
        ((checks_failed++)) || true
    fi

    set +e
    if ! systemctl is-active --quiet nginx 2>/dev/null; then
        if check_port_available 80 "Nginx HTTP"; then
            ((checks_passed++)) || true
        else
            ((checks_failed++)) || true
        fi

        if check_port_available 443 "Nginx HTTPS"; then
            ((checks_passed++)) || true
        else
            ((checks_failed++)) || true
        fi
    else
        success_msg "Ports 80/443: In use by Nginx (OK)"
        ((checks_passed++)) || true
    fi

    if ! systemctl is-active --quiet postgresql 2>/dev/null; then
        if check_port_available 5432 "PostgreSQL"; then
            ((checks_passed++)) || true
        else
            ((checks_failed++)) || true
        fi
    else
        success_msg "Port 5432: In use by PostgreSQL (OK)"
        ((checks_passed++)) || true
    fi

    if check_existing_services; then
        ((checks_passed++)) || true
    else
        ((checks_failed++)) || true
    fi

    set -e

    echo ""
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo -e "${BLUE}${BOLD}  Pre-Check Summary${NC}"
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo -e "${GREEN}Checks Passed: $checks_passed${NC}"
    if [[ $checks_failed -gt 0 ]]; then
        echo -e "${RED}Checks Failed: $checks_failed${NC}"
        echo ""
        if [[ "$precheck_only" == "true" ]]; then
            error_exit "Pre-checks failed. Please resolve the issues before running deployment."
        else
            error_exit "Pre-checks failed. Please resolve the issues before continuing."
        fi
    else
        success_msg "All pre-checks passed! System is ready for deployment."
        echo ""
    fi

    if [[ "$precheck_only" == "true" ]]; then
        echo -e "${GREEN}Pre-check mode completed. Run without --precheck to start deployment.${NC}"
        exit 0
    fi

    return 0
}

################################################################################
# Database backup / restore  (identical to original — no internet dependency)
################################################################################

restore_database_backups() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    local input_path="${1:-}"
    local search_dir="$script_dir"
    local filename=""
    local db_name="${DB_NAME:-rmeye_db}"
    local db_user="${DB_USERNAME:-postgres}"
    local db_host="${DB_HOST:-localhost}"
    local db_port="${DB_PORT:-5432}"
    local db_password="${DB_PASSWORD:-hotandcold}"
    local selected_backup=""
    local selected_ext=""
    local log_file=""
    local restore_rc=0
    local -a backups=()

    if [[ -n "$input_path" ]]; then
        if [[ -f "$input_path" && ( "$input_path" == *.backup || "$input_path" == *.sql ) ]]; then
            selected_backup="$input_path"
            search_dir="$(dirname "$selected_backup")"
        elif [[ -d "$input_path" ]]; then
            search_dir="$input_path"
        elif [[ -f "$script_dir/$input_path" && ( "$script_dir/$input_path" == *.backup || "$script_dir/$input_path" == *.sql ) ]]; then
            selected_backup="$script_dir/$input_path"
            search_dir="$(dirname "$selected_backup")"
        elif [[ -d "$script_dir/$input_path" ]]; then
            search_dir="$script_dir/$input_path"
        else
            warning_msg "Backup path '$input_path' not found. Falling back to '$script_dir'."
            search_dir="$script_dir"
        fi
    fi

    echo -e "${BLUE}Checking PostgreSQL health...${NC}"

    if ! PGPASSWORD="$db_password" psql \
        -h "$db_host" -p "$db_port" -U "$db_user" -d postgres \
        -c "SELECT 1;" >/dev/null 2>&1; then
        if [[ "$db_host" == "localhost" || "$db_host" == "127.0.0.1" ]]; then
            if sudo -u postgres psql -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
                info_msg "Connected via peer auth. Setting postgres password for future connections..."
                sudo -u postgres psql -d postgres -c "ALTER USER postgres WITH PASSWORD 'hotandcold';" 2>/dev/null || true
                export DB_PASSWORD="hotandcold"
                db_password="hotandcold"
            else
                echo -e "${RED}PostgreSQL is not accepting connections (tried password and peer auth)${NC}" >&2
                return 1
            fi
        else
            echo -e "${RED}PostgreSQL is not accepting connections${NC}" >&2
            return 1
        fi
    fi

    echo -e "${GREEN}PostgreSQL is healthy${NC}"

    if [[ -z "$selected_backup" ]]; then
        local backup_candidate
        shopt -s nullglob
        for backup_candidate in "$search_dir"/*.backup; do
            backups+=("$backup_candidate")
        done
        for backup_candidate in "$search_dir"/*.sql; do
            backups+=("$backup_candidate")
        done
        shopt -u nullglob
    else
        backups+=("$selected_backup")
    fi

    if [[ ${#backups[@]} -eq 0 ]]; then
        info_msg "No .backup or .sql files found. Skipping database restore."
        return 0
    fi

    if [[ ${#backups[@]} -eq 1 ]]; then
        selected_backup="${backups[0]}"
        info_msg "Only one backup file available. Auto-selecting: $(basename "$selected_backup")"
    else
        info_msg "Available backup files for database restoration:"
        for i in "${!backups[@]}"; do
            echo "  [$((i+1))] $(basename "${backups[$i]}")"
        done

        read -p "Select backup file to restore [1-${#backups[@]}]: " choice
        [[ "$choice" =~ ^[0-9]+$ ]] || error_exit "Invalid selection"
        (( choice >= 1 && choice <= ${#backups[@]} )) || error_exit "Selection out of range"

        selected_backup="${backups[$((choice-1))]}"
    fi

    if [[ "$selected_backup" == *.backup ]]; then
        selected_ext="backup"
    elif [[ "$selected_backup" == *.sql ]]; then
        selected_ext="sql"
    else
        error_exit "Unsupported backup format: $selected_backup"
    fi

    echo -e "${BLUE}Target database: $db_name${NC}"

    local db_exists
    db_exists=$(PGPASSWORD="$db_password" psql \
        -h "$db_host" -p "$db_port" -U "$db_user" -d postgres \
        -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name'" 2>/dev/null)

    if [[ "$db_exists" == "1" ]]; then
        echo -e "${YELLOW}Database '$db_name' exists${NC}"

        local table_count
        table_count=$(PGPASSWORD="$db_password" psql \
            -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" \
            -tAc "SELECT COUNT(*) FROM pg_tables WHERE schemaname='public';" 2>/dev/null)

        if [[ "$table_count" -gt 0 ]]; then
            read -p "Do you want to create a new database & restore it? (y/n): " create_new_db

            if [[ "$create_new_db" != "y" && "$create_new_db" != "Y" ]]; then
                echo -e "${YELLOW}Restore operation cancelled by user${NC}"
                return 0
            fi

            read -p "Enter NEW database name to restore into: " db_name

            if [[ -z "$db_name" ]]; then
                echo -e "${RED}Database name cannot be empty${NC}"
                return 1
            fi

            echo -e "${BLUE}Creating new database '$db_name'...${NC}"
            if ! PGPASSWORD="$db_password" psql \
                -h "$db_host" -p "$db_port" -U "$db_user" -d postgres \
                -c "CREATE DATABASE \"$db_name\" OWNER \"$db_user\";" 2>&1; then
                echo -e "${RED}Failed to create database${NC}"
                return 1
            fi
        else
            echo -e "${GREEN}Database is empty - safe to restore${NC}"
        fi
    else
        echo -e "${BLUE}Database '$db_name' does not exist. Creating...${NC}"
        if ! PGPASSWORD="$db_password" psql \
            -h "$db_host" -p "$db_port" -U "$db_user" -d postgres \
            -c "CREATE DATABASE \"$db_name\" OWNER \"$db_user\";" 2>&1; then
            echo -e "${RED}Failed to create database${NC}"
            return 1
        fi
    fi

    if [[ "$db_name" == *golden* || "$(basename "$selected_backup")" == *golden* ]]; then
        echo ""
        echo -e "${BLUE}${BOLD}=====================================================${NC}"
        echo -e "${BLUE}${BOLD}  Restoring golden db${NC}"
        echo -e "${BLUE}${BOLD}=====================================================${NC}"
    fi

    echo -e "${BLUE}Restoring backup: $selected_backup${NC}"
    log_file="${selected_backup%.*}_restore.log"

    set +e
    if [[ "$selected_ext" == "backup" ]]; then
        PGPASSWORD="$db_password" pg_restore \
            -h "$db_host" \
            -p "$db_port" \
            -U "$db_user" \
            -d "$db_name" \
            --no-owner \
            --no-privileges \
            -v "$selected_backup" \
            2>&1 | tee -a "$log_file"
        restore_rc=${PIPESTATUS[0]}
    else
        PGPASSWORD="$db_password" psql \
            -h "$db_host" \
            -p "$db_port" \
            -U "$db_user" \
            -d "$db_name" \
            -v ON_ERROR_STOP=1 \
            -f "$selected_backup" \
            2>&1 | tee -a "$log_file"
        restore_rc=${PIPESTATUS[0]}
    fi
    set -e

    if [[ $restore_rc -eq 0 || ( "$selected_ext" == "backup" && $restore_rc -eq 1 ) ]]; then
        echo -e "${GREEN}Database restore completed successfully${NC}"
    else
        echo -e "${RED}Restore failed with critical errors${NC}"
        echo -e "${RED}Check log: $log_file${NC}"
        return 1
    fi
}

################################################################################
# Main Script Execution
################################################################################

run_system_prechecks "$PRECHECK_ONLY"

# ---------- OS detection ----------
if [[ ! -f /etc/os-release ]]; then
    error_exit "Cannot find /etc/os-release. This script requires Ubuntu."
fi

source /etc/os-release
os_name="${ID:-}"
os_version="${VERSION_ID:-}"
ubuntu_codename="${VERSION_CODENAME:-}"
os_info="${PRETTY_NAME:-Unknown}"

if [[ "$os_name" != "ubuntu" ]]; then
    error_exit "Unsupported OS: ${os_name:-unknown}. This script supports Ubuntu only."
fi

if [[ "$os_version" =~ ^20\.04$ || "$os_version" =~ ^24\.04$ ]]; then
    cpu_info=$(lscpu | grep "Model name" | awk -F: '{print $2}' | xargs || echo "Unknown")
    num_cores=$(lscpu | grep "^CPU(s):" | awk -F: '{print $2}' | xargs || echo "Unknown")
    ram_info=$(free -h | grep "Mem:" | awk '{print $2}' || echo "Unknown")
    storage_info=$(df -h --total | grep "total" | awk '{print $2}' || echo "Unknown")
else
    error_exit "OS Version is not compatible for deployment: $os_version (supported: 20.04, 24.04)"
fi

echo "1. OS Information: $os_info"
echo "2. CPU: $cpu_info"
echo "3. Number of Cores: $num_cores"
echo "4. RAM: $ram_info"
echo "5. Storage: $storage_info"
success_msg "OS Version is Compatible for deployment!"

PG_MAJOR="13"

# ---------- locale ----------
DESIRED_LOCALE="en_US.UTF-8"
CURRENT_LOCALE=$(locale 2>/dev/null | grep "^LANG=" | cut -d= -f2 || echo "")

if [[ "$CURRENT_LOCALE" == "$DESIRED_LOCALE" ]]; then
    success_msg "Locale is already set to $DESIRED_LOCALE"
else
    info_msg "Setting locale to $DESIRED_LOCALE"

    if ! locale -a 2>/dev/null | grep -qi "$DESIRED_LOCALE"; then
        info_msg "Generating $DESIRED_LOCALE locale..."
        if ! sudo locale-gen "$DESIRED_LOCALE"; then
            error_exit "Failed to generate locale $DESIRED_LOCALE"
        fi
    fi

    if ! sudo update-locale LANG="$DESIRED_LOCALE"; then
        error_exit "Failed to update locale"
    fi

    warning_msg "Please reboot the system and re-run the script!"
    exit 1
fi

################################################################################
# Phase 1 - System prerequisites (common .deb packages)
################################################################################

info_msg "========== Installing system prerequisites =========="
install_debs_from_dir "system prerequisites" "${DEBS_DIR}/common"
success_msg "========== System prerequisites installed =========="

################################################################################
# Phase 2 - Nginx installation
################################################################################

if command_exists nginx; then
    nginx_version_info=$(nginx -v 2>&1 | awk -F/ '{print $2}' || true)
    if [[ -n "$nginx_version_info" ]]; then
        success_msg "Already nginx installed with version: $nginx_version_info"
    else
        success_msg "Already nginx installed (version unknown)"
    fi
else
    info_msg "======== Nginx installation started =========="

    install_debs_from_dir "nginx" "${DEBS_DIR}/nginx"

    if command_exists nginx; then
        success_msg "========== Nginx installed successfully =========="
        info_msg "******** Copying the nginx configuration files! ********"

        if [[ ! -f "$SCRIPT_DIR/default.conf" ]]; then
            warning_msg "default.conf not found. Skipping configuration copy."
        elif ! sudo cp "$SCRIPT_DIR/default.conf" /etc/nginx/conf.d/; then
            error_exit "Error: Copying default.conf failed."
        else
            success_msg "Nginx configuration file copied successfully"
        fi
    else
        error_exit "========== Nginx installation failed! =========="
    fi
fi

################################################################################
# Phase 3 - .NET Installation
################################################################################

DOTNET_ROOT="/usr/share/dotnet"

is_dotnet_installed() {
    local version="$1"
    if command -v dotnet &>/dev/null; then
        dotnet --list-sdks 2>/dev/null | grep -q "^${version}\." && return 0
    fi
    return 1
}

check_dotnet_exists() {
    local REQUIRED_VERSIONS=("6" "8")
    local all_installed=true

    if ! command -v dotnet &>/dev/null; then
        return 1
    fi

    for ver in "${REQUIRED_VERSIONS[@]}"; do
        if ! is_dotnet_installed "$ver"; then
            all_installed=false
            break
        fi
    done

    [[ "$all_installed" == "true" ]]
}

setup_dotnet_environment() {
    info_msg "Setting up .NET environment..."

    if [[ ! -L /usr/bin/dotnet && -f "$DOTNET_ROOT/dotnet" ]]; then
        run_with_sudo ln -sf "$DOTNET_ROOT/dotnet" /usr/bin/dotnet
        success_msg "Created symlink: /usr/bin/dotnet -> $DOTNET_ROOT/dotnet"
    fi

    if [[ ! -f /etc/profile.d/dotnet.sh ]]; then
        echo "export DOTNET_ROOT=$DOTNET_ROOT" | run_with_sudo tee /etc/profile.d/dotnet.sh > /dev/null
        echo 'export PATH=$PATH:$DOTNET_ROOT' | run_with_sudo tee -a /etc/profile.d/dotnet.sh > /dev/null
        run_with_sudo chmod +x /etc/profile.d/dotnet.sh
        success_msg "Created /etc/profile.d/dotnet.sh for system-wide PATH"
    fi

    export DOTNET_ROOT="$DOTNET_ROOT"
    export PATH="$PATH:$DOTNET_ROOT"
}

validate_dotnet() {
    export PATH="$PATH:$DOTNET_ROOT"
    hash -r 2>/dev/null || true

    if command -v dotnet &>/dev/null; then
        success_msg "dotnet CLI available: $(which dotnet)"
        echo ""
        info_msg "Installed .NET SDKs:"
        dotnet --list-sdks 2>/dev/null || true
        echo ""
        info_msg "Installed .NET Runtimes:"
        dotnet --list-runtimes 2>/dev/null || true
    else
        error_exit "dotnet CLI not found after installation. Please restart your terminal or run: source /etc/profile.d/dotnet.sh"
    fi
}

install_dotnet() {
    echo ""
    info_msg "========== .NET Installation =========="

    if check_dotnet_exists; then
        success_msg "All required .NET versions are already installed - Skipping installation"
        echo ""
        info_msg "Installed .NET SDKs:"
        dotnet --list-sdks 2>/dev/null || true
        echo ""
        return 0
    fi

    warning_msg ".NET is not fully installed. Proceeding with installation..."

    run_with_sudo mkdir -p "$DOTNET_ROOT"

    install_debs_from_dir ".NET SDK 6.0 + 8.0" "${DEBS_DIR}/dotnet"

    setup_dotnet_environment
    validate_dotnet

    success_msg "========== .NET Installed Successfully =========="
    echo ""
}

install_dotnet

################################################################################
# Phase 4 - PostgreSQL + TimescaleDB installation AND configuration
#
# KEY FIX:  The original script ran all post-install configuration (pg_hba,
# password, role creation) only inside the "else" branch — meaning re-runs
# that found psql already present skipped the entire configuration.
# This version ALWAYS runs the idempotent configuration block after verifying
# the packages are present, regardless of whether they were just installed.
################################################################################

# --- 4a: Package installation ---
if pkg_installed "postgresql-${PG_MAJOR}"; then
    psql_version_raw=$(psql -V 2>/dev/null || true)
    if [[ -n "$psql_version_raw" ]]; then
        success_msg "========== Already postgresql installed with version: $psql_version_raw ==========="
    else
        success_msg "Already postgresql installed (version unknown)"
    fi
else
    info_msg "========== PostgreSQL installation started... =========="

    install_debs_from_dir "PostgreSQL ${PG_MAJOR} + TimescaleDB 2.15.x" "${DEBS_DIR}/postgres"

    if ! pkg_installed "postgresql-${PG_MAJOR}"; then
        error_exit "========== PostgreSQL installation failed! =========="
    fi
    success_msg "========== PostgreSQL Installed Successfully =========="
fi

# --- 4b: Configuration (ALWAYS runs — every operation is idempotent) ---
if ! command_exists psql; then
    error_exit "psql binary not found after package installation. Aborting."
fi

info_msg "******** Setting up PostgreSQL configuration! ********"

pg_conf="/etc/postgresql/${PG_MAJOR}/main/postgresql.conf"
pg_hba="/etc/postgresql/${PG_MAJOR}/main/pg_hba.conf"

if [[ ! -f "$pg_conf" ]]; then
    error_exit "PostgreSQL configuration file not found: $pg_conf"
fi

if [[ ! -f "$pg_hba" ]]; then
    error_exit "PostgreSQL HBA configuration file not found: $pg_hba"
fi

# shared_preload_libraries — handles both commented (#) and uncommented forms
if ! sudo sed -i "s/^#\?shared_preload_libraries.*/shared_preload_libraries = 'timescaledb'/" "$pg_conf"; then
    error_exit "Failed to configure shared_preload_libraries"
fi

if ! sudo sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/" "$pg_conf"; then
    error_exit "Failed to configure listen_addresses"
fi

# pg_hba.conf — local peer -> trust  (no-op if already trust)
if ! sudo sed -i '/^local.*peer/s/peer/trust/g' "$pg_hba"; then
    error_exit "Failed to configure pg_hba.conf for local connections"
fi

# pg_hba.conf — widen host access  (only matches if 127.0.0.1/32 is still present)
if ! sudo sed -i '/^host[[:space:]]*all[[:space:]]*all[[:space:]]*127\.0\.0\.1\/32/s/127\.0\.0\.1\/32/0.0.0.0\/0/' "$pg_hba"; then
    error_exit "Failed to configure pg_hba.conf for host connections"
fi

# Ensure cluster is running with new config
if ! run_with_sudo pg_ctlcluster "${PG_MAJOR}" main restart; then
    warning_msg "Cluster restart failed. Attempting fresh start..."
    run_with_sudo pg_ctlcluster "${PG_MAJOR}" main start || true
    sleep 3
fi

# Wait for PostgreSQL to accept connections (up to 15 seconds)
pg_ready=false
for _attempt in $(seq 1 15); do
    if sudo -u postgres psql -d postgres -c "SELECT 1;" &>/dev/null; then
        pg_ready=true
        break
    fi
    sleep 1
done

if [[ "$pg_ready" != "true" ]]; then
    warning_msg "psql client connection failed. Recent PostgreSQL logs:"
    run_with_sudo journalctl -u postgresql --no-pager -n 50 || true
    error_exit "psql client connection failed! Check postgresql.conf / pg_hba.conf"
fi

# Set postgres password (idempotent ALTER)
sudo -u postgres psql -c "ALTER USER postgres WITH ENCRYPTED PASSWORD 'hotandcold'"

# --- 4c: Database user configuration ---
info_msg "Database User Setup"
info_msg "We're going to create a new database user."

info_msg "Username"
if [[ -n "${DB_USERNAME:-}" ]]; then
    :
elif [[ -t 0 ]]; then
    if [[ -r /dev/tty ]]; then
        printf '%b' "${BLUE}Press ENTER to use the default username [rmtest] or type a new username: ${NC}" > /dev/tty
        read -r _db_user_input < /dev/tty
    else
        read -r -p "$(printf '%b' "${BLUE}Press ENTER to use the default username [rmtest] or type a new username: ${NC}")" _db_user_input
    fi
    DB_USERNAME="${_db_user_input:-rmtest}"
else
    DB_USERNAME="${DB_USERNAME:-rmtest}"
fi

info_msg "Password"
if [[ -n "${DB_PASSWORD:-}" ]]; then
    :
elif [[ -t 0 ]]; then
    unset _db_pass_input
    if [[ -r /dev/tty ]]; then
        printf '%b' "${BLUE}Press ENTER to use the default password [hotandcold] or type a new password: ${NC}" > /dev/tty
        read -r -s _db_pass_input < /dev/tty
        echo > /dev/tty
    else
        printf '%b' "${BLUE}Press ENTER to use the default password [hotandcold] or type a new password: ${NC}" >&2
        read -r -s _db_pass_input
        echo >&2
    fi
    _db_pass_input="${_db_pass_input//$'\r'/}"
    if [[ -z "${_db_pass_input}" ]]; then
        DB_PASSWORD="hotandcold"
    else
        DB_PASSWORD="${_db_pass_input}"
    fi
else
    DB_PASSWORD="${DB_PASSWORD:-hotandcold}"
fi

export DB_USERNAME DB_PASSWORD

create_postgres_role() {
    local role_name="$1"
    local role_password="$2"

    info_msg "+++++++++++ Creating / Verifying Role: $role_name ++++++++++"

    if ! sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT FROM pg_roles WHERE rolname = '$role_name'
    ) THEN
        EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '$role_name', '$role_password');
    END IF;
    EXECUTE format(
        'ALTER ROLE %I WITH LOGIN SUPERUSER CREATEDB CREATEROLE REPLICATION PASSWORD %L',
        '$role_name',
        '$role_password'
    );
END;
\$\$;
EOF
    then
        error_exit "Failed to create role $role_name"
    fi

    local role_check
    role_check=$(sudo -u postgres psql -t -A <<EOF
SELECT
    rolname,
    rolcanlogin,
    rolsuper,
    rolcreatedb,
    rolcreaterole,
    rolreplication,
    rolpassword IS NOT NULL
FROM pg_authid
WHERE rolname = '$role_name';
EOF
)

    if [[ -z "$role_check" ]]; then
        error_exit "Role $role_name does not exist after creation"
    fi

    IFS='|' read -r name can_login is_superuser can_createdb can_createrole can_replication password_set <<< "$role_check"

    if [[ "$can_login" != "t" ]]; then
        error_exit "Role $role_name exists but LOGIN is disabled"
    fi

    if [[ "$is_superuser" != "t" || "$can_createdb" != "t" || "$can_createrole" != "t" || "$can_replication" != "t" ]]; then
        error_exit "Role $role_name does not have required privileges"
    fi

    if [[ "$password_set" != "t" ]]; then
        error_exit "Password not set for role $role_name"
    fi

    success_msg "Role '$role_name' verified (Login + password OK)"
}

create_postgres_role "$DB_USERNAME" "$DB_PASSWORD"

echo "====== Configured PostgreSQL Users list: ======" && sudo -u postgres psql -t -c "SELECT rolname FROM pg_roles WHERE rolcanlogin = true ORDER BY rolname;" 2>/dev/null | awk '{$1=$1};1' | nl -w2 -s'. '

success_msg "========== PostgreSQL configuration completed successfully =========="

################################################################################
# Phase 5 - pgAgent installation + configuration
################################################################################

if command_exists pgagent; then
    success_msg "========== Pgagent is already installed =========="
else
    info_msg "========== Pgagent installation started... =========="

    install_debs_from_dir "postgresql-${PG_MAJOR}-pgagent" "${DEBS_DIR}/postgres"

    if ! sudo -u postgres psql -c "CREATE EXTENSION IF NOT EXISTS pgagent;" 2>/dev/null; then
        warning_msg "pgagent extension may already exist or failed to create"
    fi

    if ! sudo mkdir -p /var/log/pgagent; then
        error_exit "Failed to create pgagent log directory"
    fi

    if ! sudo chown -R postgres:postgres /var/log/pgagent; then
        error_exit "Failed to set ownership for pgagent log directory"
    fi

    if ! sudo chmod g+w /var/log/pgagent; then
        warning_msg "Failed to set permissions for pgagent log directory"
    fi

    success_msg "========== Pgagent installed successfully =========="

    pg_hba_file="${pg_hba:-/etc/postgresql/${PG_MAJOR}/main/pg_hba.conf}"
    if [[ ! -f "$pg_hba_file" ]]; then
        error_exit "PostgreSQL HBA configuration file not found: $pg_hba_file"
    fi

    if ! sudo sed -i '/^local.*trust/s/trust/md5/g' "$pg_hba_file"; then
        error_exit "Failed to configure pg_hba.conf for local connections"
    fi

    if ! run_with_sudo pg_ctlcluster "${PG_MAJOR}" main restart; then
        warning_msg "Cluster restart failed after pgagent setup. Recent PostgreSQL logs:"
        run_with_sudo journalctl -u postgresql --no-pager -n 50 || true
        error_exit "Failed to restart PostgreSQL cluster ${PG_MAJOR}/main after pgagent setup"
    fi
fi

# ---------- .pgpass ----------
SERVICE_FILE="/etc/systemd/system/pgagent.service"

pgpass_password="${POSTGRES_PASSWORD:-hotandcold}"
info_msg "Setting up .pgpass for postgres user..."
if ! sudo -u postgres bash -c "
    if [[ -f ~/.pgpass ]]; then
        echo '.pgpass already exists. Deleting the old file...'
        rm -f ~/.pgpass
    fi
    touch ~/.pgpass
    chmod 600 ~/.pgpass
    echo '127.0.0.1:5432:*:postgres:${pgpass_password}' >> ~/.pgpass
    echo '.pgpass file created successfully.'
"; then
    error_exit "Failed to create .pgpass file"
fi

# ---------- pgagent systemd service ----------
OVERWRITE_SERVICE="True"

if [[ "$OVERWRITE_SERVICE" == "True" ]]; then
    PGAGENT_SERVICE_SRC="${SCRIPT_DIR}/pgagent.service"
    if [[ ! -f "$PGAGENT_SERVICE_SRC" ]]; then
        PGAGENT_SERVICE_SRC="pgagent.service"
    fi
    if [[ ! -f "$PGAGENT_SERVICE_SRC" ]]; then
        warning_msg "pgagent.service file not found. Skipping service setup."
    else
        info_msg "Creating pgAgent systemd service file..."
        if ! sudo cp "$PGAGENT_SERVICE_SRC" /etc/systemd/system/; then
            error_exit "Failed to copy pgagent service file"
        fi

        info_msg "Reloading systemd daemon..."
        if ! sudo systemctl daemon-reload; then
            error_exit "Failed to reload systemd daemon"
        fi

        info_msg "Enabling and starting pgAgent service..."
        if ! sudo systemctl enable pgagent.service; then
            error_exit "Failed to enable pgagent service"
        fi

        if ! sudo systemctl start pgagent.service; then
            error_exit "Failed to start pgagent service"
        fi

        sudo systemctl status pgagent.service --no-pager || true

        success_msg "pgAgent service setup completed successfully!"
    fi
fi

################################################################################
# Phase 6 - Database restore
################################################################################

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    restore_database_backups "$@"
fi

################################################################################
# Phase 7 - Node.js installation
################################################################################

if command_exists node; then
    node_version_info=$(node -v 2>/dev/null || true)
    if [[ -n "$node_version_info" ]]; then
        success_msg "============ Already node installed with version: $node_version_info =============="
    else
        success_msg "Already node installed (version unknown)"
    fi
else
    info_msg "========== Node.js installation started... =========="

    install_debs_from_dir "Node.js 20.x + runtime dependencies" "${DEBS_DIR}/node"

    if command_exists node; then
        success_msg "========== Node.js installed successfully =========="
        node -v

        info_msg "All Node.js runtime libraries installed from offline bundle."
    else
        error_exit "========== Node.js not installed =========="
    fi
fi

################################################################################
# Phase 8 - rmontmp directory
################################################################################

info_msg "========== Creating rmontmp directory for RMON Gateway Software If not exists !=========="

if [[ ! -d "$HOME/rmontmp" ]]; then
    if ! mkdir -p "$HOME/rmontmp"; then
        error_exit "Failed to create rmontmp directory"
    fi
    info_msg "Created rmontmp directory successfully."
else
    info_msg "Directory $HOME/rmontmp already exists, skipping creation."
fi

################################################################################
# Phase 9 - pgAgent jobs configuration
################################################################################

echo ""
echo -e "${BLUE}${BOLD}========================================${NC}"
echo -e "${BLUE}${BOLD}   PgAgent Jobs Configuration Check    ${NC}"
echo -e "${BLUE}${BOLD}========================================${NC}"

declare -A JOB_SQL_MAPPING=(
    ["DataProcessorFor5days"]="DataProcessorFor5days@pg.sql"
    ["DeleteOldHistoryData"]="DeleteOldHistoryData@pg.sql"
    ["future_partition_creator"]="future_partition_creator@pg.sql"
)

SCRIPT_HOME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG_JOB_SCRIPTS_DIR="${SCRIPT_HOME_DIR}/pg_job_scripts"
if [[ ! -d "$PG_JOB_SCRIPTS_DIR" ]]; then
    PG_JOB_SCRIPTS_DIR="pg_job_scripts"
fi

rm -f modified_*.sql 2>/dev/null || true

if ! command_exists psql; then
    error_exit "psql command not found. PostgreSQL must be installed first."
fi

if ! psql -V 2>/dev/null | grep -q "13"; then
    error_exit "PostgreSQL version 13 not found. Please install the correct version."
fi

PGUSER="${PGUSER:-postgres}"
PASSWORD="${POSTGRES_PASSWORD:-hotandcold}"
export PGPASSWORD="$PASSWORD"

get_database_list() {
    PGPASSWORD="$PASSWORD" psql -U "$PGUSER" -d postgres -t -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false;" 2>/dev/null | awk '{$1=$1};1' | grep -v '^$'
}

job_exists() {
    local job_name="$1"
    local exists
    exists=$(PGPASSWORD="$PASSWORD" psql -U "$PGUSER" -d postgres -t -A -c \
        "SELECT EXISTS(SELECT 1 FROM pgagent.pga_job WHERE jobname = '$job_name');" 2>/dev/null | tr -d '[:space:]')

    [[ "$exists" == "t" ]]
}

ensure_pgagent_extension() {
    if ! PGPASSWORD="$PASSWORD" psql -U "$PGUSER" -d postgres -t -A -c "SELECT 1;" >/dev/null 2>&1; then
        error_exit "Unable to connect to PostgreSQL with provided credentials for pgAgent jobs setup."
    fi

    if PGPASSWORD="$PASSWORD" psql -U "$PGUSER" -d postgres -t -A -c \
        "SELECT 1 FROM pg_extension WHERE extname = 'pgagent';" 2>/dev/null | grep -q "1"; then
        return 0
    fi

    warning_msg "pgAgent extension not found in postgres database. Attempting auto-fix..."

    if ! PGPASSWORD="$PASSWORD" psql -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 -c \
        "CREATE EXTENSION IF NOT EXISTS pgagent;" >/dev/null 2>&1; then
        warning_msg "CREATE EXTENSION failed for user '$PGUSER'. Trying install fallback..."

        install_debs_best_effort "pgagent-extension-fallback" "${DEBS_DIR}/postgres"

        if ! sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c \
            "CREATE EXTENSION IF NOT EXISTS pgagent;" >/dev/null 2>&1; then
            return 1
        fi
    fi

    PGPASSWORD="$PASSWORD" psql -U "$PGUSER" -d postgres -t -A -c \
        "SELECT 1 FROM pg_extension WHERE extname = 'pgagent';" 2>/dev/null | grep -q "1"
}

if ensure_pgagent_extension; then
    echo ""
    info_msg "Checking PgAgent jobs status..."
    echo "-------------------------------------------"

    jobs_found=()
    jobs_missing=()

    for job_name in "${!JOB_SQL_MAPPING[@]}"; do
        if job_exists "$job_name"; then
            jobs_found+=("$job_name")
            echo -e "  ${GREEN}✓${NC} $job_name"
        else
            jobs_missing+=("$job_name")
            echo -e "  ${RED}✗${NC} $job_name ${RED}(NOT FOUND)${NC}"
        fi
    done

    echo "-------------------------------------------"
    echo ""
    info_msg "Summary:"
    success_msg "  Jobs configured: ${#jobs_found[@]}/${#JOB_SQL_MAPPING[@]}"

    if [[ ${#jobs_missing[@]} -gt 0 ]]; then
        warning_msg "  Jobs missing: ${#jobs_missing[@]}"
        echo ""

        if [[ ! -d "$PG_JOB_SCRIPTS_DIR" ]]; then
            error_exit "Directory '$PG_JOB_SCRIPTS_DIR' not found. Cannot create missing jobs. Current directory: $(pwd)"
        fi

        info_msg "Select a database for {{DB_NAME}} replacement in SQL scripts:"
        echo ""

        DB_LIST=($(get_database_list))

        if [[ ${#DB_LIST[@]} -eq 0 ]]; then
            error_exit "No databases found. Cannot configure pgAgent jobs."
        fi

        APP_DB_LIST=()
        for db in "${DB_LIST[@]}"; do
            if [[ "$db" != "postgres" ]]; then
                APP_DB_LIST+=("$db")
            fi
        done

        if [[ ${#APP_DB_LIST[@]} -eq 0 ]]; then
            error_exit "Only maintenance database 'postgres' is available. Cannot configure pgAgent jobs."
        elif [[ ${#APP_DB_LIST[@]} -eq 1 ]]; then
            WORKING_DB="${APP_DB_LIST[0]}"
            info_msg "Only one application database found. Auto-selected: $WORKING_DB"
        else
            echo "Available application databases:"
            select WORKING_DB in "${APP_DB_LIST[@]}"; do
                if [[ -n "$WORKING_DB" ]]; then
                    info_msg "Selected database: $WORKING_DB"
                    break
                else
                    warning_msg "Invalid selection. Please try again."
                fi
            done
        fi

        echo ""
        info_msg "Creating missing pgAgent jobs..."
        echo "-------------------------------------------"

        FUNC_SCRIPT="$PG_JOB_SCRIPTS_DIR/functionpartition.sql"
        if [[ -f "$FUNC_SCRIPT" ]]; then
            info_msg "Executing prerequisite: functionpartition.sql on $WORKING_DB"
            TEMP_SQL="modified_functionpartition.sql"

            sed "s/{{DB_NAME}}/$WORKING_DB/g" "$FUNC_SCRIPT" > "$TEMP_SQL"

            if [[ ! -f "$TEMP_SQL" ]] || [[ ! -s "$TEMP_SQL" ]]; then
                warning_msg "Failed to create or temp SQL file is empty: $TEMP_SQL"
                rm -f "$TEMP_SQL"
            else
                if PGPASSWORD="$PASSWORD" psql -U "$PGUSER" -d "$WORKING_DB" -f "$TEMP_SQL" 2>&1; then
                    success_msg "Executed: functionpartition.sql"
                else
                    warning_msg "Error executing: functionpartition.sql (check psql output above)"
                fi
                rm -f "$TEMP_SQL"
            fi
            echo "-------------------------------------------"
        fi

        for job_name in "${jobs_missing[@]}"; do
            SQL_FILE="${JOB_SQL_MAPPING[$job_name]}"
            SQL_PATH="$PG_JOB_SCRIPTS_DIR/$SQL_FILE"

            if [[ ! -f "$SQL_PATH" ]]; then
                warning_msg "SQL file not found: $SQL_PATH - Skipping job '$job_name'"
                continue
            fi

            info_msg "Processing: $SQL_FILE (Job: $job_name)"

            DEFAULT_DB="postgres"
            if [[ "$SQL_FILE" != *"@pg"* ]]; then
                DEFAULT_DB="$WORKING_DB"
            fi

            TEMP_SQL="modified_$SQL_FILE"

            sed "s/{{DB_NAME}}/$WORKING_DB/g" "$SQL_PATH" > "$TEMP_SQL"

            if [[ ! -f "$TEMP_SQL" ]] || [[ ! -s "$TEMP_SQL" ]]; then
                warning_msg "Failed to create or temp SQL file is empty: $TEMP_SQL"
                rm -f "$TEMP_SQL"
                continue
            fi

            if PGPASSWORD="$PASSWORD" psql -U "$PGUSER" -d "$DEFAULT_DB" -f "$TEMP_SQL" 2>&1; then
                success_msg "Created job '$job_name' on database: $DEFAULT_DB"
            else
                warning_msg "Error creating job '$job_name' from: $SQL_FILE (check psql output above)"
            fi

            rm -f "$TEMP_SQL"
            echo "-------------------------------------------"
        done

        success_msg "PgAgent jobs configuration completed!"
    else
        success_msg "All pgAgent jobs are configured!"
    fi
    echo "-------------------------------------------"
else
    warning_msg "pgAgent extension could not be initialized. Skipping job checks."
fi

################################################################################
# Phase 10 - Security Configuration
################################################################################

    echo -e "${RED}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║              IMPORTANT WARNING                            ║${NC}"
    echo -e "${RED}${BOLD}║                                                            ║${NC}"
    echo -e "${RED}${BOLD}║   Security Configuration takes approximately 30+ minutes  ║${NC}"
    echo -e "${RED}${BOLD}║   Do NOT interrupt the process once started!              ║${NC}"
    echo -e "${RED}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    IS_WSL=false
    if grep -qEi "(Microsoft|WSL)" /proc/version &>/dev/null; then
        IS_WSL=true
    fi

    SECURITY_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/security_scripts"
    SCRIPT_DIRS_SEC=()

    if [[ "$IS_WSL" == "true" ]]; then
        SCRIPT_DIRS_SEC+=("${SECURITY_BASE_DIR}/ubuntu-server/For_windows_wsl")
    else
        SCRIPT_DIRS_SEC+=("${SECURITY_BASE_DIR}/ubuntu-server" "${SECURITY_BASE_DIR}/postgres-db")
    fi

    LOG_FILE="security_script_status.log"
    FAILED_SCRIPTS=()
    SKIP_SECURITY_SCRIPTS=("install_aide.sh" "install_pgaudit.sh")

    success_msg "========== Starting Security Configuration ==========" | tee "$LOG_FILE"

    for SEC_DIR in "${SCRIPT_DIRS_SEC[@]}"; do
        echo "Processing scripts in: $SEC_DIR" | tee -a "$LOG_FILE"

        if [[ ! -d "$SEC_DIR" ]]; then
            warning_msg "WARNING: Directory $SEC_DIR does not exist. Skipping." | tee -a "$LOG_FILE"
            continue
        fi

        sudo chmod +x "$SEC_DIR"/*.sh 2>/dev/null || true

        for script in "$SEC_DIR"/*.sh; do
            [[ -f "$script" ]] || continue

            script_name=$(basename "$script")
            if [[ " ${SKIP_SECURITY_SCRIPTS[*]} " == *" $script_name "* ]]; then
                continue
            fi

            info_msg "Running $script..." | tee -a "$LOG_FILE"

            if ! sudo bash "$script" >> "$LOG_FILE" 2>&1; then
                error_exit "ERROR: $script failed." | tee -a "$LOG_FILE"
                FAILED_SCRIPTS+=("$script")
            else
                success_msg "$script completed successfully." | tee -a "$LOG_FILE"
            fi
        done
    done

    if [[ ${#FAILED_SCRIPTS[@]} -ne 0 ]]; then
        error_exit "Some scripts failed. Check $LOG_FILE for details."
    else
        success_msg "All scripts ran successfully." | tee -a "$LOG_FILE"
    fi

rm -f modified_*.sql 2>/dev/null || true

################################################################################
# Phase 11 - Verify all critical services and create STATE file
################################################################################

RMEYE_STATE_FILE="/opt/rmeye/state.env"
RMEYE_STATE_DIR="/opt/rmeye"

verify_and_create_state_file() {
    local all_ok=true
    local missing=()
    local state_file_action="created"

    if ! command_exists psql; then
        all_ok=false
        missing+=("postgres")
    fi

    if ! command_exists nginx; then
        all_ok=false
        missing+=("nginx")
    fi

    if ! command_exists dotnet; then
        all_ok=false
        missing+=("dotnet")
    fi

    if ! command_exists node; then
        all_ok=false
        missing+=("node")
    fi

    if [[ "$all_ok" != "true" ]]; then
        warning_msg "Cannot create state file: missing services: ${missing[*]}"
        return 1
    fi

    if [[ ! -d "$RMEYE_STATE_DIR" ]]; then
        if ! run_with_sudo mkdir -p "$RMEYE_STATE_DIR"; then
            error_exit "Failed to create $RMEYE_STATE_DIR"
        fi
        run_with_sudo chmod 755 "$RMEYE_STATE_DIR"
    fi

    local services_list="postgres,nginx,dotnet,node,pgagent"
    if command_exists pgagent; then
        :
    else
        services_list="postgres,nginx,dotnet,node"
    fi

    local deployed_at
    deployed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if [[ -f "$RMEYE_STATE_FILE" ]]; then
        state_file_action="updated"
    fi

    local state_content="SERVICES=${services_list}
DEPLOYED_AT=${deployed_at}
"
    if ! echo "$state_content" | run_with_sudo tee "$RMEYE_STATE_FILE" > /dev/null; then
        error_exit "Failed to write state file: $RMEYE_STATE_FILE"
    fi
    run_with_sudo chmod 644 "$RMEYE_STATE_FILE"

    success_msg "State file ${state_file_action}: $RMEYE_STATE_FILE"
    return 0
}

verify_and_create_state_file || true

success_msg "::::::::---:::::::-----> RMEYE application env setup completed successfully! <------::::::::---:::::::"
info_msg "========== kindly requested to update the status into checklist excel, if this is customer deployment! =========="
