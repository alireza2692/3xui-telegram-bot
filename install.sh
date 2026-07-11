#!/bin/bash
# ============================================================
# 3XUI Telegram Bot - Installer
# ============================================================
set -e

# >>> EDIT THIS BEFORE PUBLISHING <<<
REPO_URL="https://github.com/alireza2692/3xui-telegram-bot.git"
REPO_BRANCH="main"

C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'
C_NC='\033[0m'

info()  { echo -e "${C_CYAN}[*]${C_NC} $1"; }
ok()    { echo -e "${C_GREEN}[OK]${C_NC} $1"; }
warn()  { echo -e "${C_YELLOW}[!]${C_NC} $1"; }
err()   { echo -e "${C_RED}[X]${C_NC} $1"; }

ask_required() {
    local prompt="$1" __resultvar="$2" value=""
    while [ -z "$value" ]; do
        read -rp "$prompt: " value
        value="$(echo -n "$value" | xargs)"
        [ -z "$value" ] && warn "This field is required and cannot be empty. Please try again."
    done
    printf -v "$__resultvar" '%s' "$value"
}

ask_optional() {
    local prompt="$1" default="$2" __resultvar="$3" value=""
    read -rp "$prompt: " value
    value="$(echo -n "$value" | xargs)"
    [ -z "$value" ] && value="$default"
    printf -v "$__resultvar" '%s' "$value"
}

ask_yesno() {
    local prompt="$1" __resultvar="$2" value=""
    while [[ "$value" != "y" && "$value" != "n" ]]; do
        read -rp "$prompt (y/n): " value
        value="$(echo -n "$value" | xargs | tr '[:upper:]' '[:lower:]')"
        [[ "$value" != "y" && "$value" != "n" ]] && warn "Please enter y or n only."
    done
    printf -v "$__resultvar" '%s' "$value"
}

ask_number() {
    local prompt="$1" __resultvar="$2" value=""
    while [[ ! "$value" =~ ^[0-9]+$ ]]; do
        read -rp "$prompt: " value
        value="$(echo -n "$value" | xargs)"
        [[ ! "$value" =~ ^[0-9]+$ ]] && warn "Please enter a whole number."
    done
    printf -v "$__resultvar" '%s' "$value"
}

if [ "$EUID" -ne 0 ]; then
    err "Please run this script as root (sudo)."
    exit 1
fi

echo ""
echo "======================================================"
echo "   3XUI Telegram Bot - Installer"
echo "======================================================"
echo ""

# ------------------------------------------------------------
# 1. Install directory
# ------------------------------------------------------------
ask_optional "Install directory [default: /root/bot]" "/root/bot" BOT_DIR
mkdir -p "$BOT_DIR"

# ------------------------------------------------------------
# 2. Fresh install or restore from backup?
# ------------------------------------------------------------
echo ""
info "Setup mode"
echo "  1) Fresh install - download source from GitHub and answer all questions"
echo "  2) Restore from an existing backup (.tar.gz made by 'vpn-bot backup')"
SETUP_MODE=""
while [[ "$SETUP_MODE" != "1" && "$SETUP_MODE" != "2" ]]; do
    read -rp "Choose (1/2): " SETUP_MODE
    [[ "$SETUP_MODE" != "1" && "$SETUP_MODE" != "2" ]] && warn "Please enter 1 or 2."
done

RESTORE_MODE="n"
if [ "$SETUP_MODE" == "2" ]; then
    RESTORE_MODE="y"
    ask_required "Full path to the backup .tar.gz file" BACKUP_FILE
    [ ! -f "$BACKUP_FILE" ] && { err "File not found: $BACKUP_FILE"; exit 1; }
    info "Extracting backup into $BOT_DIR ..."
    tar -xzf "$BACKUP_FILE" -C "$BOT_DIR"
    [ ! -f "$BOT_DIR/.env" ] && { err "Backup did not contain a .env file."; exit 1; }
    ok "Backup restored."
fi

# ------------------------------------------------------------
# 3. Fetch source code from GitHub (fresh install only)
# ------------------------------------------------------------
if [ "$RESTORE_MODE" == "n" ]; then
    echo ""
    info "Fetching source code from GitHub..."

    if ! command -v git &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq && apt-get install -y -qq git
        elif command -v dnf &> /dev/null; then
            dnf install -y -q git
        elif command -v yum &> /dev/null; then
            yum install -y -q git
        fi
    fi

    TMP_ENV=""
    if [ -f "$BOT_DIR/.env" ]; then
        TMP_ENV=$(mktemp)
        cp "$BOT_DIR/.env" "$TMP_ENV"
    fi

    TMP_CLONE=$(mktemp -d)
    if git clone -b "$REPO_BRANCH" --depth 1 "$REPO_URL" "$TMP_CLONE" 2>/tmp/git_clone_err.log; then
        rsync -a --exclude='.git' --exclude='.env' "$TMP_CLONE"/ "$BOT_DIR"/ 2>/dev/null || \
            cp -r "$TMP_CLONE"/. "$BOT_DIR"/
        rm -rf "$TMP_CLONE"
        ok "Source code downloaded from GitHub."
    else
        err "Failed to clone the repository. Check REPO_URL at the top of this script."
        cat /tmp/git_clone_err.log
        exit 1
    fi

    if [ -n "$TMP_ENV" ]; then
        cp "$TMP_ENV" "$BOT_DIR/.env"
        rm -f "$TMP_ENV"
        info "Restored your existing .env (not overwritten by the download)."
    fi
fi

