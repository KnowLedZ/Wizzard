#!/bin/bash

set -e

MAIN_LOG="/var/log/aapanel-install.log"
BOOTSTRAP_LOG="/var/log/bootstrap-aapanel.log"

exec > >(tee -a "$MAIN_LOG") 2>&1

# ==============================
# SPINNER
# ==============================
spinner() {
    local pid=$1
    local msg=$2
    local spin='-\|/'
    local i=0

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r[INFO] %s... %s" "$msg" "${spin:$i:1}"
        sleep 0.2
    done

    printf "\r"
}

# ==============================
# WAIT APT LOCK (unlimited, spinner)
# Dipanggil sebelum SETIAP apt-get command
# ==============================
wait_apt_lock() {
    local label="${1:-apt}"

    # Kalau bukan apt system, skip
    [ ! -f "/usr/bin/apt-get" ] && return 0

    # Cek apakah ada lock aktif dulu sebelum spin
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && \
       ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1 && \
       ! fuser /var/lib/dpkg/lock >/dev/null 2>&1 && \
       ! fuser /var/cache/apt/archives/lock >/dev/null 2>&1; then
        return 0
    fi

    local spin='-\|/'
    local i=0
    local elapsed=0

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        i=$(( (i+1) % 4 ))
        printf "\r[WAIT] %s locked... %s (%ds elapsed)" "$label" "${spin:$i:1}" "$elapsed"
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done

    printf "\r%-70s\r" " "
}

# ==============================
# KILL PROSES YANG BLOCK APT
# (unattended-upgrades, apt-get dist-upgrade dari cloud-init)
# ==============================
kill_apt_blockers() {
    [ ! -f "/usr/bin/apt-get" ] && return 0

    # Nonaktifkan unattended-upgrades sementara
    systemctl stop unattended-upgrades 2>/dev/null || true
    systemctl disable unattended-upgrades 2>/dev/null || true

    # Kill proses apt/dpkg yang berjalan (selain proses kita sendiri)
    local BLOCKER_PIDS
    BLOCKER_PIDS=$(ps aux | grep -E '(apt-get|apt |dpkg)' | grep -v grep | grep -v $$ | awk '{print $2}')
    if [ -n "$BLOCKER_PIDS" ]; then
        echo "[INFO] Menunggu proses apt selesai..."
        # Tunggu dulu secara graceful, jangan langsung kill
        for pid in $BLOCKER_PIDS; do
            # Tunggu max 120 detik per proses
            local w=0
            while kill -0 "$pid" 2>/dev/null && [ $w -lt 120 ]; do
                printf "\r[WAIT] Menunggu PID %s selesai... (%ds)" "$pid" "$w"
                sleep 2
                w=$(( w + 2 ))
            done
            printf "\r%-70s\r" " "
            # Kalau masih jalan setelah timeout, baru kill
            if kill -0 "$pid" 2>/dev/null; then
                echo "[INFO] Terminating stuck apt process PID $pid"
                kill -9 "$pid" 2>/dev/null || true
            fi
        done
    fi

    # Hapus lock file yang mungkin ditinggal
    rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
    rm -f /var/lib/dpkg/lock 2>/dev/null || true
    rm -f /var/cache/apt/archives/lock 2>/dev/null || true

    # Repair dpkg jika perlu
    dpkg --configure -a >> "$MAIN_LOG" 2>&1 || true

    echo "[OK] apt ready"
}

# ==============================
# RUN APT DENGAN AUTO WAIT LOCK
# ==============================
run_apt() {
    local MSG="$1"
    shift

    wait_apt_lock "$MSG"

    DEBIAN_FRONTEND=noninteractive "$@" >> "$MAIN_LOG" 2>&1 &
    local PID=$!

    spinner $PID "$MSG"
    wait $PID
    local EXIT_CODE=$?

    if [ $EXIT_CODE -ne 0 ]; then
        echo "[ERROR] $MSG failed! (exit $EXIT_CODE)"
        echo "[INFO] Check log: $MAIN_LOG"
        exit 1
    fi

    echo "[OK] $MSG"
}

# ==============================
# RUN GENERIC DENGAN SPINNER
# ==============================
run_step() {
    local MSG="$1"
    shift

    "$@" >> "$MAIN_LOG" 2>&1 &
    local PID=$!

    spinner $PID "$MSG"
    wait $PID
    local EXIT_CODE=$?

    if [ $EXIT_CODE -ne 0 ]; then
        echo "[ERROR] $MSG failed! (exit $EXIT_CODE)"
        echo "[INFO] Check log: $MAIN_LOG"
        exit 1
    fi

    echo "[OK] $MSG"
}

# ==============================
# DETECT OS & PACKAGE MANAGER
# ==============================
detect_os() {
    if [ -f "/usr/bin/yum" ] && [ -d "/etc/yum.repos.d" ]; then
        PM="yum"
    elif [ -f "/usr/bin/apt-get" ] && [ -f "/usr/bin/dpkg" ]; then
        PM="apt-get"
    else
        echo "[ERROR] Unsupported package manager"
        exit 1
    fi

    is64bit=$(getconf LONG_BIT)
    if [ "${is64bit}" != '64' ]; then
        echo "[ERROR] aaPanel does not support 32-bit systems"
        exit 1
    fi

    echo "[INFO] OS: $(uname -a)"
    echo "[INFO] Package manager: $PM"
}

