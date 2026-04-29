#!/bin/bash
set -e

# =========================
# COLOR
# =========================
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
NC="\e[0m"

LOG_FILE="/var/log/aapanel-install.log"

# =========================
# SPINNER
# =========================
spinner() {
    local pid=$1
    local msg=$2
    local spin='-\|/'
    local i=0

    echo -ne "${CYAN}[INFO] $msg... ${NC}"

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\b${spin:$i:1}"
        sleep 0.1
    done

    wait $pid
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        echo -e "\b ${GREEN}✔${NC}"
    else
        echo -e "\b ${RED}✖${NC}"
        echo -e "${RED}[ERROR] Cek log: $LOG_FILE${NC}"
        exit 1
    fi
}

clear
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}     AAPANEL INSTALLER WIZARD         ${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# =========================
# PROMPT
# =========================
read -p "Start aaPanel installation wizard? (Y/n): " CONFIRM
CONFIRM=${CONFIRM:-Y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Installation cancelled.${NC}"
    exit 0
fi

echo ""

# =========================================================
# STEP 1
# =========================================================
echo -e "${YELLOW}--------------------------------------${NC}"
echo -e "${YELLOW}[STEP 1/3] Prepare system${NC}"
echo -e "${YELLOW}--------------------------------------${NC}"

(
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 2; done
    while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 2; done

    rm -f /var/lib/dpkg/lock*
    rm -f /var/lib/apt/lists/lock*
    rm -f /var/cache/apt/archives/lock
    dpkg --configure -a || true

    apt update -y >/dev/null 2>&1
    apt install -y wget curl sudo >/dev/null 2>&1
) &
spinner $! "Preparing apt & dependencies"

echo ""

# =========================================================
# STEP 2
# =========================================================
echo -e "${YELLOW}--------------------------------------${NC}"
echo -e "${YELLOW}[STEP 2/3] Install aaPanel${NC}"
echo -e "${YELLOW}--------------------------------------${NC}"

(
    wget -O /root/install.sh http://www.aapanel.com/script/install-ubuntu_6.0_en.sh >/dev/null 2>&1
    chmod +x /root/install.sh
) &
spinner $! "Downloading installer"

(
    yes y | bash /root/install.sh > "$LOG_FILE" 2>&1
) &
spinner $! "Installing aaPanel (5-10 minutes)"

echo ""

# =========================================================
# STEP 3
# =========================================================
echo -e "${YELLOW}--------------------------------------${NC}"
echo -e "${YELLOW}[STEP 3/3] Aapanel login information${NC}"
echo -e "${YELLOW}--------------------------------------${NC}"

for i in {1..20}; do
    BT_INFO=$(bt default 2>/dev/null || true)
    [ -n "$BT_INFO" ] && break
    sleep 2
done

PUBLIC_URL=$(echo "$BT_INFO" | grep "aaPanel Internet IPv4 Address" | awk -F': ' '{print $2}')
INTERNAL_URL=$(echo "$BT_INFO" | grep "Internal Address" | awk -F': ' '{print $2}')
USERNAME=$(echo "$BT_INFO" | grep "^username:" | awk -F': ' '{print $2}')
PASSWORD=$(echo "$BT_INFO" | grep "^password:" | awk -F': ' '{print $2}')

IP=$(hostname -I | awk '{print $1}')
PORT=$(cat /www/server/panel/data/port.pl 2>/dev/null || echo "7800")

[ -z "$PUBLIC_URL" ] && PUBLIC_URL="http://$IP:$PORT"
[ -z "$INTERNAL_URL" ] && INTERNAL_URL="http://$IP:$PORT"

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}        AAPANEL LOGIN INFO            ${NC}"
echo -e "${GREEN}======================================${NC}"

printf "${CYAN}%-15s${NC} : %s\n" "Public URL" "$PUBLIC_URL"
printf "${CYAN}%-15s${NC} : %s\n" "Internal URL" "$INTERNAL_URL"
printf "${CYAN}%-15s${NC} : %s\n" "Username" "$USERNAME"
printf "${CYAN}%-15s${NC} : %s\n" "Password" "$PASSWORD"

echo -e "${GREEN}======================================${NC}"

echo ""
printf "${CYAN}%-15s${NC} : %s\n" "Log File" "$LOG_FILE"
printf "${CYAN}%-15s${NC} : %s\n" "Install Path" "/www/server"
echo ""

echo -e "${GREEN}Useful commands:${NC}"
echo -e "${CYAN}bt start${NC}       - Start aaPanel"
echo -e "${CYAN}bt stop${NC}        - Stop aaPanel"
echo -e "${CYAN}bt restart${NC}     - Restart aaPanel"
echo -e "${CYAN}bt status${NC}      - Check status"
echo -e "${CYAN}bt default${NC}     - Show login info"
echo -e "${CYAN}bt reload${NC}      - Reload panel"
echo -e "${CYAN}bt 16${NC}          - Change port"