# ------------------------------------------------------------
# 4. Collect configuration (fresh install only)
# ------------------------------------------------------------
if [ "$RESTORE_MODE" == "n" ]; then

    echo ""
    info "Telegram bot info"
    ask_required "Bot token (BOT_TOKEN)" BOT_TOKEN
    ask_required "Admin numeric IDs (comma-separated, e.g. 123,456)" ADMIN_IDS

    echo ""
    info "Mandatory channel membership"
    ask_yesno "Enable mandatory channel membership check?" WANT_CHANNEL
    if [ "$WANT_CHANNEL" == "y" ]; then
        ask_required "Channel numeric ID (e.g. -1001234567890)" REQUIRED_CHANNEL_ID
        ask_required "Channel invite link" REQUIRED_CHANNEL_INVITE
    else
        REQUIRED_CHANNEL_ID="0"
        REQUIRED_CHANNEL_INVITE=""
    fi

    echo ""
    info "3X-UI Panel info"
    ask_required "Panel URL with https and port - no trailing slash (e.g. https://example.com:2053)" PANEL_URL
    ask_required "Panel path (webBasePath) - starts with /, no trailing slash" PANEL_PATH
    ask_required "Panel API token" PANEL_API_TOKEN
    ask_required "Subscription base URL - no trailing slash" SUB_BASE_URL
    PANEL_URL="${PANEL_URL%/}"
    PANEL_PATH="${PANEL_PATH%/}"
    SUB_BASE_URL="${SUB_BASE_URL%/}"

    echo ""
    info "Fetching the inbound list from the panel..."

    INBOUNDS_JSON=$(curl -sk --max-time 15 \
        -H "Authorization: Bearer ${PANEL_API_TOKEN}" \
        "${PANEL_URL}${PANEL_PATH}/panel/api/inbounds/list" 2>/dev/null || true)

    if ! echo "$INBOUNDS_JSON" | grep -q '"success":true'; then
        INBOUNDS_JSON=$(curl -sk --max-time 15 \
            -H "Authorization: Bearer ${PANEL_API_TOKEN}" \
            "${PANEL_URL}${PANEL_PATH}/panel/inbounds/list" 2>/dev/null || true)
    fi

    INBOUNDS=""

    if echo "$INBOUNDS_JSON" | grep -q '"success":true'; then
        ok "Connected. Available inbounds:"
        python3 - "$INBOUNDS_JSON" << 'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
obj = data.get("obj", [])
if not obj:
    print("EMPTY")
else:
    for inb in obj:
        remark = inb.get("remark") or f"inbound-{inb.get('id')}"
        protocol = inb.get("protocol", "?")
        port = inb.get("port", "?")
        print(f"id={inb.get('id')}  [{protocol}]  port={port}  remark=\"{remark}\"")
PYEOF
        echo ""
        read -rp "Enter the inbound ID(s) to use, comma-separated (use the number after id=, e.g. 1,6): " INB_CHOICES

        echo ""
        ask_yesno "Enable Vision flow (xtls-rprx-vision) for these inbounds?" WANT_VISION
        FLOW=""
        [ "$WANT_VISION" == "y" ] && FLOW="xtls-rprx-vision"

        IFS=',' read -ra CHOICE_ARR <<< "$INB_CHOICES"
        for idx in "${CHOICE_ARR[@]}"; do
            idx="$(echo -n "$idx" | xargs)"
            [ -z "$idx" ] && continue

            LINE=$(python3 - "$INBOUNDS_JSON" "$idx" << 'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
want_id = sys.argv[2]
obj = data.get("obj", [])
found = None
for inb in obj:
    if str(inb.get("id")) == str(want_id):
        found = inb
        break
if found is None:
    print("INVALID")
else:
    remark = found.get("remark") or f"inbound-{found.get('id')}"
    ss_raw = found.get("streamSettings", {})
    if isinstance(ss_raw, str):
        try:
            ss = json.loads(ss_raw)
        except Exception:
            ss = {}
    else:
        ss = ss_raw or {}
    is_reality = "y" if ss.get("security") == "reality" else "n"
    print(f"{found.get('id')}|{remark}|{is_reality}")
PYEOF
)
            if [ "$LINE" == "INVALID" ]; then
                warn "Invalid selection: $idx (skipped)"
                continue
            fi
            IB_ID=$(echo "$LINE" | cut -d'|' -f1)
            IB_REMARK=$(echo "$LINE" | cut -d'|' -f2)
            IB_IS_REALITY=$(echo "$LINE" | cut -d'|' -f3)
            if [ "$IB_IS_REALITY" == "y" ]; then
                ENTRY_FLOW="$FLOW"
            else
                ENTRY_FLOW=""
            fi

            ENTRY="${IB_ID}:${IB_REMARK}:${ENTRY_FLOW}"
            if [ -z "$INBOUNDS" ]; then
                INBOUNDS="$ENTRY"
            else
                INBOUNDS="${INBOUNDS},${ENTRY}"
            fi
        done
    else
        warn "Could not fetch inbounds automatically."
    fi

    if [ -z "$INBOUNDS" ]; then
        ask_required "Enter the Inbound ID manually" INBOUND_ID_MANUAL
        ask_yesno "Enable Vision flow (xtls-rprx-vision) for it?" WANT_VISION
        FLOW=""
        [ "$WANT_VISION" == "y" ] && FLOW="xtls-rprx-vision"
        INBOUNDS="${INBOUND_ID_MANUAL}:default:${FLOW}"
    fi

    INBOUND_ID="${INBOUNDS%%:*}"
    echo ""
    ok "Selected inbound(s): $INBOUNDS"

    echo ""
    info "Local SOCKS5 proxy"
    echo "Used to bypass sanctions when calling the Telegram API."
    echo "Skip this if your server can reach Telegram directly."
    ask_yesno "Are you using a local SOCKS5 proxy?" WANT_PROXY
    if [ "$WANT_PROXY" == "y" ]; then
        ask_required "Proxy host (e.g. 127.0.0.1)" PROXY_HOST
        ask_required "Proxy port (e.g. 1010)" PROXY_PORT
    else
        PROXY_HOST=""
        PROXY_PORT=""
    fi

    echo ""
    info "Log channel (purchase/renew/topup/referral reports)"
    ask_yesno "Enable the log channel?" WANT_LOG
    if [ "$WANT_LOG" == "y" ]; then
        ask_required "Log channel numeric ID (bot must be an admin there)" LOG_CHANNEL_ID
    else
        LOG_CHANNEL_ID="0"
    fi

    echo ""
    info "Expiry reminder system"
    echo "Sends a one-time message to the user when their service is about to run out"
    echo "(either by remaining traffic or by remaining days)."
    ask_yesno "Enable the expiry reminder system?" REMINDER_ENABLED
    if [ "$REMINDER_ENABLED" == "y" ]; then
        ask_number "Remind when remaining traffic is at or below how many GB" REMINDER_GB_THRESHOLD
        ask_number "Remind when remaining days are at or below how many days" REMINDER_DAYS_THRESHOLD
    else
        REMINDER_GB_THRESHOLD="3"
        REMINDER_DAYS_THRESHOLD="3"
    fi

    echo ""
    info "Payment card numbers"
    ask_number "How many card numbers do you want to add (at least 1)" CARD_COUNT
    while [ "$CARD_COUNT" -lt 1 ]; do
        warn "You need at least 1 card."
        ask_number "How many card numbers do you want to add (at least 1)" CARD_COUNT
    done

    CARDS=""
    for ((i=1; i<=CARD_COUNT; i++)); do
        echo ""
        echo "--- Card #$i ---"
        ask_required "Card number" CARD_NUM
        ask_required "Cardholder name" CARD_NAME
        if [ -z "$CARDS" ]; then
            CARDS="${CARD_NUM}:${CARD_NAME}"
        else
            CARDS="${CARDS},${CARD_NUM}:${CARD_NAME}"
        fi
    done

    cat > "$BOT_DIR/.env" << ENVEOF
