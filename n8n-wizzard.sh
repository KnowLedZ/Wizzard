#!/bin/bash

set -e

MAIN_LOG="/var/log/n8n-install.log"
DOCKER_LOG="/var/log/n8n-docker.log"

exec > >(tee -a "$MAIN_LOG") 2>&1

# ==============================
# SPINNER
# ==============================
spin_wait() {
    local pid=$1
    local msg="$2"
    local spin='-\|/'
    local i=0

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[INFO] %s... %s" "$msg" "${spin:$i:1}"
        sleep 0.2
    done
    printf "\r"
}

run_bg() {
    local msg="$1"
    shift

    "$@" >> "$MAIN_LOG" 2>&1 &
    pid=$!

    spin_wait $pid "$msg"
    wait $pid
}

# ==============================
# WAIT APT
# ==============================
wait_apt() {
    echo "[INFO] Checking apt lock..."

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        printf "\r[INFO] Waiting apt..."
        sleep 1
    done

    echo ""
    echo "[OK] apt ready"
}

# ==============================
# HEADER
# ==============================
clear
echo "=========================================="
echo "         N8N INSTALLER WIZARD"
echo "=========================================="
echo ""

read -p "Start N8N configuration wizard? (Y/n): " CONFIRM
CONFIRM=${CONFIRM:-Y}
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && exit 0

# ==============================
# STEP 1
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 1/6] Prepare system"
echo "------------------------------------------"

wait_apt

run_bg "Download Docker" curl -fsSL https://get.docker.com -o get-docker.sh
run_bg "Install Docker" sh get-docker.sh
run_bg "Start Docker" bash -c "systemctl start docker || service docker start || true"

echo "[OK] Docker ready"

# ==============================
# STEP 2 INPUT
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 2/6] Configuration input"
echo "------------------------------------------"

read -p "Domain: " DOMAIN
read -p "POSTGRES_USER: " POSTGRES_USER

while true; do
    read -s -p "POSTGRES_PASSWORD: " P1; echo ""
    read -s -p "Re-enter password: " P2; echo ""

    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo "[ERROR] Password mismatch"
done

POSTGRES_PASSWORD=$P1

read -p "POSTGRES_DB: " POSTGRES_DB
read -p "POSTGRES_NON_ROOT_USER: " POSTGRES_NON_ROOT_USER

while true; do
    read -s -p "POSTGRES_NON_ROOT_PASSWORD: " P1; echo ""
    read -s -p "Re-enter password: " P2; echo ""

    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo "[ERROR] Password mismatch"
done

POSTGRES_NON_ROOT_PASSWORD=$P1

RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)

# ==============================
# STEP 3 PREPARE
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 3/6] Prepare environment"
echo "------------------------------------------"

INSTALL_DIR="/opt/n8n"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

run_bg "Clone repository" git clone https://github.com/KnowLedZ/n8n-http.git . || true

IP=$(hostname -I | awk '{print $1}')

cat <<EOF > .env
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
POSTGRES_NON_ROOT_USER=$POSTGRES_NON_ROOT_USER
POSTGRES_NON_ROOT_PASSWORD=$POSTGRES_NON_ROOT_PASSWORD
RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN
FQDN=$IP
EOF

echo "[OK] Config ready"

# ==============================
# STEP 4 START CONTAINER
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 4/6] Starting containers"
echo "------------------------------------------"

docker compose up -d >> "$DOCKER_LOG" 2>&1 &
spin_wait $! "Deploying containers"

echo "[OK] Containers created"

# ==============================
# STEP 5 WAIT POSTGRES
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 5/6] Waiting PostgreSQL"
echo "------------------------------------------"

for i in {1..60}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' \
        $(docker ps -a --format '{{.Names}}' | grep postgres | head -n1) \
        2>/dev/null || echo "starting")

    printf "\r[INFO] Postgres: %-10s (%d/60)" "$STATUS" "$i"

    [[ "$STATUS" == "healthy" ]] && break
    sleep 2
done

echo ""
echo "[OK] PostgreSQL ready"

# ==============================
# STEP 6 WAIT N8N REAL READY
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 6/6] Finalizing"
echo "------------------------------------------"

for i in {1..60}; do
    if ss -lnt | grep -q ":5678"; then
        echo "[OK] n8n ready"
        break
    fi

    printf "\r[INFO] Waiting n8n port... (%d/60)" "$i"
    sleep 2
done

# ==============================
# DEBUG CONTAINER
# ==============================
echo ""
echo "[INFO] Container status:"
docker ps

# ==============================
# DONE
# ==============================
echo ""
echo "======================================"
echo "        INSTALLATION COMPLETE"
echo "======================================"

echo "URL:"
echo "Domain : http://$DOMAIN"
echo "IP      : http://$IP:5678"

echo ""
echo "TOKEN:"
echo "$RUNNERS_AUTH_TOKEN"

echo ""
echo "LOG:"
echo "Main   : $MAIN_LOG"
echo "Docker : $DOCKER_LOG"
