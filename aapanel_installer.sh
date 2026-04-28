#!/bin/bash

set -e

# =========================
# LOAD CONFIG FILE (OPTIONAL)
# =========================
if [ -f /root/aapanel.env ]; then
    source /root/aapanel.env
fi

# =========================
# INPUT DARI USER (FALLBACK)
# =========================
if [ -z "$AAPANEL_PORT" ]; then
    read -p "Input aaPanel Port: " AAPANEL_PORT
fi

if [ -z "$AAPANEL_USER" ]; then
    read -p "Input Username: " AAPANEL_USER
fi

if [ -z "$AAPANEL_PASS" ]; then
    read -p "Input Password: " AAPANEL_PASS
fi

# =========================
# VALIDASI SEDERHANA
# =========================
if [ -z "$AAPANEL_PORT" ] || [ -z "$AAPANEL_USER" ] || [ -z "$AAPANEL_PASS" ]; then
    echo "[ERROR] Semua input wajib diisi!"
    exit 1
fi

# =========================
# FIX APT LOCK
# =========================
echo "[INFO] Fixing apt lock..."
while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 2; done
while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 2; done

rm -f /var/lib/dpkg/lock*
rm -f /var/lib/apt/lists/lock*
rm -f /var/cache/apt/archives/lock
dpkg --configure -a || true

# =========================
# INSTALL DEPENDENCY
# =========================
apt update -y
apt install -y curl wget sudo

# =========================
# DOWNLOAD AAPANEL
# =========================
echo "[INFO] Downloading aaPanel..."
wget -O install.sh https://www.aapanel.com/script/install-ubuntu_6.0_en.sh
chmod +x install.sh

# =========================
# INSTALL AAPANEL
# =========================
echo "[INFO] Installing aaPanel..."
yes y | bash install.sh

# =========================
# APPLY CONFIG
# =========================
echo "[INFO] Applying configuration..."

echo $AAPANEL_PORT > /www/server/panel/data/port.pl

cd /www/server/panel
btpython tools.py username "$AAPANEL_USER"
btpython tools.py password "$AAPANEL_PASS"

bt restart

IP=$(hostname -I | awk '{print $1}')

echo "======================================"
echo " aaPanel Installed Successfully!"
echo "======================================"
echo "URL: http://$IP:$AAPANEL_PORT"
echo "Username: $AAPANEL_USER"
echo "Password: $AAPANEL_PASS"
echo "======================================"