BOT_TOKEN=${BOT_TOKEN}
ADMIN_IDS=${ADMIN_IDS}
REQUIRED_CHANNEL_ID=${REQUIRED_CHANNEL_ID}
REQUIRED_CHANNEL_INVITE=${REQUIRED_CHANNEL_INVITE}
PANEL_URL=${PANEL_URL}
PANEL_PATH=${PANEL_PATH}
PANEL_API_TOKEN=${PANEL_API_TOKEN}
INBOUND_ID=${INBOUND_ID}
INBOUNDS=${INBOUNDS}
SUB_BASE_URL=${SUB_BASE_URL}
PROXY_HOST=${PROXY_HOST}
PROXY_PORT=${PROXY_PORT}
CARDS=${CARDS}
LOG_CHANNEL_ID=${LOG_CHANNEL_ID}
REMINDER_ENABLED=${REMINDER_ENABLED}
REMINDER_GB_THRESHOLD=${REMINDER_GB_THRESHOLD}
REMINDER_DAYS_THRESHOLD=${REMINDER_DAYS_THRESHOLD}
DB_PATH=vpn_bot.db
ENVEOF

    ok ".env file created at $BOT_DIR/.env"
fi

# ------------------------------------------------------------
# 5. System dependencies
# ------------------------------------------------------------
echo ""
info "Checking and installing system dependencies..."

PY_VER=""
command -v python3 &> /dev/null && PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')

if command -v apt-get &> /dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    PKGS="python3 python3-pip sqlite3 curl python3-venv python3-full nano git rsync"
    [ -n "$PY_VER" ] && PKGS="$PKGS python${PY_VER}-venv"
    apt-get install -y -qq $PKGS
elif command -v dnf &> /dev/null; then
    dnf install -y -q python3 python3-pip python3-virtualenv sqlite curl nano git rsync
elif command -v yum &> /dev/null; then
    yum install -y -q python3 python3-pip sqlite curl nano git rsync
else
    warn "Unknown package manager; assuming python3/pip/venv are already installed."
fi

command -v python3 &> /dev/null || { err "Failed to install python3."; exit 1; }
ok "System dependencies are ready."

# ------------------------------------------------------------
# 6. Python venv + requirements
# ------------------------------------------------------------
[ ! -f "$BOT_DIR/requirements.txt" ] && warn "requirements.txt not found in $BOT_DIR."

cd "$BOT_DIR"

[ -d ".venv" ] && [ ! -f ".venv/bin/python3" ] && { warn ".venv looks incomplete; rebuilding."; rm -rf .venv; }
[ ! -d ".venv" ] && { info "Creating virtual environment..."; python3 -m venv .venv; }
[ ! -f ".venv/bin/python3" ] && { err "Failed to create the virtual environment."; exit 1; }
ok "Virtual environment is ready."

info "Installing packages..."
.venv/bin/python3 -m pip install --upgrade pip -q
if [ -f "requirements.txt" ]; then
    .venv/bin/python3 -m pip install -r requirements.txt -q
    ok "Packages installed."
else
    warn "requirements.txt not found; skipped package install."
fi

# ------------------------------------------------------------
# 7. systemd service
# ------------------------------------------------------------
echo ""
info "Creating systemd service..."

cat > /etc/systemd/system/vpnbot.service << SERVICEEOF
[Unit]
Description=VPN Sales Telegram Bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${BOT_DIR}
ExecStart=${BOT_DIR}/.venv/bin/python3 main.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable vpnbot -q
ok "vpnbot service created and enabled."

# ------------------------------------------------------------
# 8. Install vpn-bot CLI management tool
# ------------------------------------------------------------
echo ""
info "Installing the vpn-bot management command..."

