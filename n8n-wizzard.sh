#!/bin/bash

set -e

MAIN_LOG="/var/log/n8n-install.log"
DOCKER_LOG="/var/log/n8n-docker.log"

exec > >(tee -a "$MAIN_LOG") 2>&1

# ==============================
# PROGRESS BAR
# ==============================
progress_bar() {
    local duration=$1
    local msg="$2"

    local elapsed=0
    local width=30

    while [ $elapsed -lt $duration ]; do
        local percent=$(( elapsed * 100 / duration ))
        local filled=$(( percent * width / 100 ))
        local empty=$(( width - filled ))

        printf "\r[INFO] %-25s [" "$msg"
        printf "%0.s#" $(seq 1 $filled)
        printf "%0.s-" $(seq 1 $empty)
        printf "] %d%%" "$percent"

        sleep 1
        elapsed=$((elapsed+1))
    done

    printf "\r[OK] %-25s\n" "$msg"
}

# ==============================
# WAIT APT (PRODUCTION SAFE)
# ==============================
wait_apt_stable() {
    echo "[INFO] Preparing apt (production-safe)..."

    # stop auto apt sementara
    systemctl stop apt-daily.service 2>/dev/null || true
    systemctl stop apt-daily-upgrade.service 2>/dev/null || true
    systemctl kill --kill-who=all apt-daily.service 2>/dev/null || true
    systemctl kill --kill-who=all apt-daily-upgrade.service 2>/dev/null || true

    # tunggu lock hilang
    for i in {1..30}; do
        if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && \
           ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
            echo "[OK] apt ready"
            return
        fi

        printf "\r[INFO] Waiting apt lock... (%d/30)" "$i"
        sleep 1
    done

    echo ""
    echo "[ERROR] apt masih terkunci!"
    exit 1
}

# ==============================
# INSTALL DOCKER (RETRY)
# ==============================
install_docker() {
    for i in {1..3}; do
        echo "[INFO] Install Docker attempt $i..."

        if sh get-docker.sh >> "$MAIN_LOG" 2>&1; then
            echo "[OK] Docker installed"
            return
        fi

        echo "[WARN] Retry install Docker..."
        sleep 5
        wait_apt_stable
    done

    echo "[ERROR] Docker install failed"
    exit 1
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
# STEP 1 SYSTEM
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 1/6] Prepare system"
echo "------------------------------------------"

wait_apt_stable

echo "[INFO] Download Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh >> "$MAIN_LOG" 2>&1

progress_bar 3 "Preparing Docker install"

install_docker

systemctl start docker || service docker start || true
echo "[OK] Docker ready"

# ==============================
# STEP 2 INPUT
# ==============================
echo ""
echo "------------------------------------------"
echo "[STEP 2/6] Configuration setup"
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

echo "[INFO] Cloning repo..."
git clone https://github.com/KnowLedZ/n8n-http.git . >> "$MAIN_LOG" 2>&1 || true

IP=$(hostname -I | awk '{print $1}')

cat <<EOF > .env
N8N_VERSION=stable

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
PID=$!

for i in {1..20}; do
    printf "\r[INFO] Deploying containers... (%d/20)" "$i"
    sleep 1
done

wait $PID
echo ""
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
# STEP 6 WAIT N8N
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
echo "IP     : http://$IP:5678"

echo ""
echo "TOKEN:"
echo "$RUNNERS_AUTH_TOKEN"

echo ""
echo "LOG:"
echo "Main   : $MAIN_LOG"
echo "Docker : $DOCKER_LOG"
