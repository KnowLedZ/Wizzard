#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/n8n-install.log"
DOCKER_LOG="/var/log/n8n-docker.log"

exec > >(tee -a "$LOG_FILE") 2>&1

# ==============================
# SPINNER
# ==============================
spinner() {
    local msg="$1"
    local spin='-\|/'
    local i=0

    while true; do
        i=$(( (i+1) %4 ))
        printf "\r[%c] %s" "${spin:$i:1}" "$msg"
        sleep 0.2
    done
}

# ==============================
# RUN BACKGROUND + SPINNER
# ==============================
run_with_spinner() {
    DESC="$1"
    shift

    echo ""
    echo "======================================"
    echo "[...] $DESC"
    echo "======================================"

    "$@" >> "$LOG_FILE" 2>&1 &
    CMD_PID=$!

    spinner "$DESC..." &
    SPIN_PID=$!

    wait $CMD_PID
    RESULT=$?

    kill $SPIN_PID >/dev/null 2>&1 || true
    printf "\r"

    if [ $RESULT -ne 0 ]; then
        echo "[ERROR] $DESC gagal"
        echo "[INFO] Check log: $LOG_FILE"
        exit 1
    fi

    echo "[OK] $DESC"
}

# ==============================
# RUN FOREGROUND (CRITICAL)
# ==============================
run_fg() {
    DESC="$1"
    shift

    echo ""
    echo "======================================"
    echo "[...] $DESC"
    echo "======================================"

    if "$@" | tee -a "$LOG_FILE"; then
        echo "[OK] $DESC"
    else
        echo "[ERROR] $DESC gagal"
        exit 1
    fi
}

clear
echo "----------------------------------------"
echo "   N8N INSTALLER + WIZARD"
echo "----------------------------------------"

# ==============================
# CONFIRM
# ==============================
read -p "Start wizard? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && exit 0

# ==============================
# WAIT APT LOCK (FIXED SPINNER)
# ==============================
echo "[INFO] Waiting apt lock..."

(
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        sleep 2
    done
) &

WAIT_PID=$!

spinner "Waiting apt lock..." &
SPIN_PID=$!

wait $WAIT_PID
kill $SPIN_PID >/dev/null 2>&1 || true
printf "\r"

echo "[OK] apt ready"

# ==============================
# INSTALL DOCKER
# ==============================
run_with_spinner "Download Docker" curl -fsSL https://get.docker.com -o get-docker.sh

run_fg "Install Docker" sh get-docker.sh

echo "[INFO] Starting Docker..."
systemctl start docker || service docker start || true
sleep 2
echo "[OK] Docker ready"

# ==============================
# INPUT
# ==============================
read -p "Domain: " DOMAIN

read -p "POSTGRES_USER: " POSTGRES_USER

while true; do
    read -s -p "POSTGRES_PASSWORD: " P1; echo ""
    read -s -p "Re-enter: " P2; echo ""
    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo "[ERROR] Password mismatch"
done

POSTGRES_PASSWORD=$P1

read -p "POSTGRES_DB: " POSTGRES_DB
read -p "POSTGRES_NON_ROOT_USER: " POSTGRES_NON_ROOT_USER

while true; do
    read -s -p "POSTGRES_NON_ROOT_PASSWORD: " P1; echo ""
    read -s -p "Re-enter: " P2; echo ""
    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo "[ERROR] Password mismatch"
done

POSTGRES_NON_ROOT_PASSWORD=$P1

RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)

INSTALL_DIR="/opt/n8n"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ==============================
# CLONE
# ==============================
run_with_spinner "Clone repo" git clone https://github.com/KnowLedZ/n8n-http.git . || true

IP=$(hostname -I | awk '{print $1}')

# ==============================
# ENV
# ==============================
echo "[INFO] Creating .env"

cat <<EOF > .env
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
POSTGRES_NON_ROOT_USER=$POSTGRES_NON_ROOT_USER
POSTGRES_NON_ROOT_PASSWORD=$POSTGRES_NON_ROOT_PASSWORD

FQDN=$IP

RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN
EOF

echo "[OK] .env ready"

# ==============================
# DOCKER START (CRITICAL)
# ==============================
run_fg "Starting containers" docker compose up -d

# ==============================
# WAIT POSTGRES
# ==============================
echo "[INFO] Waiting PostgreSQL..."

for i in {1..40}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' n8n-postgres-1 2>/dev/null || echo "starting")
    printf "\r[INFO] Postgres: %-10s (%d/40)" "$STATUS" "$i"

    [[ "$STATUS" == "healthy" ]] && break
    sleep 3
done
echo ""

# ==============================
# WAIT N8N
# ==============================
echo "[INFO] Waiting n8n..."

for i in {1..40}; do
    RUNNING=$(docker ps --format '{{.Names}}' | grep -c n8n-n8n-1 || true)
    printf "\r[INFO] n8n: %d (%d/40)" "$RUNNING" "$i"

    [[ "$RUNNING" -ge 1 ]] && break
    sleep 3
done
echo ""

# ==============================
# CLEANUP (SAFE)
# ==============================
echo "[INFO] Cleanup..."
rm -f /root/get-docker.sh
echo "[OK] Cleanup done"

# ==============================
# DONE
# ==============================
echo ""
echo "======================================"
echo "        INSTALLATION COMPLETE"
echo "======================================"

echo "Domain : http://$DOMAIN"
echo "IP     : http://$IP:5678"

echo ""
echo "TOKEN:"
echo "$RUNNERS_AUTH_TOKEN"

echo ""
echo "LOG:"
echo "$LOG_FILE"
echo "$DOCKER_LOG"