cat > /usr/local/bin/vpn-bot << CLIEOF
#!/bin/bash
BOT_DIR="${BOT_DIR}"
SERVICE="vpnbot"
BACKUP_DIR="\${BOT_DIR}/backups"
mkdir -p "\$BACKUP_DIR"

C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'
C_BLUE='\033[0;34m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_NC='\033[0m'

info()  { echo -e "\${C_CYAN}[*]\${C_NC} \$1"; }
ok()    { echo -e "\${C_GREEN}[OK]\${C_NC} \$1"; }
warn()  { echo -e "\${C_YELLOW}[!]\${C_NC} \$1"; }
err()   { echo -e "\${C_RED}[X]\${C_NC} \$1"; }
pause() { read -rp "Press Enter to continue..." _; }

env_get() {
    python3 -c "
import sys
key = sys.argv[1]
path = sys.argv[2]
try:
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if line.startswith(key + '='):
            print(line.split('=', 1)[1])
            break
except FileNotFoundError:
    pass
" "\$1" "\$BOT_DIR/.env"
}

env_set() {
    python3 -c "
import sys
key, value, path = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
found = False
try:
    with open(path, encoding='utf-8') as f:
        lines = f.read().split('\n')
except FileNotFoundError:
    pass
for i, line in enumerate(lines):
    if line.startswith(key + '='):
        lines[i] = f'{key}={value}'
        found = True
        break
if not found:
    lines.append(f'{key}={value}')
with open(path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(l for l in lines if l != '') + '\n')
" "\$1" "\$2" "\$BOT_DIR/.env"
}

mask() {
    local v="\$1"
    local len=\${#v}
    if [ "\$len" -le 8 ]; then
        echo "****"
    else
        echo "\${v:0:4}****\${v: -4}"
    fi
}

maybe_restart() {
    read -rp "Restart the bot now to apply changes? (y/n): " R
    if [ "\$R" == "y" ]; then
        systemctl restart \$SERVICE
        ok "Restarted."
    fi
}

status_line() {
    if systemctl is-active --quiet \$SERVICE; then
        echo -e "\${C_GREEN}\${C_BOLD}● RUNNING\${C_NC}"
    else
        echo -e "\${C_RED}\${C_BOLD}● STOPPED\${C_NC}"
    fi
}

do_backup() {
    TS=\$(date +%Y%m%d_%H%M%S)
    OUT="\$BACKUP_DIR/backup_\$TS.tar.gz"
    echo -e "\${C_CYAN}Creating backup...\${C_NC}"
    tar -czf "\$OUT" -C "\$BOT_DIR" \\
        .env config.py database.py main.py requirements.txt vpn_bot.db \\
        handlers keyboards middlewares services utils 2>/dev/null || true
    ok "Backup saved: \$OUT"
}

do_restore() {
    echo -e "\${C_CYAN}Available backups:\${C_NC}"
    ls -1t "\$BACKUP_DIR" 2>/dev/null | nl
    echo ""
    read -rp "Enter backup number (or full file path): " CHOICE
    if [[ "\$CHOICE" =~ ^[0-9]+\$ ]]; then
        FILE=\$(ls -1t "\$BACKUP_DIR" | sed -n "\${CHOICE}p")
        FILE="\$BACKUP_DIR/\$FILE"
    else
        FILE="\$CHOICE"
    fi
    [ ! -f "\$FILE" ] && { err "File not found."; return; }
    warn "This will overwrite the current bot files."
    read -rp "Are you sure? (y/n): " CONFIRM
    [ "\$CONFIRM" != "y" ] && { echo "Cancelled."; return; }
    systemctl stop \$SERVICE
    tar -xzf "\$FILE" -C "\$BOT_DIR"
    systemctl start \$SERVICE
    ok "Restore complete, bot restarted."
}

view_db_stats() {
    DB="\$BOT_DIR/vpn_bot.db"
    [ ! -f "\$DB" ] && { err "Database not found."; return; }
    echo -e "\${C_CYAN}--- Quick database stats ---\${C_NC}"
    printf "%-16s: " "Users";            sqlite3 "\$DB" "SELECT COUNT(*) FROM wallets;" 2>/dev/null || echo "N/A"
    printf "%-16s: " "Orders";           sqlite3 "\$DB" "SELECT COUNT(*) FROM orders;" 2>/dev/null || echo "N/A"
    printf "%-16s: " "Total revenue";    sqlite3 "\$DB" "SELECT COALESCE(SUM(amount_paid),0) FROM orders;" 2>/dev/null || echo "N/A"
    printf "%-16s: " "Pending payments"; sqlite3 "\$DB" "SELECT COUNT(*) FROM pending_payments WHERE status='pending';" 2>/dev/null || echo "N/A"
}

reinstall_deps() {
    cd "\$BOT_DIR"
    echo -e "\${C_CYAN}Updating Python packages...\${C_NC}"
    .venv/bin/python3 -m pip install --upgrade pip -q
    .venv/bin/python3 -m pip install -r requirements.txt -q --upgrade
    ok "Packages updated."
    read -rp "Restart the bot now? (y/n): " R
    [ "\$R" == "y" ] && systemctl restart \$SERVICE
}

health_check() {
    echo -e "\${C_CYAN}Running health checks...\${C_NC}"
    echo ""
    printf "%-30s" "Bot service:"
    systemctl is-active --quiet \$SERVICE && echo -e "\${C_GREEN}running\${C_NC}" || echo -e "\${C_RED}not running\${C_NC}"

    printf "%-30s" ".env file:"
    [ -f "\$BOT_DIR/.env" ] && echo -e "\${C_GREEN}found\${C_NC}" || echo -e "\${C_RED}missing\${C_NC}"

    [ -f "\$BOT_DIR/.env" ] && { set -a; source "\$BOT_DIR/.env"; set +a; }

    printf "%-30s" "Telegram bot token:"
    if [ -n "\$BOT_TOKEN" ]; then
        TG=\$(curl -s --max-time 10 "https://api.telegram.org/bot\${BOT_TOKEN}/getMe" 2>/dev/null)
        if echo "\$TG" | grep -q '"ok":true'; then
            U=\$(echo "\$TG" | grep -oP '"username":"\K[^"]+')
            echo -e "\${C_GREEN}valid (@\${U})\${C_NC}"
        else
            echo -e "\${C_RED}invalid or unreachable\${C_NC}"
        fi
    else
        echo -e "\${C_YELLOW}not set\${C_NC}"
    fi

    printf "%-30s" "SOCKS5 proxy:"
    if [ -n "\$PROXY_HOST" ] && [ -n "\$PROXY_PORT" ]; then
        if timeout 3 bash -c "cat < /dev/null > /dev/tcp/\$PROXY_HOST/\$PROXY_PORT" 2>/dev/null; then
            echo -e "\${C_GREEN}reachable (\${PROXY_HOST}:\${PROXY_PORT})\${C_NC}"
        else
            echo -e "\${C_RED}cannot connect\${C_NC}"
        fi
    else
        echo -e "\${C_DIM}disabled (direct connection)\${C_NC}"
    fi

    printf "%-30s" "3X-UI panel:"
    if [ -n "\$PANEL_URL" ]; then
        CODE=\$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "\${PANEL_URL}\${PANEL_PATH}/login" 2>/dev/null)
        [ -n "\$CODE" ] && [ "\$CODE" != "000" ] && echo -e "\${C_GREEN}reachable (HTTP \$CODE)\${C_NC}" || echo -e "\${C_RED}unreachable\${C_NC}"
    else
        echo -e "\${C_YELLOW}not set\${C_NC}"
    fi

    printf "%-30s" "Panel API token:"
    if [ -n "\$PANEL_URL" ] && [ -n "\$PANEL_API_TOKEN" ]; then
        RES=\$(curl -sk --max-time 10 -H "Authorization: Bearer \${PANEL_API_TOKEN}" "\${PANEL_URL}\${PANEL_PATH}/panel/api/clients/list" 2>/dev/null)
        echo "\$RES" | grep -q '"success":true' && echo -e "\${C_GREEN}valid\${C_NC}" || echo -e "\${C_RED}invalid or unreachable\${C_NC}"
    else
        echo -e "\${C_YELLOW}not set\${C_NC}"
    fi

    printf "%-30s" "Database file:"
    if [ -f "\$BOT_DIR/vpn_bot.db" ]; then
        SZ=\$(du -h "\$BOT_DIR/vpn_bot.db" 2>/dev/null | cut -f1)
        echo -e "\${C_GREEN}found (\${SZ})\${C_NC}"
    else
        echo -e "\${C_YELLOW}not found yet\${C_NC}"
    fi

    printf "%-30s" "Disk space:"
    echo -e "\${C_CYAN}\$(df -h "\$BOT_DIR" 2>/dev/null | awk 'NR==2 {print \$4}') free\${C_NC}"
    echo ""
}

uninstall_bot() {
    warn "This removes the systemd service and the vpn-bot command."
    echo "Bot files in \$BOT_DIR will NOT be deleted."
    read -rp "Are you sure? (y/n): " CONFIRM
    if [ "\$CONFIRM" == "y" ]; then
        systemctl stop \$SERVICE 2>/dev/null || true
        systemctl disable \$SERVICE 2>/dev/null || true
        rm -f /etc/systemd/system/\${SERVICE}.service
        systemctl daemon-reload
        rm -f /usr/local/bin/vpn-bot
        echo "Removed. Bot files remain in \$BOT_DIR."
    fi
}

settings_bot() {
    clear
    echo -e "\${C_CYAN}--- Bot & Admins ---\${C_NC}"
    echo "Token: \$(mask "\$(env_get BOT_TOKEN)")"
    echo "Admin IDs: \$(env_get ADMIN_IDS)"
    echo ""
    echo "1) Change bot token"
    echo "2) Change admin IDs"
    echo "0) Back"
    read -rp "Choose: " C
    case \$C in
        1) read -rp "New bot token: " V; env_set BOT_TOKEN "\$V"; maybe_restart ;;
        2) read -rp "New admin IDs (comma-separated): " V; env_set ADMIN_IDS "\$V"; maybe_restart ;;
    esac
}

