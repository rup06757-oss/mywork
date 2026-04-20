#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$SCRIPT_DIR/restore_shared_payload.sh" ]; then
  "$SCRIPT_DIR/restore_shared_payload.sh"
fi


# State file for single-click installation flow
RMEYE_STATE_FILE="/opt/rmeye/state.env"
RMEYE_STATE_DIR="/opt/rmeye"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_SETUP_SCRIPT="${SCRIPT_DIR}/RM_online_install/RMEYE_env_setup.sh"

run_privileged() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

check_state_file() {
    [[ -f "$RMEYE_STATE_FILE" ]]
}

check_core_services_installed() {
    command -v psql &>/dev/null &&
    command -v nginx &>/dev/null &&
    command -v dotnet &>/dev/null &&
    command -v node &>/dev/null &&
    command -v pgagent &>/dev/null
}

check_user_databases_present() {
    local pg_user="${PGUSER:-postgres}"
    local pg_password="${POSTGRES_PASSWORD:-hotandcold}"
    local db_count

    db_count=$(PGPASSWORD="$pg_password" psql -U "$pg_user" -d postgres -t -A -c \
        "SELECT COUNT(*) FROM pg_database WHERE datname NOT IN ('template0','template1','postgres') AND datistemplate = false;" 2>/dev/null | tr -d '[:space:]')
    [[ "$db_count" =~ ^[0-9]+$ ]] || return 1
    (( db_count > 0 ))
}

check_pgagent_jobs_present() {
    local required_jobs=(
        "DataProcessorFor5days"
        "DeleteOldHistoryData"
        "future_partition_creator"
    )
    local pg_user="${PGUSER:-postgres}"
    local pg_password="${POSTGRES_PASSWORD:-hotandcold}"
    local job_name=""
    local exists=""

    for job_name in "${required_jobs[@]}"; do
        exists=$(PGPASSWORD="$pg_password" psql -U "$pg_user" -d postgres -t -A -c \
            "SELECT EXISTS(SELECT 1 FROM pgagent.pga_job WHERE jobname = '$job_name');" 2>/dev/null | tr -d '[:space:]')
        [[ "$exists" == "t" ]] || return 1
    done

    return 0
}

create_state_file_for_existing_setup() {
    local state_file_action="created"
    local services_list="postgres,nginx,dotnet,node"
    if command -v pgagent &>/dev/null; then
        services_list="postgres,nginx,dotnet,node,pgagent"
    fi

    if check_state_file; then
        state_file_action="updated"
    fi

    run_privileged mkdir -p "$RMEYE_STATE_DIR"
    run_privileged chmod 755 "$RMEYE_STATE_DIR"
    run_privileged tee "$RMEYE_STATE_FILE" > /dev/null <<EOF
SERVICES=${services_list}
EOF
    run_privileged chmod 644 "$RMEYE_STATE_FILE"
    echo "State file ${state_file_action}: $RMEYE_STATE_FILE"
}

check_rmon_installed() {
    if command -v vers-rmon &>/dev/null; then
        vers-rmon &>/dev/null && return 0
    fi
    return 1
}

run_env_setup() {
    echo "Environment not configured. Running RMEYE environment setup..."
    if [[ ! -f "$ENV_SETUP_SCRIPT" ]]; then
        echo "ERROR: Environment setup script not found: $ENV_SETUP_SCRIPT"
        exit 1
    fi
    if ! bash "$ENV_SETUP_SCRIPT"; then
        echo "Environment setup failed. Please fix the errors above and re-run: ./linux.install_final.sh"
        exit 1
    fi
    echo "Environment setup completed successfully."
    echo "Please install RMON if not exists and re run the script linux.install_final.sh for RMEYE build."
    exit 0
}

# Single-click flow: check state file first
if check_state_file; then
    if ! check_core_services_installed || ! check_user_databases_present || ! check_pgagent_jobs_present; then
        echo "State file exists but environment is incomplete (missing required services or pgAgent jobs, or Database Restoration). Running environment setup..."
        run_env_setup
    fi
else
    if check_core_services_installed && check_user_databases_present && check_pgagent_jobs_present; then
        create_state_file_for_existing_setup
    else
        echo "Existing environment is incomplete (missing required services or pgAgent jobs, or Database Restoration). Running environment setup..."
        run_env_setup
    fi
fi

# State exists: verify RMON is installed before build
if ! check_rmon_installed; then
    echo "Please install RMON if not exists and re-run: ./linux.install_final.sh"
    exit 1
fi

# State exists and RMON installed: proceed with build installation
echo "Environment configured. RMON detected. Proceeding with build installation..."

refreshPermissions () {
    local pid="${1}"
    while kill -0 "${pid}" 2> /dev/null; do
        sudo -v
        sleep 10
    done
}

# Expand "~/" in file paths (because "~" won't expand when quoted)
expand_tilde_path() {
    local path="$1"
    local home="$2"

    [[ -z "$path" ]] && echo "" && return

    # Replace /~/ or ~/ anywhere with home
    path="${path//\/~\//\/}"
    path="${path/#~\//$home/}"

    # Handle ~username/
    if [[ "$path" =~ ^~([^/]+)/ ]]; then
        local u="${BASH_REMATCH[1]}"
        local uh
        uh="$(getent passwd "$u" | cut -d: -f6)"
        [[ -n "$uh" ]] && path="${path/#~$u/$uh}"
    fi

    echo "$path"
}

# # Sync a backup file with the corresponding file from the *build folder* before copying.
# # Rules:
# # - For JSON: merge build(JSON) + backup(JSON) so backup values win, but new build keys are added to backup
# # - For config.js: insert any missing keys from build config.js into backup config.js (keep backup values)
# sync_backup_file_with_build() {
#     local backup_src="$1"     # backup file path (source in filesTobeCp.txt)
#     local dest_path="$2"      # destination path from filesTobeCp.txt
#     local build_root="$3"     # build folder root (pwd where script is run)
#     local home="$4"           # resolved home path

#     if [[ -z "$backup_src" || -z "$dest_path" || -z "$build_root" ]]; then
#         return 0
#     fi

#     local src_exp dest_exp
#     src_exp="$(expand_tilde_path "$backup_src" "$home")"
#     dest_exp="$(expand_tilde_path "$dest_path" "$home")"

#     # Only sync when both are files
#     if [[ ! -f "$src_exp" ]]; then
#         return 0
#     fi

#     local build_rel=""
#     if [[ "$dest_exp" == /var/www/* ]]; then
#         build_rel="${dest_exp#/var/www/}"
#     elif [[ "$dest_exp" == /srv/* ]]; then
#         build_rel="${dest_exp#/srv/}"
#     else
#         return 0
#     fi

#     local build_file="${build_root}/${build_rel}"
#     if [[ ! -f "$build_file" ]]; then
#         return 0
#     fi

#     # JSON merge
#     if [[ "$src_exp" == *.json && "$build_file" == *.json ]]; then
#         if command -v python3 >/dev/null 2>&1 && [[ -f "${build_root}/external_scripts/backup_json_updator.py" ]]; then
#             python3 "${build_root}/external_scripts/backup_json_updator.py" \
#                 --current "$src_exp" --new "$build_file" --inplace 2>/dev/null || {
#                 refreshPermissions "$$" & sudo python3 "${build_root}/external_scripts/backup_json_updator.py" \
#                     --current "$src_exp" --new "$build_file" --inplace 2>/dev/null || true
#             }
#         fi
#         return 0
#     fi

#     # config.js merge
#     if [[ "$(basename "$src_exp")" == "config.js" && "$(basename "$build_file")" == "config.js" ]]; then
#         if command -v python3 >/dev/null 2>&1 && [[ -f "${build_root}/external_scripts/config_js_merger.py" ]]; then
#             python3 "${build_root}/external_scripts/config_js_merger.py" \
#                 --current "$src_exp" --new "$build_file" --inplace 2>/dev/null || {
#                 refreshPermissions "$$" & sudo python3 "${build_root}/external_scripts/config_js_merger.py" \
#                     --current "$src_exp" --new "$build_file" --inplace 2>/dev/null || true
#             }
#         fi
#         return 0
#     fi
# }