# ==============================
# CHECK PANEL PROCESS
# ==============================
check_panel_running() {
    local PID=""

    # Cek semua kemungkinan nama proses aaPanel
    PID=$(ps aux | grep -E 'BT-Panel|btpanel|panel\.py' | grep -v grep | awk '{print $2}' | head -1)

    # Fallback: cek via PID file
    if [ -z "$PID" ]; then
        local PIDFILE="/www/server/panel/logs/panel.pid"
        if [ -f "$PIDFILE" ]; then
            local STORED_PID
            STORED_PID=$(cat "$PIDFILE" 2>/dev/null)
            [ -n "$STORED_PID" ] && kill -0 "$STORED_PID" 2>/dev/null && PID="$STORED_PID"
        fi
    fi

    # Fallback: cek via port yang sedang listen
    if [ -z "$PID" ]; then
        local PORT
        PORT=$(cat /www/server/panel/data/port.pl 2>/dev/null || echo "")
        if [ -n "$PORT" ]; then
            PID=$(ss -lntp 2>/dev/null | grep ":$PORT" | grep -oP 'pid=\K[0-9]+' | head -1)
        fi
    fi

    echo "$PID"
}

# ==============================
# HEADER
# ==============================
clear
echo "=========================================="
echo "      AAPANEL INSTALLER WIZARD"
echo "=========================================="
echo ""

read -p "Start aaPanel configuration wizard? (Y/n): " CONFIRM
CONFIRM=${CONFIRM:-y}
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && echo "Cancelled." && exit 0

# ==============================
# STEP 1 - PREPARE SYSTEM
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 1/6] Prepare system"
echo "------------------------------------------"

detect_os

if [ "${PM}" = "apt-get" ]; then
    # Bunuh dulu proses apt blocker dari cloud-init/unattended-upgrades
    kill_apt_blockers

    run_apt "Updating apt index" apt-get update -y
    run_apt "Installing dependencies" apt-get install -y \
        wget curl tar unzip openssl ca-certificates git sudo net-tools

elif [ "${PM}" = "yum" ]; then
    run_step "Installing dependencies" yum install -y \
        wget curl tar unzip openssl ca-certificates git sudo net-tools
fi

echo "[OK] System ready"

# ==============================
# STEP 2 - CONFIGURATION INPUT
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 2/6] Configuration setup"
echo "------------------------------------------"
echo ""

# Panel port (default random 10000-65535)
DEFAULT_PORT=$(expr $RANDOM % 55535 + 10000)
read -p "Panel port [$DEFAULT_PORT]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-$DEFAULT_PORT}

# Panel username
read -p "Panel username [admin]: " PANEL_USER
PANEL_USER=${PANEL_USER:-admin}

# Panel password
while true; do
    read -s -p "Panel password: " P1; echo ""
    read -s -p "Re-enter password: " P2; echo ""
    if [[ "$P1" == "$P2" && -n "$P1" ]]; then
        break
    fi
    echo "[ERROR] Password mismatch or empty, try again"
done
PANEL_PASSWORD=$P1

# Safe path (security slug setelah port)
DEFAULT_SAFE=$(cat /dev/urandom | head -n 16 | md5sum | head -c 8)
read -p "Panel safe path [$DEFAULT_SAFE]: " SAFE_PATH
SAFE_PATH=${SAFE_PATH:-$DEFAULT_SAFE}

# SSL
read -p "Enable SSL for panel? (Y/n): " ENABLE_SSL
ENABLE_SSL=${ENABLE_SSL:-y}
SSL_FLAG=""
[[ ! "$ENABLE_SSL" =~ ^[Yy]$ ]] && SSL_FLAG="--ssl-disable"

echo ""
echo "[INFO] Configuration summary:"
echo "  Panel port  : $PANEL_PORT"
echo "  Username    : $PANEL_USER"
echo "  Safe path   : /$SAFE_PATH"
echo "  SSL enabled : $([[ -z $SSL_FLAG ]] && echo yes || echo no)"
echo ""

# ==============================
# STEP 3 - PREPARE ENVIRONMENT
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 3/6] Prepare environment"
echo "------------------------------------------"

INSTALL_SCRIPT="/root/aapanel-installer.sh"

(
    curl -sSL -o "$INSTALL_SCRIPT" \
        "https://raw.githubusercontent.com/KnowLedZ/Wizzard/main/aapanel-install.sh" \
        2>>"$MAIN_LOG" || \
    curl -sSL -o "$INSTALL_SCRIPT" \
        "https://www.aapanel.com/script/install_7.0_en.sh" \
        2>>"$MAIN_LOG"
) &