settings_channel() {
    clear
    echo -e "\${C_CYAN}--- Mandatory Channel ---\${C_NC}"
    echo "Channel ID: \$(env_get REQUIRED_CHANNEL_ID)"
    echo "Invite link: \$(env_get REQUIRED_CHANNEL_INVITE)"
    echo ""
    echo "1) Enable / change channel ID"
    echo "2) Change invite link"
    echo "3) Disable mandatory channel"
    echo "0) Back"
    read -rp "Choose: " C
    case \$C in
        1) read -rp "Channel numeric ID: " V; env_set REQUIRED_CHANNEL_ID "\$V"; maybe_restart ;;
        2) read -rp "New invite link: " V; env_set REQUIRED_CHANNEL_INVITE "\$V"; maybe_restart ;;
        3) env_set REQUIRED_CHANNEL_ID "0"; env_set REQUIRED_CHANNEL_INVITE ""; ok "Disabled."; maybe_restart ;;
    esac
}

settings_panel() {
    clear
    echo -e "\${C_CYAN}--- Panel (3X-UI) ---\${C_NC}"
    echo "URL: \$(env_get PANEL_URL)"
    echo "Path: \$(env_get PANEL_PATH)"
    echo "API token: \$(mask "\$(env_get PANEL_API_TOKEN)")"
    echo "Subscription URL: \$(env_get SUB_BASE_URL)"
    echo ""
    echo "1) Change panel URL"
    echo "2) Change panel path"
    echo "3) Change API token"
    echo "4) Change subscription URL"
    echo "0) Back"
    read -rp "Choose: " C
    case \$C in
        1) read -rp "New panel URL (no trailing slash): " V; env_set PANEL_URL "\${V%/}"; maybe_restart ;;
        2) read -rp "New panel path (no trailing slash): " V; env_set PANEL_PATH "\${V%/}"; maybe_restart ;;
        3) read -rp "New API token: " V; env_set PANEL_API_TOKEN "\$V"; maybe_restart ;;
        4) read -rp "New subscription URL (no trailing slash): " V; env_set SUB_BASE_URL "\${V%/}"; maybe_restart ;;
    esac
}