copy_specific_files_from_list() {
    local file_path="$1"
    local build_root="$2"
    local user_name="$3"
    local home

    home="$(getent passwd "$user_name" | cut -d: -f6)"

    [[ ! -f "$file_path" ]] && return 0

    if [[ ! -s "$file_path" ]]; then
        echo "⚠️ $file_path is empty, Assuming no backupfiles are present"
        return 0
    fi

    while IFS=: read -r src dest || [[ -n "$src" ]]; do
        # Trim whitespace
        src="$(echo "$src" | xargs)"
        dest="$(echo "$dest" | xargs)"

        # Skip blanks and comments
        [[ -z "$src" || -z "$dest" || "$src" == \#* ]] && continue

        # Expand ~ paths
        src="$(expand_tilde_path "$src" "$home")"
        dest="$(expand_tilde_path "$dest" "$home")"

        # Validate source
        if [[ ! -e "$src" ]]; then
            echo "⚠️  Source not found: $src"
            continue
        fi

        # Validate destination directory (STRICT)
        dest_dir="$(dirname "$dest")"
        if [[ ! -d "$dest_dir" ]]; then
            echo "❌ Destination directory does not exist: $dest_dir"
            continue
        fi

        # # Copy with visibility
        # echo "📂 Copying: $src → $dest"

        refreshPermissions "$$" &
        PID=$!

        if sudo cp -r "$src" "$dest"; then
            echo "✅ Copied successfully: $(basename "$src")"
        else
            echo "❌ Failed to copy from $src to $dest"
        fi

        kill "$PID" 2>/dev/null || true

    done < "$file_path"
}

# ============================================================================
# PATRONI INSTALLATION FUNCTIONS (for redundancy setup)
# ============================================================================

check_patroni_prerequisites() {
    echo -e "\n\033[1;33m🔍 Checking Patroni prerequisites...\033[0m"

    local errors=0

    if ! command -v psql &> /dev/null; then
        echo -e "\033[91m❌ PostgreSQL client (psql) not found\033[0m"
        ((errors++))
    else
        echo -e "\033[92m✅ PostgreSQL client found\033[0m"
    fi

    if ! command -v pg_ctl &> /dev/null && ! ls /usr/lib/postgresql/*/bin/pg_ctl &> /dev/null; then
        echo -e "\033[91m❌ PostgreSQL server not found\033[0m"
        ((errors++))
    else
        echo -e "\033[92m✅ PostgreSQL server found\033[0m"
    fi

    if systemctl list-unit-files | grep -q "postgresql"; then
        echo -e "\033[92m✅ PostgreSQL service exists\033[0m"

        if systemctl is-active --quiet postgresql; then
            echo -e "\033[92m✅ PostgreSQL service is running\033[0m"
        else
            echo -e "\033[93m⚠️  PostgreSQL service is not running - attempting to start...\033[0m"
            sudo systemctl start postgresql
            sleep 2
            if systemctl is-active --quiet postgresql; then
                echo -e "\033[92m✅ PostgreSQL service started successfully\033[0m"
            else
                echo -e "\033[91m❌ Failed to start PostgreSQL service\033[0m"
                ((errors++))
            fi
        fi
    else
        echo -e "\033[91m❌ PostgreSQL service not found\033[0m"
        ((errors++))
    fi

    if [[ -n "$DbPassword" && -n "$dbMachineIp" && -n "$DbName" ]]; then
        echo "Testing database connectivity..."
        if PGPASSWORD="$DbPassword" psql -h "$dbMachineIp" -U "${DbUsername:-postgres}" -d "$DbName" -c "SELECT 1;" &> /dev/null; then
            echo -e "\033[92m✅ PostgreSQL database connection successful\033[0m"
        else
            echo -e "\033[93m⚠️  PostgreSQL database connection failed (may be normal for new setup)\033[0m"
        fi
    fi

    if ! command -v python3 &> /dev/null; then
        echo -e "\033[91m❌ Python3 not found (required for Patroni)\033[0m"
        ((errors++))
    else
        local python_version
        python_version=$(python3 --version 2>&1)
        echo -e "\033[92m✅ $python_version found\033[0m"
    fi

    if ! command -v pip3 &> /dev/null && ! python3 -m pip --version &> /dev/null 2>&1; then
        echo -e "\033[93m⚠️  pip3 not found - attempting offline installation...\033[0m"

        local pip_dir="external_scripts/pip"
        if [[ -d "$pip_dir" ]] && ls "$pip_dir"/*.deb &> /dev/null; then
            echo "Installing pip3 from offline packages..."
            sudo dpkg -i "$pip_dir"/*.deb 2>/dev/null || {
                sudo apt-get install -f -y 2>/dev/null
                sudo dpkg -i "$pip_dir"/*.deb 2>/dev/null
            }

            if command -v pip3 &> /dev/null || python3 -m pip --version &> /dev/null 2>&1; then
                echo -e "\033[92m✅ pip3 installed successfully from offline packages\033[0m"
            else
                echo -e "\033[91m❌ pip3 offline installation failed\033[0m"
                ((errors++))
            fi
        else
            echo -e "\033[91m❌ pip3 not found and no offline packages in $pip_dir\033[0m"
            echo -e "\033[93m   To prepare offline pip packages, run on a machine with internet:\033[0m"
            echo -e "\033[93m   mkdir -p services/pip && cd services/pip\033[0m"
            echo -e "\033[93m   apt-get download python3-pip python3-setuptools python3-wheel\033[0m"
            ((errors++))
        fi
    else
        echo -e "\033[92m✅ pip3 found\033[0m"
    fi

    if dpkg -l 2>/dev/null | grep -q "build-essential"; then
        echo -e "\033[92m✅ build-essential package found\033[0m"
    else
        echo -e "\033[93m⚠️  build-essential not found - installing...\033[0m"
        sudo apt-get update -qq
        sudo apt-get install -y build-essential python3-dev &> /dev/null || {
            echo -e "\033[91m❌ Failed to install build-essential (offline environment?)\033[0m"
            echo -e "\033[93m   Patroni may still work if all wheels are pre-built\033[0m"
        }
    fi

    if dpkg -l 2>/dev/null | grep -q "libpq-dev"; then
        echo -e "\033[92m✅ libpq-dev (PostgreSQL dev library) found\033[0m"
    else
        echo -e "\033[93m⚠️  libpq-dev not found - psycopg2-binary wheel should work\033[0m"
    fi

    if [[ $errors -gt 0 ]]; then
        echo -e "\033[91m❌ Patroni prerequisites check failed with $errors error(s)\033[0m"
        return 1
    fi

    echo -e "\033[92m✅ All Patroni prerequisites satisfied\033[0m"
    return 0
}

install_patroni_offline() {
    local packages_archive="$1"
    local install_dir="/tmp/patroni_install_$$"

    echo -e "\n\033[1;33m📦 Installing Patroni from offline packages...\033[0m"

    if [[ ! -f "$packages_archive" ]]; then
        echo -e "\033[91m❌ Patroni packages archive not found: $packages_archive\033[0m"
        return 1
    fi

    mkdir -p "$install_dir"

    echo "Extracting packages from $packages_archive..."
    if ! tar -xzf "$packages_archive" -C "$install_dir" 2>/dev/null; then
        echo -e "\033[91m❌ Failed to extract packages archive\033[0m"
        rm -rf "$install_dir"
        return 1
    fi

    local patroni_wheel
    patroni_wheel=$(find "$install_dir" -name "patroni*.whl" -type f 2>/dev/null | head -1)

    if [[ -z "$patroni_wheel" ]]; then
        echo -e "\033[91m❌ Patroni wheel file not found in archive\033[0m"
        rm -rf "$install_dir"
        return 1
    fi

    echo "Using Patroni wheel: $patroni_wheel"
    echo "================================================"
    echo "Installing Patroni and dependencies..."
    echo "================================================"

    local PIP_CMD="sudo python3 -m pip"

    if $PIP_CMD install --no-index --find-links="$install_dir" "$patroni_wheel" psycopg2-binary 2>&1; then
        echo -e "\033[92m✅ Patroni and psycopg2-binary installed successfully\033[0m"
    else
        echo -e "\033[93m⚠️  Full installation had issues, trying alternative method...\033[0m"

        $PIP_CMD install --no-index --find-links="$install_dir" --no-deps "$patroni_wheel" 2>&1 || true

        local deps=("click" "prettytable" "python-dateutil" "psutil" "redis" "urllib3" "PyYAML" "ydiff" "psycopg2-binary")
        local dep=""
        for dep in "${deps[@]}"; do
            echo "Installing $dep..."
            $PIP_CMD install --no-index --find-links="$install_dir" "$dep" 2>&1 || true
        done

        $PIP_CMD install --no-index --find-links="$install_dir" py-consul 2>&1 || true
        $PIP_CMD install --no-index --find-links="$install_dir" python-etcd 2>&1 || true
    fi

    echo -e "\n\033[1;33m🔍 Verifying Patroni installation...\033[0m"

    if command -v patroni &> /dev/null; then
        local patroni_version
        patroni_version=$(patroni --version 2>&1)
        echo -e "\033[92m✅ Patroni installed successfully: $patroni_version\033[0m"

        if command -v patronictl &> /dev/null; then
            echo -e "\033[92m✅ patronictl command available\033[0m"
        fi
    else
        if python3 -c "import patroni" &> /dev/null; then
            echo -e "\033[92m✅ Patroni module installed (may need PATH update)\033[0m"
            local patroni_loc
            patroni_loc=$(python3 -c "import patroni; print(patroni.__file__)" 2>/dev/null)
            echo "Patroni location: $patroni_loc"
        else
            echo -e "\033[91m❌ Patroni installation verification failed\033[0m"
            rm -rf "$install_dir"
            return 1
        fi
    fi

    if python3 -c "import psycopg2" &> /dev/null; then
        echo -e "\033[92m✅ psycopg2 module available\033[0m"
    else
        echo -e "\033[93m⚠️  psycopg2 not available - some Patroni features may not work\033[0m"
    fi

    rm -rf "$install_dir"
    return 0
}

setup_patroni_service() {
    echo -e "\n\033[1;33m⚙️  Setting up Patroni service...\033[0m"

    local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    local services_dir="$script_dir/services"

    if [[ -f "$services_dir/patroni.service" ]]; then
        sudo cp "$services_dir/patroni.service" /etc/systemd/system/
        echo -e "\033[92m✅ Patroni service file copied to /etc/systemd/system/\033[0m"
    else
        echo -e "\033[91m❌ patroni.service not found in services directory\033[0m"
        return 1
    fi

    if [[ -f "$services_dir/patroni.yml" && -s "$services_dir/patroni.yml" ]]; then
        sudo cp "$services_dir/patroni.yml" /etc/patroni.yml
        sudo chown postgres:postgres /etc/patroni.yml
        sudo chmod 640 /etc/patroni.yml
        echo -e "\033[92m✅ Patroni configuration copied to /etc/patroni.yml\033[0m"

        echo -e "\n\033[1;33m📝 Step 1: Fetching local hostname and IP address...\033[0m"

        local localHostName
        localHostName=$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]')
        local localIp="$Ip"

        if [[ -z "$localHostName" ]]; then
            echo -e "\033[93m⚠️  Could not read /etc/hostname. Please enter hostname manually.\033[0m"
            while true; do
                read -rp "  Enter LOCAL machine's hostname: " localHostName
                if [[ -n "$localHostName" ]]; then
                    break
                fi
                echo -e "\033[91m  Hostname cannot be empty.\033[0m"
            done
        fi

        if [[ -z "$localIp" ]]; then
            echo -e "\033[93m⚠️  Ip variable not set. Please enter local IP manually.\033[0m"
            while true; do
                read -rp "  Enter LOCAL machine's IP address: " localIp
                if [[ -n "$localIp" ]]; then
                    break
                fi
                echo -e "\033[91m  Local IP address cannot be empty.\033[0m"
            done
        fi

        echo -e "  Local hostname: \033[92m$localHostName\033[0m"
        echo -e "  Local IP: \033[92m$localIp\033[0m"

        echo -e "\n\033[1;33m📝 Step 2: Fetching peer hostname and IP address...\033[0m"

        local peerHostName=""
        if [[ -f "/var/www/eye.api/appsettings.json" ]]; then
            local secondary_redis
            secondary_redis=$(jq -r '.ConnectionStrings.SecondaryRedis // empty' /var/www/eye.api/appsettings.json 2>/dev/null)
            if [[ -n "$secondary_redis" ]]; then
                peerHostName="${secondary_redis%%:*}"
                echo -e "  Peer hostname (from appsettings.json): \033[92m$peerHostName\033[0m"
            fi
        fi

        if [[ -z "$peerHostName" ]]; then
            echo -e "\033[93m⚠️  Could not extract peer hostname from SecondaryRedis in appsettings.json\033[0m"
            while true; do
                read -rp "Enter PEER machine's hostname: " peerHostName
                [[ -n "$peerHostName" ]] && break
                echo -e "\033[91mPeer hostname cannot be empty.\033[0m"
            done
        fi

        local peerIp=""
        while true; do
            read -rp "  Enter PEER machine's IP address: " peerIp
            if [[ -n "$peerIp" ]]; then
                break
            fi
            echo -e "\033[91m  Peer IP address cannot be empty.\033[0m"
        done

        echo -e "  Peer IP: \033[92m$peerIp\033[0m"

        echo -e "\n\033[1;33m📝 Step 3-5: Updating /etc/hosts...\033[0m"

        sudo chattr -i /etc/hosts 2>/dev/null || true
        sudo cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
        echo -e "  ✅ Backed up /etc/hosts"

        sudo sed -i "/[[:space:]]${localHostName}$/d" /etc/hosts 2>/dev/null || true
        sudo sed -i "/[[:space:]]${peerHostName}$/d" /etc/hosts 2>/dev/null || true

        echo -e "  Adding host entries..."
        echo -e "127.0.0.1\t${localHostName}" | sudo tee -a /etc/hosts >/dev/null
        echo -e "    Added: 127.0.0.1\t${localHostName}"
        echo -e "${localIp}\t${localHostName}" | sudo tee -a /etc/hosts >/dev/null
        echo -e "    Added: ${localIp}\t${localHostName}"
        echo -e "${peerIp}\t${peerHostName}" | sudo tee -a /etc/hosts >/dev/null
        echo -e "    Added: ${peerIp}\t${peerHostName}"

        echo -e "\033[92m✅ /etc/hosts updated successfully\033[0m"
        sudo chattr +i /etc/hosts 2>/dev/null || true
        echo -e "\033[92m✅ /etc/hosts locked with chattr +i\033[0m"
        echo -e "\033[93m   To unlock later, run: sudo chattr -i /etc/hosts\033[0m"

        echo -e "\n\033[1;33m📝 Step 6: Updating patroni.yml with hostnames...\033[0m"
        echo -e "  This machine (ourHostName): \033[92m$localHostName\033[0m"
        echo -e "  Peer machine (peerHostName): \033[92m$peerHostName\033[0m"

        sudo sed -i "s/name: ourHostName/name: $localHostName/g" /etc/patroni.yml
        sudo sed -i "s/connect_address: ourHostName:/connect_address: $localHostName:/g" /etc/patroni.yml
        sudo sed -i "s/node_id: ourHostName/node_id: $localHostName/g" /etc/patroni.yml
        sudo sed -i "s/peer_redis_host: peerHostName/peer_redis_host: $peerHostName/g" /etc/patroni.yml
        sudo sed -i "s/^\\([ ]*\\)peerHostName:/\\1$peerHostName:/g" /etc/patroni.yml

        echo -e "\033[92m✅ Patroni configuration updated with hostnames\033[0m"

        echo -e "\n\033[1;33m📝 Step 7-8: Updating pg_hba.conf...\033[0m"

        local pg_hba_conf="/etc/postgresql/13/main/pg_hba.conf"
        if [[ ! -f "$pg_hba_conf" ]]; then
            echo -e "\033[91m❌ FATAL: pg_hba.conf not found at $pg_hba_conf\033[0m"
            echo -e "\033[91m   Cannot proceed with Patroni setup without pg_hba.conf\033[0m"
            return 1
        fi

        sudo cp "$pg_hba_conf" "${pg_hba_conf}.bak"
        echo -e "  ✅ Backed up pg_hba.conf to ${pg_hba_conf}.bak"

        local SUBNET_CIDR=""
        echo -e "  \033[93m💡 PostgreSQL requires an explicit subnet (CIDR) to allow remote access.\033[0m"
        echo -e "  \033[93m   Examples:\033[0m"
        echo -e "  \033[93m     192.168.60.0/24   (typical LAN)\033[0m"
        echo -e "  \033[93m     10.0.0.0/16       (corporate network)\033[0m"
        echo -e "  \033[93m     192.168.60.50/32  (single host)\033[0m"
        echo

        while true; do
            read -rp "  Enter allowed subnet in CIDR format (e.g., 192.168.60.0/24, 10.0.0.0/16, 192.168.60.50/32): " SUBNET_CIDR
            if [[ "$SUBNET_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
                break
            fi
            echo -e "\033[91m  ❌ Invalid CIDR format. Try again.\033[0m"
        done

        if [[ "$SUBNET_CIDR" == "0.0.0.0/0" ]]; then
            echo -e "\033[91m⚠️  WARNING: This allows access from ANY IP.\033[0m"
            read -rp "  Type YES to confirm: " CONFIRM
            [[ "$CONFIRM" == "YES" ]] || return 1
        fi

        echo -e "  ✅ Using subnet: $SUBNET_CIDR"
        echo -e "  Modifying existing replication entry..."

        if sudo grep -qE '^[[:space:]]*host[[:space:]]+replication[[:space:]]+all[[:space:]]+127\.0\.0\.1/32[[:space:]]+md5' "$pg_hba_conf"; then
            sudo sed -i \
                's/^\([[:space:]]*\)host[[:space:]]\+replication[[:space:]]\+all[[:space:]]\+127\.0\.0\.1\/32[[:space:]]\+md5/\1host    replication     all             0.0.0.0\/0               md5/' \
                "$pg_hba_conf"
            echo -e "    ✅ Modified replication entry"
        else
            echo -e "    ⚠️  Replication entry not found or already updated"
        fi

        echo -e "  Appending pg_hba.conf entries (if missing)..."

        append_if_missing() {
            local entry="$1"
            local comment="$2"

            if ! sudo grep -qF -- "$entry" "$pg_hba_conf"; then
                if [[ -n "$comment" ]]; then
                    echo "$entry $comment" | sudo tee -a "$pg_hba_conf" >/dev/null
                else
                    echo "$entry" | sudo tee -a "$pg_hba_conf" >/dev/null
                fi
                echo -e "    ✅ Added: $entry"
            else
                echo -e "    ⚠️  Exists: $entry"
            fi
        }

        append_if_missing "host replication postgres 127.0.0.1/32 md5" ""
        append_if_missing "host replication postgres $SUBNET_CIDR md5" "#User-defined subnet"
        append_if_missing "host all postgres 127.0.0.1/32 md5" ""
        append_if_missing "host all postgres $SUBNET_CIDR md5" "#User-defined subnet"
        append_if_missing "host all all $SUBNET_CIDR md5" "#User-defined subnet"
        append_if_missing "local all postgres peer" ""
        append_if_missing "local all all peer" ""

        echo -e "  Validating pg_hba.conf..."
        if [[ ! -s "$pg_hba_conf" ]]; then
            echo -e "\033[91m❌ FATAL: pg_hba.conf is empty after modification!\033[0m"
            echo -e "  Restoring backup..."
            sudo cp "${pg_hba_conf}.bak" "$pg_hba_conf"
            return 1
        fi

        local line_count
        line_count=$(sudo wc -l "$pg_hba_conf" | awk '{print $1}')
        echo -e "    ✅ pg_hba.conf has $line_count lines"

        echo -e "  Reloading PostgreSQL configuration..."
        if systemctl is-active --quiet postgresql 2>/dev/null; then
            if sudo systemctl reload postgresql 2>/dev/null; then
                echo -e "    ✅ PostgreSQL configuration reloaded successfully"
            else
                echo -e "\033[93m    ⚠️  Failed to reload PostgreSQL - may need manual reload\033[0m"
            fi
        else
            echo -e "    ⚠️  PostgreSQL is not running - reload skipped"
        fi

        echo -e "\033[92m✅ pg_hba.conf updated successfully\033[0m"

        echo -e "\n\033[1;33m📝 Step 8: Updating patroni.yml pg_hba section...\033[0m"
        if [[ -f /etc/patroni.yml ]]; then
            sudo cp /etc/patroni.yml /etc/patroni.yml.bak
            echo -e "  ✅ Backed up /etc/patroni.yml to /etc/patroni.yml.bak"
            echo -e "  Updating pg_hba entries in patroni.yml..."

            if sudo grep -q "host replication postgres 192\.168\.0\.0/16" /etc/patroni.yml; then
                sudo sed -i "s|host replication postgres 192\.168\.0\.0/16|host replication postgres $SUBNET_CIDR|g" /etc/patroni.yml
                echo -e "    ✅ Updated: host replication postgres $SUBNET_CIDR md5"
            else
                echo -e "    ⚠️  Entry 'host replication postgres 192.168.0.0/16' not found or already updated"
            fi

            if sudo grep -q "host all postgres 192\.168\.0\.0/16" /etc/patroni.yml; then
                sudo sed -i "s|host all postgres 192\.168\.0\.0/16|host all postgres $SUBNET_CIDR|g" /etc/patroni.yml
                echo -e "    ✅ Updated: host all postgres $SUBNET_CIDR md5"
            else
                echo -e "    ⚠️  Entry 'host all postgres 192.168.0.0/16' not found or already updated"
            fi

            if sudo grep -q "host all all 192\.168\.0\.0/16" /etc/patroni.yml; then
                sudo sed -i "s|host all all 192\.168\.0\.0/16|host all all $SUBNET_CIDR|g" /etc/patroni.yml
                echo -e "    ✅ Updated: host all all $SUBNET_CIDR md5"
            else
                echo -e "    ⚠️  Entry 'host all all 192.168.0.0/16' not found or already updated"
            fi

            sudo sed -i "s|#Change this based on your subnet|#User-defined subnet|g" /etc/patroni.yml
            echo -e "\033[92m✅ patroni.yml pg_hba section updated successfully\033[0m"
        else
            echo -e "\033[93m    ⚠️  /etc/patroni.yml not found - skipping pg_hba update in patroni.yml\033[0m"
        fi

        echo -e "\n\033[1;33m📝 Step 8.1: Adding sudoers entries for www-data...\033[0m"

        local sudoers_file="/etc/sudoers.d/www-data-patroni"
        local sudoers_entry1="www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl"
        local sudoers_entry2="www-data ALL=(ALL) NOPASSWD: /usr/lib/postgresql/13/bin/pg_controldata"
        local temp_sudoers="/tmp/www-data-patroni.$$"

        echo -e "  Creating sudoers file: $sudoers_file"
        echo "$sudoers_entry1" > "$temp_sudoers"
        echo "$sudoers_entry2" >> "$temp_sudoers"

        if sudo visudo -c -f "$temp_sudoers" &>/dev/null; then
            sudo cp "$temp_sudoers" "$sudoers_file"
            sudo chmod 440 "$sudoers_file"
            rm -f "$temp_sudoers"
            echo -e "    Added: $sudoers_entry1"
            echo -e "    Added: $sudoers_entry2"
            echo -e "\033[92m✅ Sudoers entries added successfully\033[0m"
        else
            echo -e "\033[91m❌ Sudoers syntax validation failed - skipping\033[0m"
            rm -f "$temp_sudoers"
        fi

        echo -e "\n\033[1;33m📝 Step 9: Updating postgresql.conf...\033[0m"

        local pg_conf="/etc/postgresql/13/main/postgresql.conf"
        if [[ -f "$pg_conf" ]]; then
            sudo cp "$pg_conf" "${pg_conf}.backup.$(date +%Y%m%d_%H%M%S)"
            echo -e "  ✅ Backed up postgresql.conf"

            local current_listen
            current_listen=$(sudo grep -E "^listen_addresses" "$pg_conf" 2>/dev/null || echo "")
            if [[ -z "$current_listen" ]]; then
                echo "listen_addresses = '*'" | sudo tee -a "$pg_conf" > /dev/null
                echo -e "  ✅ Added: listen_addresses = '*'"
            elif [[ "$current_listen" =~ "'\\*'" ]]; then
                echo -e "  ✅ listen_addresses already set to '*'"
            else
                sudo sed -i "s/^listen_addresses.*/listen_addresses = '*'/g" "$pg_conf"
                echo -e "  ✅ Changed listen_addresses to '*'"
            fi

            echo -e "\033[92m✅ postgresql.conf updated successfully\033[0m"
        else
            echo -e "\033[93m⚠️  postgresql.conf not found at $pg_conf - skipping\033[0m"
        fi

        echo -e "\n\033[1;33m📝 Step 10: Checking PostgreSQL service...\033[0m"

        if systemctl is-active --quiet postgresql; then
            echo -e "  PostgreSQL is running. Restarting..."
            sudo systemctl restart postgresql
            sleep 2
            if systemctl is-active --quiet postgresql; then
                echo -e "\033[92m✅ PostgreSQL restarted successfully\033[0m"
            else
                echo -e "\033[91m❌ PostgreSQL failed to restart\033[0m"
            fi
        else
            echo -e "  PostgreSQL is not running. Skipping restart."
        fi

        echo -e "\n\033[1;33m📝 Step 11: Adding leadercheck alias to ~/.bashrc...\033[0m"

        local bashrc_file="$HOME/.bashrc"
        local alias_line='alias leadercheck="sudo patronictl -c /etc/patroni.yml list"'
        if grep -qF 'alias leadercheck=' "$bashrc_file" 2>/dev/null; then
            sed -i '/alias leadercheck=/d' "$bashrc_file" 2>/dev/null || true
            sed -i '/# Patroni leader check alias/d' "$bashrc_file" 2>/dev/null || true
            echo -e "  Removed existing leadercheck alias"
        fi

        echo "" >> "$bashrc_file"
        echo "# Patroni leader check alias" >> "$bashrc_file"
        echo "$alias_line" >> "$bashrc_file"
        echo -e "\033[92m✅ Added alias 'leadercheck' to ~/.bashrc\033[0m"
        echo -e "\033[93m   ⚠️  To use the alias in this terminal, run: source ~/.bashrc\033[0m"
        echo -e "\033[93m   Or open a new terminal window.\033[0m"
    else
        echo -e "\033[93m⚠️  patroni.yml not found or empty - you'll need to configure /etc/patroni.yml manually\033[0m"
    fi

    echo -e "\n\033[1;33m📝 Creating required directories...\033[0m"

    if [[ ! -d /var/run/postgresql ]]; then
        sudo mkdir -p /var/run/postgresql
        sudo mkdir -p /var/run/postgresql/13-main.pg_stat_tmp
        sudo chown -R postgres:postgres /var/run/postgresql
        sudo chmod 755 /var/run/postgresql
        echo -e "  ✅ Created PostgreSQL runtime directories"
    else
        echo -e "  PostgreSQL runtime directory already exists"
    fi

    if [[ -d /var/lib/postgresql ]]; then
        sudo chown -R postgres:postgres /var/lib/postgresql
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable patroni.service
    sudo systemctl start patroni.service

    echo -e "\033[92m✅ Patroni service enabled & running\033[0m"
    echo -e "\n\033[1;32m========================================\033[0m"
    echo -e "\033[1;32m   PATRONI SETUP COMPLETED!\033[0m"
    echo -e "\033[1;32m========================================\033[0m"
    echo -e "\033[93mRemember:\033[0m"
    echo -e "  - To unlock /etc/hosts: sudo chattr -i /etc/hosts"
    echo -e "  - To use leadercheck alias: source ~/.bashrc (or open new terminal)"
    echo -e "  - To check Patroni cluster: sudo patronictl -c /etc/patroni.yml list"

    return 0
}

main_patroni_installation() {
    local patroni_already_installed=false

    if command -v patroni &> /dev/null; then
        local existing_version
        existing_version=$(patroni --version 2>&1)
        patroni_already_installed=true
        if [[ -f "/etc/systemd/system/patroni.service" && -s "/etc/patroni.yml" ]]; then
            echo -e "\033[92m✅ Patroni already installed and configured: $existing_version\033[0m"
            return 0
        fi
        echo -e "\033[93m⚠️  Patroni is already installed ($existing_version) but service/config is incomplete.\033[0m"
        echo -e "\033[93m   Continuing with Patroni service setup.\033[0m"
    fi

    echo -e "\n\033[1;33m🔍 Checking Redis server on port 19742...\033[0m"
    if ! ps ax | grep -q "redis-server.*:19742"; then
        echo -e "\033[91m❌ Redis server on port 19742 is NOT running!\033[0m"
        echo -e "\033[93m⚠️  Patroni requires Redis on port 19742 for leader election.\033[0m"
        echo -e "\033[93m   Possibly: Please install RMON / might publish not done.\033[0m"
        echo -e "\033[93m   Skipping Patroni installation.\033[0m"
        return 1
    else
        echo -e "\033[92m✅ Redis server on port 19742 is running\033[0m"
    fi

    echo -e "\n\033[1;33m🔍 Checking database dependency for Patroni installation...\033[0m"
    if [[ -z "$DbPassword" || -z "$dbMachineIp" || -z "$DbName" ]]; then
        echo -e "\033[91m❌ Database credentials not available. Cannot verify REDUNDANCY_ASSET.\033[0m"
        echo -e "\033[93m⚠️  Please ensure database configuration is complete before Patroni installation.\033[0m"
        return 1
    fi

    local redundancy_check=""
    if [[ "$dbMachineIp" == "127.0.0.1" || "$dbMachineIp" == "localhost" ]]; then
        redundancy_check=$(PGPASSWORD="$DbPassword" psql \
            -U "${DbUsername:-postgres}" \
            -d "$DbName" \
            -t -A \
            -c "SELECT asset_name FROM assets WHERE asset_name = 'REDUNDANCY_ASSET' LIMIT 1;" 2>/dev/null)
    else
        redundancy_check=$(PGPASSWORD="$DbPassword" psql \
            -h "$dbMachineIp" \
            -p "${db_port:-5432}" \
            -U "${DbUsername:-postgres}" \
            -d "$DbName" \
            -t -A \
            -c "SELECT asset_name FROM assets WHERE asset_name = 'REDUNDANCY_ASSET' LIMIT 1;" 2>/dev/null)
    fi

    if [[ -z "$redundancy_check" || "$redundancy_check" != "REDUNDANCY_ASSET" ]]; then
        echo -e "\033[91m❌ REDUNDANCY_ASSET not found in database!\033[0m"
        echo -e "\033[93m⚠️  Cannot proceed with Patroni installation without REDUNDANCY_ASSET entry.\033[0m"
        echo -e "\033[93m   Did redund.py run successfully?\033[0m"
        echo -e "\033[93m   Please run: sudo python3 external_scripts/redund.py\033[0m"
        echo -e "\033[93m   Then retry the installation.\033[0m"
        return 1
    fi

    echo -e "\033[92m✅ REDUNDANCY_ASSET found in database - proceeding with Patroni installation\033[0m"
    echo -e "\n\033[1;36m========================================\033[0m"
    echo -e "\033[1;36m   PATRONI INSTALLATION FOR REDUNDANCY\033[0m"
    echo -e "\033[1;36m========================================\033[0m"

    local script_dir_patroni="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    local patroni_packages_archive="$script_dir_patroni/external_scripts/patroni_offline_v4.0.5.tar.gz"

    if [[ "$patroni_already_installed" == "true" ]]; then
        echo -e "\n\033[1;33mStep 1: Setting up Patroni service...\033[0m"
        if setup_patroni_service; then
            echo -e "\033[92m✅ Patroni service setup completed\033[0m"
        else
            echo -e "\033[91m❌ Patroni service setup failed\033[0m"
        fi
    elif [[ -f "$patroni_packages_archive" ]]; then
        echo -e "\033[92m✅ Found Patroni offline packages: $patroni_packages_archive\033[0m"
        echo -e "\n\033[1;33mStep 1: Checking Patroni prerequisites...\033[0m"
        if check_patroni_prerequisites; then
            echo -e "\033[92m✅ Prerequisites check passed\033[0m"
            echo -e "\n\033[1;33mStep 2: Installing Patroni...\033[0m"
            if install_patroni_offline "$patroni_packages_archive"; then
                echo -e "\033[92m✅ Patroni installation completed\033[0m"
                echo -e "\n\033[1;33mStep 3: Setting up Patroni service...\033[0m"
                if setup_patroni_service; then
                    echo -e "\033[92m✅ Patroni service setup completed\033[0m"
                else
                    echo -e "\033[91m❌ Patroni service setup failed\033[0m"
                fi
            else
                echo -e "\033[91m❌ Patroni installation failed\033[0m"
                echo -e "\033[93m   You may need to install Patroni manually\033[0m"
            fi
        else
            echo -e "\033[91m❌ Prerequisites check failed\033[0m"
            echo -e "\033[93m   Please resolve the issues and install Patroni manually\033[0m"
        fi
    else
        echo -e "\033[93m⚠️  Patroni offline packages not found in external_scripts/\033[0m"
        echo -e "\033[93m   Expected: patroni_offline_v4.0.5.tar.gz (or similar)\033[0m"
        echo -e "\033[93m   Skipping Patroni installation - please install manually if needed\033[0m"
        echo -e "\n   Files in external_scripts/:"
        ls -la "$script_dir_patroni/external_scripts/" 2>/dev/null || echo "   (directory not accessible)"
    fi

    echo -e "\n\033[1;36m========================================\033[0m"
    echo -e "\033[1;36m   END OF PATRONI INSTALLATION\033[0m"
    echo -e "\033[1;36m========================================\033[0m\n"
    echo -e "\033[93m Important: To start using the 'leadercheck' alias, run:\033[0m \033[1msource ~/.bashrc\033[0m \033[93mor open a new terminal window.\033[0m"
}

# ============================================================================
# END OF PATRONI FUNCTIONS
# ============================================================================

  # Check if jq is installed
  if ! command -v jq &> /dev/null; then
    echo -e "\e[1;32m ==========jq tool is not installed, Installing...========== \e[0m"
    cd services/jq/ && sudo dpkg -i *.deb 
#   else
    # echo -e "\e[1;32m ==========jq tool is already installed!========== \e[0m"
  fi

# Desired locale
DESIRED_LOCALE="en_US.UTF-8"

# Get current LANG value
CURRENT_LOCALE=$(locale | grep "^LANG=" | cut -d= -f2)

# Check if desired locale is already set
if [[ "$CURRENT_LOCALE" == "$DESIRED_LOCALE" ]]; then
    echo -e "Locale is already set to \e[1;32m$DESIRED_LOCALE\e[0m"
else
    echo "Setting locale to $DESIRED_LOCALE"

    # Generate the locale if not already present
    if ! locale -a | grep -i "$DESIRED_LOCALE"; then
        echo "Generating $DESIRED_LOCALE locale..."
        sudo locale-gen "$DESIRED_LOCALE"
    fi
    # Set system-wide locale
    sudo update-locale LANG=$DESIRED_LOCALE
    echo -e "\e[1;33mPlease reboot the system and re-run the script!\e[0m"
    exit 1
fi

# Arguments parsing
if [[ "$1" == "--help" ]]; then
    echo "This is an installation for RMEYE Build"
    echo 'bash linux.install_final.sh -h DbIpAddress -d dataBaseNAme -p rmtestUserPassword -n cmp'
    exit 0
fi

# Handling Redundancy mode
while true; do
    read -p $'\nIs this a Redundancy Machine? (y/n): ' redund
    redund=$(echo "$redund" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$redund" == "yes" || "$redund" == "y" ]]; then
        redund_flag=true
        SCRIPT_FOLDER='external_scripts'
        
        # Get all executable scripts from the folder
        ext_scripts=()
        if [ -d "$SCRIPT_FOLDER" ]; then
            for f in "$SCRIPT_FOLDER"/*; do
                if [ -f "$f" ] && [[ ! "$(basename "$f")" =~ ^\. ]]; then
                    ext_scripts+=("$f")
                fi
            done
        fi
        
        if [ ${#ext_scripts[@]} -eq 0 ]; then
            echo "No executable scripts found in $SCRIPT_FOLDER"
            exit 1
        else
            echo "⚙️ Starting build installation with redundancy configuration..."
            break
        fi
    elif [[ -z "$redund" || "$redund" == "no" || "$redund" == "n" ]]; then
        redund_flag=false
        echo "⚙️ Proceeding with normal build installation..."
        break
    else
        echo "Invalid input. Please enter Yes, No, or press ENTER to skip."
    fi
done

# Function to stop redundancy services
stop_redundant_services() {
    local service="$1"
    refreshPermissions "$$" & sudo systemctl daemon-reload
    refreshPermissions "$$" & sudo service "$service" stop
    local status=$(systemctl is-active "$service")
    if [[ "$status" == "inactive" ]]; then
        echo "Successfully stopped $service."
    else
        echo "Failed to stop $service!"
        exit 1
    fi
}

# Function to start redundancy services
start_redundant_services() {
    local service="$1"

    if [[ "$service" == "patroni" ]]; then
        if [[ ! -f "/etc/systemd/system/patroni.service" ]] && ! systemctl list-unit-files 2>/dev/null | grep -q "^patroni\.service"; then
            echo "⚠️  Skipping patroni (service file not present)"
            return 0
        fi

        if ! command -v patroni &> /dev/null && [[ ! -f "/usr/local/bin/patroni" ]]; then
            echo "⚠️  Skipping patroni (patroni not installed)"
            return 0
        fi
    fi

    refreshPermissions "$$" & sudo service "$service" start
    local status=$(systemctl is-active "$service")
    if [[ "$status" == "active" ]]; then
        echo "Successfully started $service."
    else
        echo "Failed to start $service!"
        exit 1
    fi
}

# Handle the services stop/start required services
first_time_redund_installation=false
if [[ "$redund_flag" == "true" ]]; then
    kestrelfilepath1='/etc/systemd/system/kestrel-eyewatchdog.service'
    kestrelfilepath2='/etc/systemd/system/patroni.service'
    if [[ -f "$kestrelfilepath1" && -f "$kestrelfilepath2" ]]; then
        redund_services=("kestrel-eyewatchdog" "patroni")
        for ser in "${redund_services[@]}"; do
            stop_redundant_services "$ser"
        done
        # start postgres service
        refreshPermissions "$$" & sudo service postgresql start
        status=$(systemctl is-active postgresql)
        if [[ "$status" == "active" ]]; then
            echo "Successfully started postgresql"
        else
            echo "Failed to start postgresql!"
            exit 1
        fi
    else
        echo "This is first time redundancy build installation or Please check eye.watchdog folder preset on build !!"
        first_time_redund_installation=true
    fi
fi

# Arguments for Database connection strings handling
argumentsData=("$@")

# Default values
DbName=''
DbUsername=''
DbPassword=''
dbMachineIp=''
cmp=''

# Parse command line arguments
if [ ${#argumentsData[@]} -gt 2 ]; then
    for i in "${!argumentsData[@]}"; do
        dataPoint="${argumentsData[$i]}"
        if [[ "$dataPoint" == "-h" ]] && [ $((i + 1)) -lt ${#argumentsData[@]} ]; then
            dbMachineIp="${argumentsData[$((i + 1))]}"
        fi
        if [[ "$dataPoint" == "-d" ]] && [ $((i + 1)) -lt ${#argumentsData[@]} ]; then
            DbName="${argumentsData[$((i + 1))]}"
        fi
        if [[ "$dataPoint" == "-p" ]] && [ $((i + 1)) -lt ${#argumentsData[@]} ]; then
            DbPassword="${argumentsData[$((i + 1))]}"
        fi
        if [[ "$dataPoint" == "-n" ]] && [ $((i + 1)) -lt ${#argumentsData[@]} ]; then
            cmp="${argumentsData[$((i + 1))]}"
        fi
    done
    
    if [[ -z "$DbName" || -z "$DbPassword" || -z "$dbMachineIp" || -z "$cmp" ]]; then
        echo "invalid syntax to give command line parameters"
        echo 'bash linux.install_final.sh -h DbIpAddress -d dataBaseNAme -p rmtestUserPassword -n cmp'
        exit 1
    fi
fi

# Function to list available databases with improved error handling
list_databases() {
    local host="$1"
    local port="$2"
    local user="$3"
    local pass="$4"

    port="${port:-5432}"

    echo -e "\n🔎 Fetching databases from ${host}:${port}..." >&2

    local dbs
    if [[ "$host" == "127.0.0.1" || "$host" == "localhost" ]]; then
        dbs=$(PGPASSWORD="$pass" psql \
            -U "$user" \
            -d postgres \
            -t -A \
            -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0','template1','postgres');"
        )
    else
        dbs=$(PGPASSWORD="$pass" psql \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d postgres \
            -t -A \
            -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0','template1','postgres');"
        )
    fi || {
        echo "❌ PostgreSQL connection failed" >&2
        return 1
    }

    mapfile -t DB_ARRAY <<< "$dbs"

    echo "✅ Available databases:" >&2
    for i in "${!DB_ARRAY[@]}"; do
        echo "  [$i] ${DB_ARRAY[$i]}" >&2
    done

    read -rp "Select database number: " choice
    echo "${DB_ARRAY[$choice]}"
}



# Get the DB credentials either from user or from json file
if [[ -z "$DbName" || -z "$DbPassword" || -z "$dbMachineIp" ]]; then
    # Check if we can use existing configuration
    if [ -f '/var/www/eye.api/appsettings.json' ]; then
        app=$(jq '.' /var/www/eye.api/appsettings.json 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            conn_str=$(echo "$app" | jq -r '.ConnectionStrings.PostgreConnection // empty')
            if [[ -n "$conn_str" ]]; then
                IFS=';' read -ra line <<< "$conn_str"
                existing_host="" existing_db="" existing_user=""
                for part in "${line[@]}"; do
                    if [[ "$part" =~ ^Host= ]]; then
                        existing_host="${part#Host=}"
                    elif [[ "$part" =~ ^Database= ]]; then
                        existing_db="${part#Database=}"
                    elif [[ "$part" =~ ^Username= ]]; then
                        existing_user="${part#Username=}"
                    fi
                done
                
                if [[ -n "$existing_host" && -n "$existing_db" ]]; then
                    read -p $'\nDo you want to use the existing database configuration? (Host: '"${existing_host}"$', Database: '"${existing_db}"$') [y/n]: ' use_existing
                    if [[ "$use_existing" =~ ^[yY] ]]; then
                        dbMachineIp="$existing_host"
                        DbName="$existing_db"
                        # Extract username and password from connection string
                        for part in "${line[@]}"; do
                            if [[ "$part" =~ ^Username= ]]; then
                                DbUsername="${part#Username=}"
                            elif [[ "$part" =~ ^Password= ]]; then
                                DbPassword="${part#Password=}"
                            fi
                        done
                        echo -e "\033[92mUsing existing database configuration.\033[0m"
                    fi
                fi
            fi
        fi
    else
        # First time build installation - appsettings.json not found
        echo -e "\n\033[1;33m⚠️  First time build installation detected!\033[0m"
        echo -e "\033[1;33m   Please provide database connection details.\033[0m\n"
    fi
    
    # If credentials still not set, prompt user
    if [[ -z "$DbName" || -z "$DbPassword" || -z "$dbMachineIp" ]]; then
        echo -e "\n=================================================="
        echo -e "        Database Configuration Setup"
        echo -e "=================================================="
        echo -e "This step configures the PostgreSQL connection"
        echo -e "required for the RMEYE application services."

        echo -e "\nWhere is your PostgreSQL database hosted?"
        echo -e "  1) On this server (localhost)"
        echo -e "  2) On a remote server"
        read -rp "Select an option [1/2] (default: 1): " db_location
        db_location="${db_location:-1}"

        if [[ "$db_location" == "1" ]]; then
            dbMachineIp="127.0.0.1"
            db_port="5432"

            echo -e "\033[92m✔ Using local database server\033[0m"
            echo -e "  Host : $dbMachineIp"
            echo -e "  Port : $db_port"

        elif [[ "$db_location" == "2" ]]; then
            while true; do
                read -rp "Enter database server IP address or hostname: " dbMachineIp
                [[ -n "$dbMachineIp" ]] && break
                echo -e "\033[91mDatabase host cannot be empty.\033[0m"
            done

            read -rp "Enter database server port [default: 5432]: " db_port
            db_port="${db_port:-5432}"
            
        else
            echo -e "\033[91m❌ Invalid selection. Exiting.\033[0m"
            exit 1
        fi

        # Credentials (for both local & remote)
        read -rp "Enter database username [default: postgres]: " pg_username
        pg_username="${pg_username:-postgres}"

        echo "Password will not be displayed"
        read -rsp "Enter password for database user \"${pg_username}\": " pg_password
        echo

        # Try auto-listing databases
        DbName=$(list_databases "$dbMachineIp" "$db_port" "$pg_username" "$pg_password")

        if [[ $? -ne 0 || -z "$DbName" ]]; then
            echo -e "\033[93m⚠️ Unable to fetch database list automatically.\033[0m"
            while true; do
                read -rp "Enter database name manually: " DbName
                [[ -n "$DbName" ]] && break
                echo -e "\033[91mDatabase name cannot be empty.\033[0m"
            done
        fi

        # Use the same username and password for application connection
        DbUsername="$pg_username"
        DbPassword="$pg_password"
    fi
fi

# Ensure DbUsername is set (default to postgres if not set)
if [[ -z "$DbUsername" ]]; then
    DbUsername="postgres"
fi

echo -e "DB-IP: \033[92m${dbMachineIp}\033[00m DB-Name: \033[92m${DbName}\033[00m DB-User: \033[92m${DbUsername}\033[00m"

# Updating COMPANY_NAME in the config.js based on user input
company_names=('1' 'RM' '2' 'SAIL' '3' 'GANZ' '4' 'MR')
while true; do
    if [[ -n "$cmp" ]]; then
        break
    else
        read -p $'\nPlease select the customer environment from below list:\n0.RIL\n1.RM\n2.SAIL\n3.GANZ\n4.MR\nPress ENTER to skip, default RIL environment will be selected: ' env
        case "$env" in
            '1')
                cmp='RM'
                echo -e "Environment is \033[92m${cmp}\033[00m"
                break
                ;;
            '2')
                cmp='SAIL'
                echo -e "Environment is \033[92m${cmp}\033[00m"
                break
                ;;
            '3')
                cmp='GANZ'
                echo -e "Environment is \033[92m${cmp}\033[00m"
                break
                ;;
            '4')
                cmp='MR'
                echo -e "Environment is \033[92m${cmp}\033[00m"
                break
                ;;
            '0'|'')
                cmp='RIL'
                echo -e "Environment is \033[92m${cmp}\033[00m"
                break
                ;;
            *)
                echo -e "\033[91m\nInvalid input! Please select a valid option\033[00m"
                ;;
        esac
    fi
done

# Run the command to extract the IP address from the API_URL in config.js
existing_domain_name=""
if [ -f /var/www/eye-ui/assets/config.js ]; then
    existing_domain_name=$(cat /var/www/eye-ui/assets/config.js | awk -F"'" '/API_URL/ {print $2}' | sed 's|http[s]\?://||; s|/api$||')
fi

# Updating RMEYE wepage URL in the config.js and appsettings.json of eyeapi service based on user input
while true; do
    # checking whether the system is hosted Publically or is azure cloud
    check_public_ip=$(curl -s ifconfig.me 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    if [ -d /var/lib/waagent ]; then
        check_public_ip='azure'
    fi
    if [[ "$check_public_ip" == '103.60.212.97' || "$check_public_ip" == 'azure' ]]; then
        echo -e "\033[92m\nThis machine is hosted as public domain server!So, Need to configure a RMEYE website URL.\033[00m"
        read -p $'\nPlease select one from below list\n1.Use the exsisting domain name. '"${existing_domain_name}"$'.\n2.Configure a new specific \'domain name\':\n3.Configure the IP address as URL\n' configure_url
        if [[ "$configure_url" == "1" || -z "$configure_url" ]]; then
            if [ -d /var/www/eye-ui/ ]; then
                echo -e "\033[92m\nUpdating the exsisting domain name!\033[00m"
                new_url="$existing_domain_name"
                break
            else
                echo -e "\033[92m\nThis is first time build Installtion! Kindly select the option 2 or 3 \033[00m"
            fi
        elif [[ "$configure_url" == "2" ]]; then
            read -p "Please provide your domain name (eg'www.rmeyedemo.com'):" new_url
            break
        elif [[ "$configure_url" == "3" ]]; then
            echo -e "\033[92m\nConfiguring the host ip as URL.\033[00m"
            break
        else
            echo -e "\033[91m\nInvalid input! Please select a valid option\033[00m"
        fi
    elif [[ "$redund_flag" == "true" ]]; then
        echo -e "\033[92m\nThis machine is hosted as local server with redundancy setup.\033[00m"
        configure_url="1"
        break
    else
        echo -e "\033[92m\nThis machine is hosted as local server.\033[00m"
        configure_url='3'
        break
    fi
done
# Taking maps backup if any
# refreshPermissions "$$" & sudo cp -rf /var/www/eye-ui/assets/maps/ ./ 2>/dev/null || true

# Removing the files from Ui and showing maintenance page
refreshPermissions "$$" & sudo rm -rf /var/www/eye-ui/*
if [ -d "eye-maintenance" ]; then
    refreshPermissions "$$" & sudo cp -r eye-maintenance/* /var/www/eye-ui/
    echo -e "\033[92mUI will be under maintenance,Installation in progress...\033[00m"
fi

# List of all the services
# services=(eye eyeapi eyescheduler eyeanalyticsBT eyecommondata eyeanalyticsMIO eyeanalyticsMIP eyeanalyticsOLC eyeanalyticsRL eyeanalyticsWHS eyedga eyereport eyeanalyticsHI eyeanalyticsHIDGA eyecalc eyetpcalc eyestandardanalyticengine eyetimeranalyticengine eyedataimporter eyenotify replayengine analyticengine AuditLogger eyesf6calculation eyeanalyticsvfdml eyerealtimeexport eyeanalyticsvfdprediction eyeaianalytics eyeanalyticsRCM eyewatchdog)

# Dynamically updating the services() list from the services directory (kestrel-*.service files)
echo -e "\n\033[1;33m Validating the unit service files...\033[0m"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICES_DIR="$SCRIPT_DIR/services"

services=()

for service_file in "$SERVICES_DIR"/kestrel-*.service; do
    [[ -f "$service_file" ]] || continue

    # Skip eyewatchdog service if redundancy is not enabled
    if [[ "$redund_flag" == "false" && "$service_file" == "$SERVICES_DIR/kestrel-eyewatchdog.service" ]]; then
        echo "⚠️  Skipping kestrel-eyewatchdog (redundancy not enabled)"
        continue
    fi

    if [[ "$service_file" == "$SERVICES_DIR/kestrel-eyeanalyticsBT.service" || "$service_file" == "$SERVICES_DIR/kestrel-eyeanalyticsMIO.service" || "$service_file" == "$SERVICES_DIR/kestrel-eyeanalyticsMIP.service" ]]; then
        echo "⚠️  Skipping kestrel-$service_name (BT/MIO/MIP services are skipping))"
        continue
    fi

    # Extract service name: kestrel-<name>.service → <name>
    service_name=$(basename "$service_file")
    service_name="${service_name#kestrel-}"
    service_name="${service_name%.service}"

    # Extract DLL path from ExecStart
    dll_path=$(grep -E '^ExecStart=' "$service_file" | awk '{print $NF}')

    if [[ -z "$dll_path" ]]; then
        echo "⚠️  Skipping $service_name (ExecStart not found)"
        continue
    fi

    if [[ ! -f "$dll_path" ]]; then
        echo "⚠️  Skipping kestrel-$service_name (DLL missing: $dll_path)"
        continue
    fi

    echo "✅ Found valid service file: kestrel-$service_name"
    services+=("$service_name")
done

# Reload systemd daemon
sudo systemctl daemon-reload

# Optimized code (to Stop only running services in parallel)
echo -e "\n\033[1;33m🛑 Stopping the eye services...\033[0m"

STOP_PIDS=()
for service in "${services[@]}"; do
    status=$(systemctl is-active "kestrel-${service}" 2>/dev/null || echo "inactive")
    if [[ "$status" == "active" ]]; then
        echo " Stopping the kestrel-${service} service..."
        sudo systemctl stop "kestrel-${service}" &
        STOP_PIDS+=($!)
    else
        echo "Service already stopped: kestrel-${service}"
    fi
done

# Wait only for the systemctl stop commands to complete
if [ ${#STOP_PIDS[@]} -gt 0 ]; then
    echo " Waiting for the services to stop..."
    for pid in "${STOP_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
fi

# Remove service files
for service in "${services[@]}"; do
    refreshPermissions "$$" & sudo rm -f /etc/systemd/system/kestrel-${service}.service
done

echo "All running services stopped and service files removed successfully."

# Removing all the services and apis files
refreshPermissions "$$" & sudo rm -rf /var/www/eye.api/
refreshPermissions "$$" & sudo rm -rf /var/www/eyemobile-ui/
refreshPermissions "$$" & sudo rm -rf /srv/*

# Installing the npm install
echo "Installing the npm install for eye-reports-ui..."
if [ -d "eye-reports-ui" ]; then
    # refreshPermissions "$$" & sudo npm i --prefix eye-reports-ui/
    refreshPermissions "$$" & sudo npm install --no-audit --no-fund --prefix eye-reports-ui/
fi

# Copying the build folder to root directories
present_working_dir=$(pwd)

# Get all directories in current directory that contain 'eye'
folders=()
for f in "$present_working_dir"/*; do
    if [ -d "$f" ] && [[ "$(basename "$f")" == *"eye"* ]]; then
        folders+=("$(basename "$f")")
    fi
done

www_folders=('eye.api' 'eyemobile-ui' 'eye-ui')

# remove Endpoints strings from eyeapi appsettings.json
if [ -f "eye.api/appsettings.json" ]; then
    tmp_file=$(mktemp)
    jq 'if .Kestrel.Endpoints then .Kestrel.Endpoints = {} else . end' eye.api/appsettings.json > "$tmp_file"
    sudo cp "$tmp_file" eye.api/appsettings.json
    rm -f "$tmp_file"
fi

for folder in "${folders[@]}"; do
    if [[ " ${www_folders[@]} " =~ " ${folder} " ]]; then
        target_path='/var/www/'
    else
        target_path='/srv/'
    fi
    
    echo -e "Copying \033[92m${folder}\033[00m to \033[92m${target_path}\033[00m..."
    refreshPermissions "$$" & sudo cp -r "$folder" "$target_path"
done

# Published builds may omit appsettings.Development.json (optional in ASP.NET Core).
# This script patches both files; seed Development from base when absent so later
# sed/jq steps and DB credential discovery under /srv stay consistent.
ensure_appsettings_development_shadow() {
    local base_json="$1"
    local dev_json="$2"
    if [[ -f "$base_json" && ! -f "$dev_json" ]]; then
        echo -e "\033[93mNote: Missing ${dev_json}; copying from ${base_json} for install-time configuration.\033[0m"
        refreshPermissions "$$" & sudo cp "$base_json" "$dev_json"
    fi
}
ensure_appsettings_development_shadow "/var/www/eye.api/appsettings.json" "/var/www/eye.api/appsettings.Development.json"
ensure_appsettings_development_shadow "/srv/eye.notifier/appsettings.json" "/srv/eye.notifier/appsettings.Development.json"

# Copying the nginx config file
refreshPermissions "$$" & sudo cp services/nginx.conf /etc/nginx/

# Copying the service files
for service in "${services[@]}"; do
    refreshPermissions "$$" & sudo cp "services/kestrel-${service}.service" /etc/systemd/system/
done

# Keep the Patroni unit updated during redundancy installs without changing the
# existing kestrel service flow.
if [[ "$redund_flag" == "true" && -f "services/patroni.service" ]]; then
    refreshPermissions "$$" & sudo cp "services/patroni.service" /etc/systemd/system/
fi

##Coping maps to the eye-ui
#if [ -f ~/maps/hyderabad_tiles/OSMPublicTransport/10/734/460.png ]; then
#  echo -e "\e[1;32m ==========Coping Maps to Eye-ui ========== \e[0m"
#  refreshPermissions "$$" & sudo cp -r ~/maps/ /var/www/eye-ui/assets/
#else
#  echo -e "\e[1;31m ==========Maps are not present========== \e[0m"
#fi

# All appsettings json file paths
srv_dirs=("/srv")
appsettings_file_paths=()

# Search for "appsettings*.json" files only in the first subdirectory level
for base_dir in "${srv_dirs[@]}"; do
    if [ -d "$base_dir" ]; then
        while IFS= read -r -d '' file; do
            # Ensure the file is exactly one level below base_dir
            rel_path="${file#$base_dir/}"
            if [[ "$rel_path" != */*/* ]]; then
                appsettings_file_paths+=("$file")
            fi
        done < <(find "$base_dir" -maxdepth 2 -name "appsettings*.json" -type f -print0 2>/dev/null)
    fi
done

appsettings_file_paths+=('/var/www/eye.api/appsettings.Development.json' '/var/www/eye.api/appsettings.json')

# Function to update database connection string in a JSON file
# Handles both first-time installation (creates ConnectionStrings) and normal installation (updates existing)
update_db_connection_string() {
    local file_path="$1"
    local new_host="$2"
    local new_db="$3"
    local new_username="$4"
    local new_password="$5"
    
    if [[ ! -f "$file_path" ]]; then
        echo -e "\033[93mFile not found: $file_path, skipping...\033[0m"
        return 0
    fi
    
    # Validate JSON first
    if ! jq empty "$file_path" 2>/dev/null; then
        echo -e "\033[91mInvalid JSON in file $file_path\033[0m"
        return 1
    fi
    
    # Check if ConnectionStrings exists, if not create it
    local has_connection_strings
    has_connection_strings=$(jq -e '.ConnectionStrings // empty' "$file_path" 2>/dev/null)
    
    # Get existing connection string if it exists
    local conn_str
    conn_str=$(jq -r '.ConnectionStrings.PostgreConnection // empty' "$file_path" 2>/dev/null)
    
    local old_host="" old_port="" old_db="" old_user="" old_password=""
    local other_params=()
    
    # Parse existing connection string if it exists
    if [[ -n "$conn_str" ]]; then
        IFS=';' read -ra parts <<< "$conn_str"
        for part in "${parts[@]}"; do
            part=$(echo "$part" | xargs)  # Trim whitespace
            [[ -z "$part" ]] && continue
            
            if [[ "$part" =~ ^Host= ]]; then
                old_host="${part#Host=}"
            elif [[ "$part" =~ ^Port= ]]; then
                old_port="${part#Port=}"
            elif [[ "$part" =~ ^Database= ]]; then
                old_db="${part#Database=}"
            elif [[ "$part" =~ ^Username= ]]; then
                old_user="${part#Username=}"
            elif [[ "$part" =~ ^Password= ]]; then
                old_password="${part#Password=}"
            else
                # Preserve other parameters (Pooling, MinPoolSize, MaxPoolSize, etc.)
                other_params+=("$part")
            fi
        done
    fi
    
    # Use new values, fallback to old values, then defaults
    local final_host="${new_host:-$old_host}"
    local final_port="${old_port:-5432}"
    local final_db="${new_db:-$old_db}"
    local final_user="${new_username:-$old_user:-postgres}"
    local final_password="${new_password:-$old_password}"
    
    # Validate required fields
    if [[ -z "$final_host" || -z "$final_db" || -z "$final_user" || -z "$final_password" ]]; then
        echo -e "\033[91mMissing required database connection parameters for $file_path\033[0m"
        return 1
    fi
    
    # Build new connection string
    local new_conn_str="Host=${final_host};Port=${final_port};Database=${final_db};Username=${final_user};Password=${final_password}"
    
    # Add other connection string parameters if they exist
    for param in "${other_params[@]}"; do
        new_conn_str="${new_conn_str};${param}"
    done
    
    # Update JSON using jq
    local tmp_file
    tmp_file=$(mktemp)
    
    # If ConnectionStrings doesn't exist, create it
    if [[ -z "$has_connection_strings" ]]; then
        # First-time installation: create ConnectionStrings object
        jq --arg conn_str "$new_conn_str" \
           '.ConnectionStrings = {"PostgreConnection": $conn_str}' \
           "$file_path" > "$tmp_file" 2>/dev/null
    else
        # Normal installation: update existing ConnectionStrings
        jq --arg conn_str "$new_conn_str" \
           '.ConnectionStrings.PostgreConnection = $conn_str' \
           "$file_path" > "$tmp_file" 2>/dev/null
    fi
    
    if [[ $? -eq 0 ]]; then
        refreshPermissions "$$" & sudo cp "$tmp_file" "$file_path"
        rm -f "$tmp_file"
        echo -e "\033[92m✅ Updated DB credentials in: $file_path\033[0m"
        return 0
    else
        rm -f "$tmp_file"
        echo -e "\033[91m❌ Failed to update $file_path\033[0m"
        return 1
    fi
}

# Update database credentials in all appsettings files
echo -e "\n\033[1;33mUpdating database connection strings in all appsettings files...\033[0m"
for i in "${appsettings_file_paths[@]}"; do
    update_db_connection_string "$i" "$dbMachineIp" "$DbName" "$DbUsername" "$DbPassword"
done

echo -e "\033[92m\n✅ All appsettings*.json files successfully updated with new DB credentials\033[00m"

# Update redisq Server keys with 127.0.0.1 as it contains hostname
file_pattern="/srv/eye.*/appsettings*.json"
refreshPermissions "$$" & sudo sed -i -E 's/"Server"\s*:\s*"[^"]+"/"Server": "127.0.0.1"/g' $file_pattern 2>/dev/null || true
echo -e "\033[92mAll Message Queue 'Server' keys successfully updated to 127.0.0.1\033[00m"

# Writing the quartz.config
temp_path="/tmp/quartz.config"

cat > "$temp_path" << EOF
org.quartz.threadPool.threadCount = 30
org.quartz.jobStore.class = org.quartz.impl.jdbcjobstore.PostgreSQLDelegate
quartz.jobStore.type = Quartz.Impl.AdoJobStore.JobStoreTX, Quartz
quartz.jobStore.tablePrefix = job_
quartz.jobStore.dataSource = myDS
quartz.dataSource.myDS.connectionString = Host=${dbMachineIp};Port=5432;Database=${DbName};Username=${DbUsername};Password=${DbPassword};Pooling=true;MinPoolSize=1;MaxPoolSize=100;ConnectionLifeTime=0;CommandTimeout=300;Timeout=15
quartz.dataSource.myDS.provider = Npgsql
quartz.serializer.type = json
EOF

# Move to target with sudo
refreshPermissions "$$" & sudo mv "$temp_path" /srv/eye.scheduler/quartz.config

# To check whether the environment Linux or WSL and handle multiple IP's.
if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
    echo -e "\033[92m\nThe Current environment is a WSL (Windows Subsystem for Linux).\033[00m"
    # Fetching IP address in WSL environment
    # Detect PowerShell binary (Windows via WSL)
    PWSH_PATHS=(
        "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
        "/mnt/c/Program Files/PowerShell/7/pwsh.exe"
    )

    POWERSHELL_PATH=""
    for p in "${PWSH_PATHS[@]}"; do
        [[ -x "$p" ]] && POWERSHELL_PATH="$p" && break
    done

    ips=()

    if [[ -n "$POWERSHELL_PATH" ]]; then
        # Run PowerShell safely (no eval, no noise)
        output=$(
            "$POWERSHELL_PATH" -Command \
            "(Get-NetAdapter | Where-Object Status -eq 'Up' |
            ForEach-Object {
                Get-NetIPAddress -InterfaceIndex \$_.IfIndex -AddressFamily IPv4
            }).IPAddress" 2>/dev/null
        )

        # Normalize output
        read -ra ips <<< "$(echo "$output" | tr -d '\r' | tr '\n' ' ')"
    fi

    # No IPs detected → ask user directly
    if [[ ${#ips[@]} -eq 0 ]]; then
        read -rp "Unable to auto-detect Windows IP. Please enter the IP address manually: " Ip
        export Ip
        return 0
    fi

    # Single IP → auto select
    if [[ ${#ips[@]} -eq 1 ]]; then
        Ip="${ips[0]}"
        echo -e "\nAvailable Windows Machine IP Address: \033[1;32m$Ip\033[0m"
        export Ip
        return 0
    fi

    # Multiple IPs → let user choose
    echo "Available IP Addresses on Windows:"
    for i in "${!ips[@]}"; do
        echo "[$i] ${ips[$i]}"
    done

    while true; do
        read -rp "Select IP to host the application (enter number): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice < ${#ips[@]} )); then
            Ip="${ips[$choice]}"
            echo -e "\nSelected IP Address: \033[1;32m$Ip\033[0m"
            export Ip
            break
        fi
        echo "Invalid selection. Try again."
    done
else
    echo -e "\033[92m\nThe Current environment is a Native Linux.\033[00m"
    # Fetching IP address in the native Linux environment
    result=$(hostname -I 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$result" ]; then
        read -ra ip_addresses <<< "$result"
        # Ensure there's at least one IP address
        if [ ${#ip_addresses[@]} -gt 0 ]; then
            Ip="${ip_addresses[0]}"
            echo -e "\nIP Address found on Linux machine: \033[92m${Ip}\033[00m"
        else
            echo -e "\033[91m\nNo IP addresses found on the Linux machine.\nQuitting the Process!\033[00m"
            exit 1
        fi
    else
        echo -e "\033[91m\nError fetching IP address on the Linux machine.\nQuitting the Process!\033[00m"
        exit 1
    fi
fi

date=$(date -u '+%Y-%m-%d %H:%M:%S')

# Updating 'worker_connections' based on no.of.cores of machine and uncommenting the 'multiconnections' nginx.conf file
no_cpu_cores=$(nproc)
no_worker_conn=$((no_cpu_cores * 512))
echo -e "Configuring the 'worker_connections' settings of nginx.conf file with new value:\033[92m${no_worker_conn}\033[00m"
refreshPermissions "$$" & sudo sed -i -E "s/(worker_connections )[0-9]+;/\1${no_worker_conn};/; s/#( multi_accept on;)/\1/" /etc/nginx/nginx.conf

# Updating time zone details as per system location, into eye.notifier > appsettings.json and appsettings.Development.json
# time_zone=$(timedatectl | awk '/Time zone:/ {gsub(/\"/, ""); print $3}')
# time_zone_id=$(timedatectl | awk '/Local time:/ {gsub(/\"/, ""); print $6}')
time_zone=$(timedatectl show -p Timezone --value)
time_zone_id=$(timedatectl show -p Timezone --value)
if [[ -f /srv/eye.notifier/appsettings.json ]]; then
    refreshPermissions "$$" & sudo sed -i -E "s|\"TimeZone\": \"[^\"]*\"|\"TimeZone\": \"${time_zone_id}\"|; s|\"TimeZoneId\": \"[^\"]*\"|\"TimeZoneId\": \"${time_zone}\"|" /srv/eye.notifier/appsettings.json
fi
if [[ -f /srv/eye.notifier/appsettings.Development.json ]]; then
    refreshPermissions "$$" & sudo sed -i -E "s|\"TimeZone\": \"[^\"]*\"|\"TimeZone\": \"${time_zone_id}\"|; s|\"TimeZoneId\": \"[^\"]*\"|\"TimeZoneId\": \"${time_zone}\"|" /srv/eye.notifier/appsettings.Development.json
fi

# Updating the file paths in configuration files
# Getting the current user
user=$(whoami)

# # Desired paths
# report_path="/home/$user/gw-rmon/db/"
# nameplate_path="/home/$user/gw-rmon/db/"
# upload_path="/home/$user/gw-rmon/db/"
# expected_path="/home/$user/gw-rmon/db/"
# pivotExportPath="/home/$user/gw-rmon/db/"
# json_paths=('/var/www/eye.api/appsettings.json' '/var/www/eye.api/appsettings.Development.json')
# syslog_path="/home/$user/rmeye_logs/"

# # Paths to check
# paths_to_check=("$report_path" "$nameplate_path" "$upload_path" "$expected_path" "$pivotExportPath" "$syslog_path")

# # Create required directories if missing
# for path in "${paths_to_check[@]}"; do
#     if [ ! -d "$path" ]; then
#         echo -e "Creating path \033[92m'${path}'\033[00m!"
#         refreshPermissions "$$" & sudo mkdir -p "$path"
#         refreshPermissions "$$" & sudo chown -R "$user:www-data" "$path"
#         refreshPermissions "$$" & sudo chmod -R 777 "$path"
#         echo "Desired Path created successfully!"
#     fi
# done

# Move report files and update .env (only once)
echo "Updating .env file with reports folder path..."
refreshPermissions "$$" & sudo sed -i "s|^REPORT_FOLDER=.*|REPORT_FOLDER='${report_path}'|" /srv/eye-reports-ui/.env

# Update JSON files
for json_file in "${json_paths[@]}"; do
    if [ -f "$json_file" ]; then
        tmp_file=$(mktemp)
        jq --arg nameplate_path "$nameplate_path" \
           --arg upload_path "$upload_path" \
           --arg expected_path "$expected_path" \
           --arg pivotExportPath "$pivotExportPath" \
           'if .NameplateImagePath then .NameplateImagePath.Filepath = $nameplate_path else . end |
            if .UploadFolder then .UploadFolder.Filepath = $upload_path else . end |
            if .TrendsDataPivotExportPath then .TrendsDataPivotExportPath.Filepath = $pivotExportPath else . end |
            if .PrpdFilePath then .PrpdFilePath.FilePath = $expected_path else . end' \
           "$json_file" > "$tmp_file"
        
        # Copy preserving ownership
        refreshPermissions "$$" & sudo cp "$tmp_file" "$json_file"
        rm -f "$tmp_file"
        
        echo "Updated ${json_file} successfully."
    fi
done

# Update the installation time in config.js
refreshPermissions "$$" & sudo sed -i "s|^.*INSTALLATION_TIME:.*$|    INSTALLATION_TIME: '${date}'|g" /var/www/eye-ui/assets/config.js

# updating company name
refreshPermissions "$$" & sudo sed -i "s/COMPANY_NAME : .*/COMPANY_NAME : '${cmp}',/" /var/www/eye-ui/assets/config.js

# update Cross origin values on eyeapi & eyecommunicator appsettings json
if [[ "$redund_flag" == "true" ]]; then
    new_url=""
    read -p "Enter your domain (e.g. rmeye.com): " domain
    domain=$(echo "$domain" | xargs)
    new_url="$domain"
    # New CORS entries to append
    append_values="http://${domain};http://${user};http://${Ip}"
    # Escape special characters for sed
    append_values_esc=$(echo "$append_values" | sed 's|/|\\/|g; s|&|\\&|g; s|\$|\\$|g')
    # update for each filepath
    cros_origin_file_paths=(
        "/var/www/eye.api/appsettings.json"
        "/var/www/eye.api/appsettings.Development.json"
        "/srv/eye.communicator/appsettings.json"
        "/srv/eye.communicator/appsettings.Development.json"
    )
    for i in "${cros_origin_file_paths[@]}"; do
        if [ -f "$i" ]; then
            refreshPermissions "$$" & sudo sed -i -E "s/(\"CrosOrigins\"\\s*:\\s*\"[^\"]*)/\\1;${append_values_esc}/" "$i" || {
                echo -e "\033[91m❌ Failed to update $i\033[00m"
                exit 1
            }
        fi
    done
    echo -e "\033[92m✅ CrosOrigins values updated for eyeapi & eyecommunicator appsettings.json files\033[00m"
fi

# Updating RMEYE website URL in the config.js and appsettings.json of eyeapi based on user input after copying the eye-ui and eye.api dir's into root
if [[ "$configure_url" == '3' ]]; then
    refreshPermissions "$$" & sudo sed -i "2s|.*|      API_URL: 'http://${Ip}/api',|g" /var/www/eye-ui/assets/config.js
    refreshPermissions "$$" & sudo sed -i "3s|.*|      WS_URL: 'http://${Ip}/notify',|g" /var/www/eye-ui/assets/config.js
    refreshPermissions "$$" & sudo sed -i "s|\"VerificationMobileUrlRoot\": \"http://[^\"]*\"|\"VerificationMobileUrlRoot\": \"http://${Ip}\"|" /var/www/eye.api/appsettings.json
    refreshPermissions "$$" & sudo sed -i "s|\"VerificationUrlRoot\": \"http://[^\"]*\"|\"VerificationUrlRoot\": \"http://${Ip}\"|" /var/www/eye.api/appsettings.json
    if [[ -f /var/www/eye.api/appsettings.Development.json ]]; then
        refreshPermissions "$$" & sudo sed -i "s|\"VerificationMobileUrlRoot\": \"http://[^\"]*\"|\"VerificationMobileUrlRoot\": \"http://${Ip}\"|" /var/www/eye.api/appsettings.Development.json
        refreshPermissions "$$" & sudo sed -i "s|\"VerificationUrlRoot\": \"http://[^\"]*\"|\"VerificationUrlRoot\": \"http://${Ip}\"|" /var/www/eye.api/appsettings.Development.json
        refreshPermissions "$$" & sudo sed -i "s|\"Eyeurl\": \"http://[^\"]*\"|\"Eyeurl\": \"http://${Ip}\"|" /var/www/eye.api/appsettings.Development.json
    fi
    refreshPermissions "$$" & sudo sed -i "s|\"Eyeurl\": \"http://[^\"]*\"|\"Eyeurl\": \"http://${Ip}\"|" /var/www/eye.api/appsettings.json
    url_configured=$(cat /var/www/eye-ui/assets/config.js | awk -F"'" '/API_URL/ {print $2}' | sed 's|/api$||')
    echo -e "\nThe URL to acess RMEYE website is \033[92m${url_configured}\033[00m"
elif [[ "$configure_url" == "1" || "$configure_url" == "2" || -z "$configure_url" ]]; then
    refreshPermissions "$$" & sudo sed -i "2s|.*|      API_URL: 'http://${new_url}/api',|g" /var/www/eye-ui/assets/config.js
    refreshPermissions "$$" & sudo sed -i "3s|.*|      WS_URL: 'http://${new_url}/notify',|g" /var/www/eye-ui/assets/config.js
    refreshPermissions "$$" & sudo sed -i "s|\"VerificationMobileUrlRoot\": \"http://[^\"]*\"|\"VerificationMobileUrlRoot\": \"http://${new_url}\"|" /var/www/eye.api/appsettings.json
    refreshPermissions "$$" & sudo sed -i "s|\"VerificationUrlRoot\": \"http://[^\"]*\"|\"VerificationUrlRoot\": \"http://${new_url}\"|" /var/www/eye.api/appsettings.json
    if [[ -f /var/www/eye.api/appsettings.Development.json ]]; then
        refreshPermissions "$$" & sudo sed -i "s|\"VerificationMobileUrlRoot\": \"http://[^\"]*\"|\"VerificationMobileUrlRoot\": \"http://${new_url}\"|" /var/www/eye.api/appsettings.Development.json
        refreshPermissions "$$" & sudo sed -i "s|\"VerificationUrlRoot\": \"http://[^\"]*\"|\"VerificationUrlRoot\": \"http://${new_url}\"|" /var/www/eye.api/appsettings.Development.json
        refreshPermissions "$$" & sudo sed -i "s|\"Eyeurl\": \"http://[^\"]*\"|\"Eyeurl\": \"http://${new_url}\"|" /var/www/eye.api/appsettings.Development.json
    fi
    refreshPermissions "$$" & sudo sed -i "s|\"Eyeurl\": \"http://[^\"]*\"|\"Eyeurl\": \"http://${new_url}\"|" /var/www/eye.api/appsettings.json
    url_configured=$(cat /var/www/eye-ui/assets/config.js | awk -F"'" '/API_URL/ {print $2}' | sed 's|/api$||')
    echo -e "\nThe URL to acess RMEYE website is \033[92m${url_configured}\033[00m"
fi

# updating installed time.json
refreshPermissions "$$" & sudo sed -i 's/"installationTime":"debugTime"/"installationTime":"'"$date"'"/' /var/www/eye-ui/assets/installedTime.json

# Updating time zone details as per system location, into eye.notifier > appsettings.json and appsettings.Development.json
time_zone_id=$(timedatectl | awk '/Time zone:/ {print $3}')
time_zone=$(timedatectl | awk '/Local time:/ {print $6}')
if [[ -f /srv/eye.notifier/appsettings.json ]]; then
    refreshPermissions "$$" & sudo sed -i -E "s|\"TimeZone\": \"[^\"]*\"|\"TimeZone\": \"${time_zone}\"|; s|\"TimeZoneId\": \"[^\"]*\"|\"TimeZoneId\": \"${time_zone_id}\"|" /srv/eye.notifier/appsettings.json
fi
if [[ -f /srv/eye.notifier/appsettings.Development.json ]]; then
    refreshPermissions "$$" & sudo sed -i -E "s|\"TimeZone\": \"[^\"]*\"|\"TimeZone\": \"${time_zone}\"|; s|\"TimeZoneId\": \"[^\"]*\"|\"TimeZoneId\": \"${time_zone_id}\"|" /srv/eye.notifier/appsettings.Development.json
fi

# Updating filepaths in configuration files (appsettings & .env)
user=$(whoami)
expected_path="/home/$user/gw-rmon/db/"
syslog_path="/home/$user/rmeye_logs/"
json_paths=(
    "/var/www/eye.api/appsettings.json"
    "/var/www/eye.api/appsettings.Development.json"
)

paths_to_check=("$expected_path" "$syslog_path")

# Create directories if not present
for path in "${paths_to_check[@]}"; do
    if [ ! -d "$path" ]; then
        echo -e "Creating path \e[1;32m'$path'\e[0m"
        sudo mkdir -p "$path"
        sudo chown -R "$user:www-data" "$path"
        sudo chmod -R 755 "$path"
    fi
done

# Update .env file
echo "Updating .env file with db folder path..."
sudo sed -i "s|^REPORT_FOLDER=.*|REPORT_FOLDER='$expected_path'|" /srv/eye-reports-ui/.env

# Update JSON files while preserving ownership
for json_file in "${json_paths[@]}"; do
    if [ -f "$json_file" ]; then
        echo "Updating $json_file..."

        # Validate JSON first
        if ! jq empty "$json_file" 2>/dev/null; then
            echo -e "\e[1;31mError: Invalid JSON in $json_file. Exiting.\e[0m"
            exit 1
        fi

        # Create temp file in user's home directory
        tmp_file="/home/$user/$(basename "$json_file").tmp"
        
        # Update JSON and save to temp file
        jq --arg expected_path "$expected_path" \
           '
           if .NameplateImagePath then .NameplateImagePath.Filepath = $expected_path else . end |
           if .UploadFolder then .UploadFolder.Filepath = $expected_path else . end |
           if .TrendsDataPivotExportPath then .TrendsDataPivotExportPath.Filepath = $expected_path else . end |
           if .PrpdFilePath then .PrpdFilePath.FilePath = $expected_path else . end
           ' "$json_file" > "$tmp_file"

        # Copy temp file to original location to preserve ownership
        sudo cp "$tmp_file" "$json_file"
        
        # Clean up temp file
        rm -f "$tmp_file"

        echo "Updated file paths in $json_file successfully."
    elif [[ "$json_file" == *appsettings.Development.json ]]; then
        echo -e "\033[93mSkipping optional path updates for missing file: $json_file\033[0m"
    else
        echo "Error!: File $json_file not found! Exiting..."
        exit 1
    fi
done

# updating favicon for GANZ
if [[ "$cmp" == 'GANZ' ]]; then
    refreshPermissions "$$" & sudo mv /var/www/eye-ui/assets/favicons/faviconGanz.ico /var/www/eye-ui/assets/favicons/favicon.ico 2>/dev/null || true
fi

# Copying maps if any
map_source_dir="/home/$user/maps"
if [ -d "$map_source_dir" ]; then
    echo "Copying maps from $map_source_dir to /var/www/eye-ui/assets ..."
    refreshPermissions "$$" & sudo cp -rf "$map_source_dir" /var/www/eye-ui/assets/ 2>/dev/null || true
else
    echo "No maps directory found at $map_source_dir. Skipping map copy."
    mkdir -p "$map_source_dir"
    echo "Created maps directory at $map_source_dir."
fi

# Copying the Files that are specific
echo "Copying backup files ..."
file_path="/home/$user/backupFiles/filesTobeCp.txt"
backup_dir=$(dirname "$file_path")
if [ ! -f "$file_path" ]; then
    mkdir -p "$backup_dir"
    echo "backupFiles folder not available, creating.."
    touch "$file_path"
    echo "File 'filesTobeCp.txt' created."
fi

if [ -f "$file_path" ]; then
    copy_specific_files_from_list "$file_path" "$(pwd)" "$user"
fi

# update syslog paths
home=$(eval echo ~$user)

# Update syslog paths in all appsettings files
sed_cmd="sudo sed -i -E \"s|\\\"path\\\": *\\\"[^\\\"]*/rmeye_logs/([^\\\"/]+)\\\"|\\\"path\\\": \\\"${home}/rmeye_logs/\\1\\\"|g\" /var/www/eye*/appsettings*.json /srv/eye*/appsettings*.json"
eval "$sed_cmd" 2>/dev/null && echo "✅ RMEYE logs path have been updated successfully in all appsettings files." || echo "❌ sed execution failed."

# Daemon Reload
echo "Enabling the services..."
refreshPermissions "$$" & sudo systemctl daemon-reload
for service in "${services[@]}"; do
    refreshPermissions "$$" & sudo systemctl enable "kestrel-${service}"
done

# Restarting the Nginx
echo "Starting the services ..."
refreshPermissions "$$" & sudo service nginx restart
for service in "${services[@]}"; do
    refreshPermissions "$$" & sudo service "kestrel-${service}" start
done

# Removing the backup of maps if they exist
# refreshPermissions "$$" & sudo rm -rf maps/ 2>/dev/null || true

# TO Check if all the services are running
for service in "${services[@]}"; do
    if systemctl is-active --quiet "kestrel-${service}"; then
        echo -e "\033[92m kestrel-${service} is running\033[00m"
    else
        echo -e "\033[91m kestrel-${service} is NOT running\033[00m"
    fi
done

echo -e '\033[0;37m'

# Log the build upgrade
directory_path=$(pwd)
folder_name=$(basename "$directory_path")
current_user=$(whoami)
user_home=$(getent passwd "$current_user" | cut -d: -f6)

# Ensure user_home is set (fallback to ~ if getent fails)
if [[ -z "$user_home" ]]; then
    user_home="$HOME"
fi

# If still empty, try eval
if [[ -z "$user_home" ]]; then
    user_home=$(eval echo ~"$current_user")
fi

build_log_file="${user_home}/build-log"
log_entry="$(date '+%Y-%m-%d %H:%M:%S') : $folder_name"

# Create build-log file in user's home directory with proper permissions
if [[ -n "$user_home" && -d "$user_home" ]]; then
    # Create file if it doesn't exist
    if [[ ! -f "$build_log_file" ]]; then
        if ! touch "$build_log_file" 2>/dev/null; then
            # If touch fails due to permissions, try with sudo and fix ownership
            refreshPermissions "$$" & 
            PID=$!
            sudo touch "$build_log_file" 2>/dev/null && \
            sudo chown "$current_user:$current_user" "$build_log_file" 2>/dev/null
            kill "$PID" 2>/dev/null || true
        fi
    fi
    
    # Ensure file is writable by the user
    if [[ -f "$build_log_file" ]]; then
        # Fix ownership if needed (check without sudo first)
        file_owner=$(stat -c '%U' "$build_log_file" 2>/dev/null || stat -f '%Su' "$build_log_file" 2>/dev/null || echo "")
        if [[ -n "$file_owner" && "$file_owner" != "$current_user" ]]; then
            refreshPermissions "$$" & 
            PID=$!
            sudo chown "$current_user:$current_user" "$build_log_file" 2>/dev/null || true
            kill "$PID" 2>/dev/null || true
        fi
        
        # Ensure write permissions
        if ! chmod 644 "$build_log_file" 2>/dev/null; then
            refreshPermissions "$$" & 
            PID=$!
            sudo chmod 644 "$build_log_file" 2>/dev/null || true
            kill "$PID" 2>/dev/null || true
        fi
        
        # Write to build-log
        if echo "$log_entry" >> "$build_log_file" 2>/dev/null; then
            echo -e "\033[92mBuild log file updated: $build_log_file\033[0m"
        else
            # If write fails, try with sudo and fix permissions
            refreshPermissions "$$" & 
            PID=$!
            echo "$log_entry" | sudo tee -a "$build_log_file" > /dev/null 2>&1 && \
            sudo chown "$current_user:$current_user" "$build_log_file" 2>/dev/null || true
            kill "$PID" 2>/dev/null || true
            echo -e "\033[93mBuild log file updated with elevated permissions: $build_log_file\033[0m"
        fi
    else
        echo -e "\033[91mWarning: Could not create build-log file at $build_log_file\033[0m"
    fi
else
    echo -e "\033[91mWarning: Could not determine user home directory for build-log\033[0m"
fi

# stop watchdog & patroni services again (redundancy)
# if [[ "$redund_flag" == "true" ]]; then
#     redund_services=("kestrel-eyewatchdog" "patroni")
#     for ser in "${redund_services[@]}"; do
#         refreshPermissions "$$" & sudo service "$ser" stop
#         status=$(systemctl is-active "$ser")
#         if [[ "$status" == "inactive" ]]; then
#             echo "Successfully stopped $ser"
#         else
#             echo "Failed to stop $ser!"
#             exit 1
#         fi
#     done
# fi

# run redund.py after build installation
if [[ "$redund_flag" == "true" ]]; then
    redund_services=("kestrel-eyewatchdog" "patroni")

    # stop watchdog & patroni before execution of redund.py
    if [[ "$first_time_redund_installation" == "false" ]]; then
        for ser in "${redund_services[@]}"; do
            stop_redundant_services "$ser"
        done
    fi
    
    if [ -f "external_scripts/redund.py" ]; then
        refreshPermissions "$$" & sudo python3 external_scripts/redund.py || {
            echo -e "\033[91mRedundancy script failed\033[0m"
            exit 1
        }
    fi

    main_patroni_installation

    # start watchdog & patroni after execution of redund.py
    echo -e "\n\033[1;33m🚀 Starting redundancy services...\033[0m"
    for ser in "${redund_services[@]}"; do
        start_redundant_services "$ser"
    done
fi