DL_PID=$!
spinner $DL_PID "Downloading installer"
wait $DL_PID
DL_EXIT=$?

if [ $DL_EXIT -ne 0 ] || [ ! -s "$INSTALL_SCRIPT" ]; then
    echo "[ERROR] Failed to download aaPanel installer"
    exit 1
fi

chmod +x "$INSTALL_SCRIPT"
echo "[OK] Installer downloaded"

# ==============================
# STEP 4 - RUNNING INSTALLER
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 4/6] Running aaPanel installer"
echo "------------------------------------------"
echo "[INFO] This may take several minutes..."
echo ""

(
    PANEL_PORT="$PANEL_PORT" \
    PANEL_USER="$PANEL_USER" \
    PANEL_PASSWORD="$PANEL_PASSWORD" \
    SAFE_PATH="$SAFE_PATH" \
        bash "$INSTALL_SCRIPT" $SSL_FLAG -y >> "$MAIN_LOG" 2>&1
) &

INST_PID=$!
spinner $INST_PID "Installing aaPanel"
wait $INST_PID
INST_EXIT=$?

if [ $INST_EXIT -ne 0 ]; then
    echo "[ERROR] aaPanel installer failed! (exit $INST_EXIT)"
    echo "[INFO] Check log: $MAIN_LOG"
    exit 1
fi

echo "[OK] aaPanel installed"

# ==============================
# STEP 5 - WAITING PANEL
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 5/6] Waiting for panel"
echo "------------------------------------------"

ELAPSED=0
spin='-\|/'
si=0

while true; do
    si=$(( (si+1) % 4 ))
    PANEL_PID=$(check_panel_running)

    printf "\r[INFO] Panel: %-10s %s (%ds)" \
        "$( [ -n "$PANEL_PID" ] && echo "running" || echo "starting" )" \
        "${spin:$si:1}" \
        "$ELAPSED"

    if [ -n "$PANEL_PID" ]; then
        printf "\r%-70s\r" " "
        echo "[OK] Panel running (PID: $PANEL_PID, ${ELAPSED}s)"
        break
    fi

    sleep 2
    ELAPSED=$(( ELAPSED + 2 ))
done

# ==============================
# STEP 6 - FINALIZING
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 6/6] Finalizing"
echo "------------------------------------------"

# Baca port aktual dari file panel
PANEL_PORT_FILE=$(cat /www/server/panel/data/port.pl 2>/dev/null || echo "$PANEL_PORT")

# Verify port dengan spinner
PORT_OPEN=false
spin='-\|/'
si=0
for i in $(seq 1 10); do
    si=$(( (si+1) % 4 ))
    if ss -lnt 2>/dev/null | grep -q ":${PANEL_PORT_FILE}" || \
       netstat -lnt 2>/dev/null | grep -q ":${PANEL_PORT_FILE}"; then
        PORT_OPEN=true
        break
    fi
    printf "\r[WAIT] Checking port %s... %s (%d/10)" \
        "$PANEL_PORT_FILE" "${spin:$si:1}" "$i"
    sleep 2
done
printf "\r%-70s\r" " "

# Get public IP only
IP_PUBLIC=$(curl -4 -sS --connect-timeout 10 -m 15 https://ifconfig.me 2>/dev/null || \
            curl -4 -sS --connect-timeout 10 -m 15 https://api.ipify.org 2>/dev/null || \
            curl -4 -sS --connect-timeout 10 -m 15 https://icanhazip.com 2>/dev/null || \
            echo "YOUR_SERVER_IP")

# Baca safe path aktual dari file panel
AUTH_PATH=$(cat /www/server/panel/data/admin_path.pl 2>/dev/null || echo "/$SAFE_PATH")

echo "[INFO] Process status:"
ps aux | grep -E 'BT-Panel|btpanel|panel\.py' | grep -v grep || true

# ==============================
# DONE
# ==============================
echo ""
echo "======================================"
echo "      INSTALLATION COMPLETE"
echo "======================================"
echo ""
echo "URL:"
echo "  http://${IP_PUBLIC}:${PANEL_PORT_FILE}${AUTH_PATH}"
echo ""
echo "CREDENTIALS:"
echo "  Username : $PANEL_USER"
echo "  Password : $PANEL_PASSWORD"
echo ""
echo "PORT STATUS:"
if [ "$PORT_OPEN" = true ]; then
    echo "  [OK] Port $PANEL_PORT_FILE is open"
else
    echo "  [WARNING] Port $PANEL_PORT_FILE belum terbuka!"
    echo "  [INFO] Cek firewall / security group"
fi
echo ""
echo "LOG:"
echo "  Main : $MAIN_LOG"
echo ""
echo "======================================"

# ==============================
# CLEANUP & BOOTSTRAP LOG
# ==============================
echo "" >> "$BOOTSTRAP_LOG"
echo "[INFO] Bootstrap selesai: $(date)" >> "$BOOTSTRAP_LOG"

echo "[OK] Bootstrap selesai"
echo "[INFO] Log: $BOOTSTRAP_LOG"