settings_inbounds() {
    clear
    echo -e "\${C_CYAN}--- Inbounds ---\${C_NC}"
    echo "Format: id:remark:flow (flow empty for non-Reality inbounds)"
    echo ""
    CURRENT=\$(env_get INBOUNDS)
    IFS=',' read -ra ARR <<< "\$CURRENT"
    i=1
    for e in "\${ARR[@]}"; do
        [ -n "\$e" ] && echo "\$i) \$e"
        i=\$((i+1))
    done
    echo ""
    echo "1) Fetch inbound list from panel and rebuild selection"
    echo "2) Add one inbound manually"
    echo "3) Remove an inbound by number"
    echo "4) Clear all (fallback to single INBOUND_ID)"
    echo "0) Back"
    read -rp "Choose: " C

    case \$C in
        1)
            P_URL=\$(env_get PANEL_URL)
            P_PATH=\$(env_get PANEL_PATH)
            P_TOKEN=\$(env_get PANEL_API_TOKEN)
            echo "Fetching inbounds..."
            JSON=\$(curl -sk --max-time 15 -H "Authorization: Bearer \${P_TOKEN}" "\${P_URL}\${P_PATH}/panel/api/inbounds/list" 2>/dev/null)
            if ! echo "\$JSON" | grep -q '"success":true'; then
                err "Could not fetch inbounds from the panel."
                return
            fi
            python3 - "\$JSON" << 'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
for inb in data.get("obj", []):
    remark = inb.get("remark") or f"inbound-{inb.get('id')}"
    print(f"id={inb.get('id')}  [{inb.get('protocol')}]  port={inb.get('port')}  remark=\"{remark}\"")
PYEOF
            echo ""
            read -rp "Enter the inbound ID(s) to include, comma-separated (use the number after id=): " PICKS

            HAS_REALITY=\$(python3 - "\$JSON" "\$PICKS" << 'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
picks = [p.strip() for p in sys.argv[2].split(",") if p.strip()]
obj = data.get("obj", [])
for inb in obj:
    if str(inb.get("id")) in picks:
        ss_raw = inb.get("streamSettings", {})
        if isinstance(ss_raw, str):
            try:
                ss = json.loads(ss_raw)
            except Exception:
                ss = {}
        else:
            ss = ss_raw or {}
        if ss.get("security") == "reality":
            print("y")
            sys.exit(0)
print("n")
PYEOF
)
            FLOW=""
            if [ "\$HAS_REALITY" == "y" ]; then
                echo ""
                read -rp "One or more selected inbounds are Reality. Enable Vision flow for them? (y/n): " ISV
                [ "\$ISV" == "y" ] && FLOW="xtls-rprx-vision"
            fi
            NEW_INBOUNDS=""
            IFS=',' read -ra PICK_ARR <<< "\$PICKS"
            for idx in "\${PICK_ARR[@]}"; do
                idx="\$(echo -n "\$idx" | xargs)"
                [ -z "\$idx" ] && continue
                LINE=\$(python3 - "\$JSON" "\$idx" << 'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
want_id = sys.argv[2]
obj = data.get("obj", [])
found = None
for inb in obj:
    if str(inb.get("id")) == str(want_id):
        found = inb
        break
if found is None:
    print("INVALID")
else:
    remark = found.get("remark") or f"inbound-{found.get('id')}"
    ss_raw = found.get("streamSettings", {})
    if isinstance(ss_raw, str):
        try:
            ss = json.loads(ss_raw)
        except Exception:
            ss = {}
    else:
        ss = ss_raw or {}
    is_reality = "y" if ss.get("security") == "reality" else "n"
    print(f"{found.get('id')}|{remark}|{is_reality}")
PYEOF
)
                [ "\$LINE" == "INVALID" ] && { warn "Invalid: \$idx"; continue; }
                IB_ID=\$(echo "\$LINE" | cut -d'|' -f1)
                IB_REMARK=\$(echo "\$LINE" | cut -d'|' -f2)
                IB_IS_REALITY=\$(echo "\$LINE" | cut -d'|' -f3)
                if [ "\$IB_IS_REALITY" == "y" ]; then
                    ENTRY_FLOW="\$FLOW"
                else
                    ENTRY_FLOW=""
                fi
                ENTRY="\${IB_ID}:\${IB_REMARK}:\${ENTRY_FLOW}"
                [ -z "\$NEW_INBOUNDS" ] && NEW_INBOUNDS="\$ENTRY" || NEW_INBOUNDS="\${NEW_INBOUNDS},\${ENTRY}"
            done
            if [ -n "\$NEW_INBOUNDS" ]; then
                env_set INBOUNDS "\$NEW_INBOUNDS"
                env_set INBOUND_ID "\${NEW_INBOUNDS%%:*}"
                ok "Inbounds updated."
                maybe_restart
            fi
            ;;
        2)
            read -rp "Inbound ID: " IB_ID
            read -rp "Display name (remark): " IB_REMARK
            read -rp "Enable Vision flow? (y/n): " ISV
            FLOW=""
            [ "\$ISV" == "y" ] && FLOW="xtls-rprx-vision"
            ENTRY="\${IB_ID}:\${IB_REMARK}:\${FLOW}"
            CURRENT=\$(env_get INBOUNDS)
            if [ -z "\$CURRENT" ]; then
                NEW="\$ENTRY"
            else
                NEW="\${CURRENT},\${ENTRY}"
            fi
            env_set INBOUNDS "\$NEW"
            env_set INBOUND_ID "\${NEW%%:*}"
            ok "Added."
            maybe_restart
            ;;
        3)
            read -rp "Enter the number to remove: " N
            CURRENT=\$(env_get INBOUNDS)
            IFS=',' read -ra ARR <<< "\$CURRENT"
            NEW=""
            i=1
            for e in "\${ARR[@]}"; do
                if [ "\$i" != "\$N" ]; then
                    [ -z "\$NEW" ] && NEW="\$e" || NEW="\${NEW},\${e}"
                fi
                i=\$((i+1))
            done
            env_set INBOUNDS "\$NEW"
            [ -n "\$NEW" ] && env_set INBOUND_ID "\${NEW%%:*}"
            ok "Removed."
            maybe_restart
            ;;
        4)
            read -rp "Fallback single Inbound ID: " V
            env_set INBOUNDS ""
            env_set INBOUND_ID "\$V"
            ok "Cleared."
            maybe_restart
            ;;
    esac
}

