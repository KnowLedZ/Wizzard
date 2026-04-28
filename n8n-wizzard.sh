#!/bin/bash

set -e

MAIN_LOG="/var/log/n8n-install.log"
DOCKER_LOG="/var/log/n8n-docker.log"

exec > >(tee -a "$MAIN_LOG") 2>&1

# ==============================
# UI HELPER
# ==============================
step() {
    echo ""
    echo "--------------------------------------"
    echo "[STEP $1] $2"
    echo "--------------------------------------"
}

ok() {
    echo "[OK] $1"
}

fail() {
    echo "[ERROR] $1"
    echo "[INFO] Check log: $MAIN_LOG"
    exit 1
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
    ok "apt ready"
}

# ==============================
# HEADER
# ==============================
clear
echo "======================================"
echo "        N8N INSTALLER WIZARD"
echo "======================================"
echo ""

read -p "Start N8N configuration wizard? (Y/n): " CONFIRM
CONFIRM=${CONFIRM:-y}

[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && echo "Cancelled." && exit 0

# ==============================
# STEP 1 - SYSTEM PREP
# ==============================
step "1/6" "Prepare system"

wait_apt

curl -fsSL https://get.docker.com -o get-docker.sh || fail "Download Docker"
sh get-docker.sh || fail "Install Docker"

systemctl start docker || service docker start || true
sleep 3

ok "Docker ready"

# ==============================
# STEP 2 - INPUT
# ==============================
step "2/6" "Configuration input"

read -p "Domain: " DOMAIN
read -p "POSTGRES_USER: " POSTGRES_USER

while true; do
    read -s -p "POSTGRES_PASSWORD: " P1; echo ""
    read -s -p "Re-enter password: " P2; echo ""

    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo "[ERROR] Password tidak cocok / kosong"
done
POSTGRES_PASSWORD=$P1

read -p "POSTGRES_DB: " POSTGRES_DB
read -p "POSTGRES_NON_ROOT_USER: " POSTGRES_NON_ROOT_USER

while true; do
    read -s -p "POSTGRES_NON_ROOT_PASSWORD: " P1; echo ""
    read -s -p "Re-enter password: " P2; echo ""

    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo "[ERROR] Password tidak cocok / kosong"
done
POSTGRES_NON_ROOT_PASSWORD=$P1

[[ -z "$POSTGRES_USER" || -z "$POSTGRES_DB" ]] && fail "Field wajib kosong"

RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)

# ==============================
# STEP 3 - PREPARE
# ==============================
step "3/6" "Prepare environment"

INSTALL_DIR="/opt/n8n"
mkdir -p "$INSTALL_DIR" || fail "Create directory"
cd "$INSTALL_DIR"

git clone https://github.com/KnowLedZ/n8n-http.git . || true

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

ok "Config ready"

# ==============================
# STEP 4 - START CONTAINERS
# ==============================
step "4/6" "Starting containers"

docker compose up -d >> "$DOCKER_LOG" 2>&1 || true

ok "Containers created"

echo "[DEBUG] Containers:"
docker ps -a

# ==============================
# STEP 5 - WAIT POSTGRES
# ==============================
step "5/6" "Waiting PostgreSQL"

for i in {1..60}; do
    NAME=$(docker ps -a --format '{{.Names}}' | grep postgres | head -n1 || true)

    if [ -z "$NAME" ]; then
        printf "\r[INFO] Postgres: starting (%d/60)" "$i"
        sleep 2
        continue
    fi

    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo "starting")

    printf "\r[INFO] Postgres: %-10s (%d/60)" "$STATUS" "$i"

    [[ "$STATUS" == "healthy" ]] && break

    sleep 2
done

echo ""
ok "PostgreSQL ready"

# ==============================
# STEP 6 - WAIT N8N
# ==============================
step "6/6" "Waiting n8n"

for i in {1..60}; do
    RUNNING=$(docker ps --format '{{.Names}}' | grep -c n8n || true)

    printf "\r[INFO] n8n: %d (%d/60)" "$RUNNING" "$i"

    [[ "$RUNNING" -ge 1 ]] && break

    sleep 2
done

echo ""
ok "n8n running"

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
