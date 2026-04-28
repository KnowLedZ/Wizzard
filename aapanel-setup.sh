#!/bin/bash
set -e

URL_SCRIPT="https://raw.githubusercontent.com/KnowLedZ/Wizzard/main/aapanel-wizzard.sh"

echo "======================================"
echo "   AAPANEL BOOTSTRAP INITIALIZER"
echo "======================================"
echo ""

echo "[INFO] Downloading installer..."
curl -L -f "$URL_SCRIPT" -o /root/aapanel-installer.sh

chmod +x /root/aapanel-installer.sh

echo "[OK] Installer downloaded"
echo ""

echo "[INFO] Running installer..."
echo ""

# ✅ BLOCKING (WAJIB, supaya tidak lanjut sebelum selesai)
exec bash /root/aapanel-installer.sh