settings_proxy() {
    clear
    echo -e "\${C_CYAN}--- SOCKS5 Proxy ---\${C_NC}"
    echo "Host: \$(env_get PROXY_HOST)"
    echo "Port: \$(env_get PROXY_PORT)"
    echo ""
    echo "1) Enable / change proxy"
    echo "2) Disable proxy"
    echo "0) Back"
    read -rp "Choose: " C
    case \$C in
        1) read -rp "Proxy host: " H; read -rp "Proxy port: " P; env_set PROXY_HOST "\$H"; env_set PROXY_PORT "\$P"; maybe_restart ;;
        2) env_set PROXY_HOST ""; env_set PROXY_PORT ""; ok "Disabled."; maybe_restart ;;
    esac
}

settings_log() {
    clear
    echo -e "\${C_CYAN}--- Log Channel ---\${C_NC}"
    echo "Channel ID: \$(env_get LOG_CHANNEL_ID)"
    echo ""
    echo "1) Enable / change log channel"
    echo "2) Disable log channel"
    echo "0) Back"
    read -rp "Choose: " C
    case \$C in
        1) read -rp "Log channel numeric ID: " V; env_set LOG_CHANNEL_ID "\$V"; maybe_restart ;;
        2) env_set LOG_CHANNEL_ID "0"; ok "Disabled."; maybe_restart ;;
    esac
}

settings_reminder() {
    clear
    echo -e "\${C_CYAN}--- Expiry Reminder ---\${C_NC}"
    echo "Enabled: \$(env_get REMINDER_ENABLED)"
    echo "GB threshold: \$(env_get REMINDER_GB_THRESHOLD)"
    echo "Days threshold: \$(env_get REMINDER_DAYS_THRESHOLD)"
    echo ""
    echo "1) Enable"
    echo "2) Disable"
    echo "3) Change GB threshold"
    echo "4) Change days threshold"
    echo "0) Back"
    read -rp "Choose: " C
    case \$C in
        1) env_set REMINDER_ENABLED "y"; ok "Enabled."; maybe_restart ;;
        2) env_set REMINDER_ENABLED "n"; ok "Disabled."; maybe_restart ;;
        3) read -rp "New GB threshold: " V; env_set REMINDER_GB_THRESHOLD "\$V"; maybe_restart ;;
        4) read -rp "New days threshold: " V; env_set REMINDER_DAYS_THRESHOLD "\$V"; maybe_restart ;;
    esac
}

settings_cards() {
    clear
    echo -e "\${C_CYAN}--- Payment Cards ---\${C_NC}"
    CURRENT=\$(env_get CARDS)
    IFS=',' read -ra ARR <<< "\$CURRENT"
    i=1
    for e in "\${ARR[@]}"; do
        [ -n "\$e" ] && echo "\$i) \$e"
        i=\$((i+1))
    done
    echo ""
    echo "1) Add a card"
    echo "2) Remove a card by number"
    echo "3) Replace all cards"
    echo "0) Back"
    read -rp "Choose: " C
    case \$C in
        1)
            read -rp "Card number: " NUM
            read -rp "Cardholder name: " NAME
            [ -z "\$CURRENT" ] && NEW="\${NUM}:\${NAME}" || NEW="\${CURRENT},\${NUM}:\${NAME}"
            env_set CARDS "\$NEW"
            ok "Added."
            maybe_restart
            ;;
        2)
            read -rp "Number to remove: " N
            NEW=""
            i=1
            for e in "\${ARR[@]}"; do
                if [ "\$i" != "\$N" ]; then
                    [ -z "\$NEW" ] && NEW="\$e" || NEW="\${NEW},\${e}"
                fi
                i=\$((i+1))
            done
            env_set CARDS "\$NEW"
            ok "Removed."
            maybe_restart
            ;;
        3)
            read -rp "How many cards: " CNT
            NEW=""
            for ((k=1; k<=CNT; k++)); do
                read -rp "Card #\$k number: " NUM
                read -rp "Card #\$k holder name: " NAME
                [ -z "\$NEW" ] && NEW="\${NUM}:\${NAME}" || NEW="\${NEW},\${NUM}:\${NAME}"
            done
            env_set CARDS "\$NEW"
            ok "Cards replaced."
            maybe_restart
            ;;
    esac
}

edit_env() {
    while true; do
        clear
        echo -e "\${C_CYAN}\${C_BOLD}--- Edit Settings ---\${C_NC}"
        echo "1) Bot & Admins"
        echo "2) Mandatory Channel"
        echo "3) Panel (3X-UI)"
        echo "4) Inbounds / Servers"
        echo "5) SOCKS5 Proxy"
        echo "6) Log Channel"
        echo "7) Expiry Reminder"
        echo "8) Payment Cards"
        echo "9) Raw .env editor (advanced)"
        echo "0) Back to main menu"
        read -rp "Choose: " C
        case \$C in
            1) settings_bot; pause ;;
            2) settings_channel; pause ;;
            3) settings_panel; pause ;;
            4) settings_inbounds; pause ;;
            5) settings_proxy; pause ;;
            6) settings_log; pause ;;
            7) settings_reminder; pause ;;
            8) settings_cards; pause ;;
            9)
                EDITOR_BIN="\${EDITOR:-nano}"
                command -v "\$EDITOR_BIN" &> /dev/null || EDITOR_BIN="vi"
                "\$EDITOR_BIN" "\$BOT_DIR/.env"
                maybe_restart
                ;;
            0) break ;;
        esac
    done
}

show_menu() {
    clear
    echo -e "\${C_BLUE}\${C_BOLD}╔══════════════════════════════════════════════════╗\${C_NC}"
    echo -e "\${C_BLUE}\${C_BOLD}║          🤖  VPN Sales Bot — Control Panel         ║\${C_NC}"
    echo -e "\${C_BLUE}\${C_BOLD}╚══════════════════════════════════════════════════╝\${C_NC}"
    echo -e "  Service status: \$(status_line)"
    echo -e "\${C_DIM}──────────────────────────────────────────────────────\${C_NC}"
    echo -e "  \${C_GREEN}1)\${C_NC}  🟢 Start bot"
    echo -e "  \${C_GREEN}2)\${C_NC}  🔴 Stop bot"
    echo -e "  \${C_GREEN}3)\${C_NC}  🔄 Restart bot"
    echo -e "  \${C_GREEN}4)\${C_NC}  📊 Service status"
    echo -e "  \${C_GREEN}5)\${C_NC}  📜 Live logs (Ctrl+C to exit)"
    echo -e "  \${C_GREEN}6)\${C_NC}  📄 Last 100 log lines"
    echo -e "  \${C_GREEN}7)\${C_NC}  ⚙️  Edit settings"
    echo -e "  \${C_GREEN}8)\${C_NC}  💾 Create backup"
    echo -e "  \${C_GREEN}9)\${C_NC}  ♻️  Restore from backup"
    echo -e "  \${C_GREEN}10)\${C_NC} 📈 Quick database stats"
    echo -e "  \${C_GREEN}11)\${C_NC} 📦 Update Python packages"
    echo -e "  \${C_GREEN}12)\${C_NC} 🩺 Health check"
    echo -e "  \${C_GREEN}13)\${C_NC} 🗑  Uninstall CLI & service"
    echo -e "  \${C_RED}0)\${C_NC}  Exit"
    echo -e "\${C_DIM}──────────────────────────────────────────────────────\${C_NC}"
}

if [ -n "\$1" ]; then
    case "\$1" in
        start) systemctl start \$SERVICE; ok "Started." ;;
        stop) systemctl stop \$SERVICE; warn "Stopped." ;;
        restart) systemctl restart \$SERVICE; ok "Restarted." ;;
        status) systemctl status \$SERVICE ;;
        logs) journalctl -u \$SERVICE -f ;;
        backup) do_backup ;;
        restore) do_restore ;;
        health) health_check ;;
        *) err "Unknown command: \$1" ;;
    esac
    exit 0
fi

while true; do
    show_menu
    read -rp "Choose an option: " CHOICE
    case \$CHOICE in
        1) systemctl start \$SERVICE; ok "Started."; pause ;;
        2) systemctl stop \$SERVICE; warn "Stopped."; pause ;;
        3) systemctl restart \$SERVICE; ok "Restarted."; pause ;;
        4) systemctl status \$SERVICE --no-pager; pause ;;
        5) journalctl -u \$SERVICE -f ;;
        6) journalctl -u \$SERVICE -n 100 --no-pager; pause ;;
        7) edit_env ;;
        8) do_backup; pause ;;
        9) do_restore; pause ;;
        10) view_db_stats; pause ;;
        11) reinstall_deps; pause ;;
        12) health_check; pause ;;
        13) uninstall_bot; exit 0 ;;
        0) exit 0 ;;
        *) err "Invalid option."; pause ;;
    esac
done
CLIEOF

chmod +x /usr/local/bin/vpn-bot
ok "vpn-bot command installed."

# ------------------------------------------------------------
# 9. Start service
# ------------------------------------------------------------
echo ""
ask_yesno "Start the bot right now?" START_NOW
if [ "$START_NOW" == "y" ]; then
    systemctl start vpnbot
    sleep 2
    if systemctl is-active --quiet vpnbot; then
        ok "Bot started successfully!"
    else
        err "Bot failed to start. Check the logs: journalctl -u vpnbot -n 50"
    fi
fi

echo ""
echo "======================================================"
ok "Installation complete!"
echo "======================================================"
echo ""
echo "To manage the bot, use:"
echo -e "   ${C_CYAN}vpn-bot${C_NC}"
echo ""
echo "Quick commands:"
echo "   vpn-bot start | stop | restart | status | logs | backup | restore | health"
echo ""
