set -e

REPO_URL="https://github.com/alireza2692/3xui-telegram-bot.git"
BRANCH="main"

BOT_DIR="/opt/telegram-bot"

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
    local prompt="$1"
    local __resultvar="$2"
    local value=""
    while [ -z "$value" ]; do
        read -rp "$prompt: " value
        value="$(echo -n "$value" | xargs)"
        if [ -z "$value" ]; then
            warn "This field is required and cannot be empty. Please try again."
        fi
    done
    printf -v "$__resultvar" '%s' "$value"
}
ask_optional() {
    local prompt="$1"
    local default="$2"
    local __resultvar="$3"
    local value=""
    read -rp "$prompt: " value
    value="$(echo -n "$value" | xargs)"
    if [ -z "$value" ]; then
        value="$default"
    fi
    printf -v "$__resultvar" '%s' "$value"
}
ask_yesno() {
    local prompt="$1"
    local __resultvar="$2"
    local value=""
    while [[ "$value" != "y" && "$value" != "n" ]]; do
        read -rp "$prompt (y/n): " value
        value="$(echo -n "$value" | xargs | tr '[:upper:]' '[:lower:]')"
        if [[ "$value" != "y" && "$value" != "n" ]]; then
            warn "Please enter y or n only."
        fi
    done
    printf -v "$__resultvar" '%s' "$value"
}
if [ "$EUID" -ne 0 ]; then
    err "Please run this script as root (sudo)."
    exit 1
fi

echo ""
echo "======================================================"
echo "   Nex1Shield VPN Bot - Installer"
echo "======================================================"
echo ""

if ! command -v git >/dev/null 2>&1; then
    apt-get update
    apt-get install -y git
fi

if [ -d "$BOT_DIR" ]; then
    warn "Directory $BOT_DIR already exists and may be overwritten."
    ask_yesno "Continue?" CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        err "Installation cancelled."
        exit 1
    fi
fi

if [ -d "$BOT_DIR/.git" ]; then
    info "Updating source..."
    cd "$BOT_DIR"
    git pull origin "$BRANCH"
else
    info "Downloading source..."
    rm -rf "$BOT_DIR"
    git clone -b "$BRANCH" --depth 1 "$REPO_URL" "$BOT_DIR"
fi

cd "$BOT_DIR"
echo ""
info "Setup mode"
echo "  1) Fresh install - answer all questions from scratch"
echo "  2) Restore from an existing backup (.tar.gz made by 'vpn-bot backup')"
SETUP_MODE=""
while [[ "$SETUP_MODE" != "1" && "$SETUP_MODE" != "2" ]]; do
    read -rp "Choose (1/2): " SETUP_MODE
    if [[ "$SETUP_MODE" != "1" && "$SETUP_MODE" != "2" ]]; then
        warn "Please enter 1 or 2."
    fi
done

RESTORE_MODE="n"
if [ "$SETUP_MODE" == "2" ]; then
    RESTORE_MODE="y"
    ask_required "Full path to the backup .tar.gz file" BACKUP_FILE
    if [ ! -f "$BACKUP_FILE" ]; then
        err "File not found: $BACKUP_FILE"
        exit 1
    fi
    info "Extracting backup into $BOT_DIR ..."
    tar -xzf "$BACKUP_FILE" -C "$BOT_DIR"
    if [ ! -f "$BOT_DIR/.env" ]; then
        err "The backup did not contain a .env file. Cannot continue in restore mode."
        exit 1
    fi
    ok "Backup restored. Skipping the configuration questions below."
fi

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
    ask_required "Channel invite link (e.g. https://t.me/yourchannel)" REQUIRED_CHANNEL_INVITE
else
    REQUIRED_CHANNEL_ID="0"
    REQUIRED_CHANNEL_INVITE=""
fi

echo ""
info "3X-UI Panel info"
ask_required "Panel URL with https and port - no trailing slash (e.g. https://example.com:2053)" PANEL_URL
ask_required "Panel path (webBasePath) - starts with /, no trailing slash (e.g. /randompath)" PANEL_PATH
ask_required "Panel API token" PANEL_API_TOKEN
ask_required "Subscription base URL - no trailing slash (e.g. https://example.com:2096/sub)" SUB_BASE_URL
PANEL_URL="${PANEL_URL%/}"
PANEL_PATH="${PANEL_PATH%/}"
SUB_BASE_URL="${SUB_BASE_URL%/}"
echo ""
info "Connecting to the panel to fetch the inbound list..."

INBOUNDS_JSON=$(curl -sk --max-time 15 \
    -H "Authorization: Bearer ${PANEL_API_TOKEN}" \
    "${PANEL_URL}${PANEL_PATH}/panel/api/inbounds/list" 2>/dev/null || true)
if ! echo "$INBOUNDS_JSON" | grep -q '"success":true'; then
    INBOUNDS_JSON=$(curl -sk --max-time 15 \
        -H "Authorization: Bearer ${PANEL_API_TOKEN}" \
        "${PANEL_URL}${PANEL_PATH}/panel/inbounds/list" 2>/dev/null || true)
fi

INBOUND_LIST_OK="n"
if echo "$INBOUNDS_JSON" | grep -q '"success":true'; then
    INBOUND_LIST_OK="y"
fi

INBOUNDS=""

if [ "$INBOUND_LIST_OK" == "y" ]; then
    ok "Connected. Parsing inbound list..."
    python3 - "$INBOUNDS_JSON" << 'PYEOF'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    print("PARSE_ERROR")
    sys.exit(0)
obj = data.get("obj", [])
if not obj:
    print("EMPTY")
    sys.exit(0)
for i, inb in enumerate(obj, 1):
    remark = inb.get("remark") or f"inbound-{inb.get('id')}"
    protocol = inb.get("protocol", "?")
    port = inb.get("port", "?")
    security = ""
    try:
        ss = json.loads(inb.get("streamSettings", "{}"))
        security = ss.get("security", "")
    except Exception:
        pass
    tag = f"{protocol}"
    if security:
        tag += f"/{security}"
    print(f"{i}) id={inb.get('id')}  [{tag}]  port={port}  remark=\"{remark}\"")
PYEOF

    echo ""
    read -rp "Enter the numbers of the inbounds to use for client creation (comma-separated, e.g. 1,3): " INB_CHOICES

    IFS=',' read -ra CHOICE_ARR <<< "$INB_CHOICES"
    for idx in "${CHOICE_ARR[@]}"; do
        idx="$(echo -n "$idx" | xargs)"
        [ -z "$idx" ] && continue
        LINE=$(python3 - "$INBOUNDS_JSON" "$idx" << 'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
i = int(sys.argv[2])
obj = data.get("obj", [])
if i < 1 or i > len(obj):
    print("INVALID")
    sys.exit(0)
inb = obj[i-1]
remark = inb.get("remark") or f"inbound-{inb.get('id')}"
protocol = inb.get("protocol", "")
security = ""
try:
    ss = json.loads(inb.get("streamSettings", "{}"))
    security = ss.get("security", "")
except Exception:
    pass
print(f"{inb.get('id')}|{protocol}|{security}|{remark}")
PYEOF
)
        if [ "$LINE" == "INVALID" ]; then
            warn "Invalid selection: $idx (skipped)"
            continue
        fi

        IB_ID="${LINE%%|*}"
        REST="${LINE#*|}"
        IB_PROTO="${REST%%|*}"
        REST2="${REST#*|}"
        IB_SEC="${REST2%%|*}"
        IB_REMARK="${REST2#*|}"

        FLOW=""
        if [ "$IB_PROTO" == "vless" ] && [ "$IB_SEC" == "reality" ]; then
            echo ""
            ask_yesno "Inbound \"$IB_REMARK\" (id=$IB_ID) is VLESS Reality. Use Vision flow (xtls-rprx-vision) for it?" WANT_VISION
            if [ "$WANT_VISION" == "y" ]; then
                FLOW="xtls-rprx-vision"
            fi
        fi

        ENTRY="${IB_ID}:${IB_REMARK}:${FLOW}"
        if [ -z "$INBOUNDS" ]; then
            INBOUNDS="$ENTRY"
        else
            INBOUNDS="${INBOUNDS},${ENTRY}"
        fi
    done
fi

if [ -z "$INBOUNDS" ]; then
    warn "Could not auto-fetch inbounds from the panel (or none selected)."
    ask_required "Enter Inbound ID manually (the main inbound clients will be created on)" INBOUND_ID_MANUAL
    ask_yesno "Is this inbound VLESS Reality?" IS_REALITY
    FLOW=""
    if [ "$IS_REALITY" == "y" ]; then
        ask_yesno "Use Vision flow (xtls-rprx-vision) for it?" WANT_VISION
        [ "$WANT_VISION" == "y" ] && FLOW="xtls-rprx-vision"
    fi
    INBOUNDS="${INBOUND_ID_MANUAL}:default:${FLOW}"
fi
INBOUND_ID="${INBOUNDS%%:*}"

echo ""
ok "Selected inbound(s): $INBOUNDS"
echo ""
info "Local SOCKS5 proxy"
echo "This proxy is used to bypass sanctions when calling the Telegram API."
echo "If your server can reach Telegram directly (no filtering), you don't need it."
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
    ask_required "Log channel numeric ID (the bot must be an admin there)" LOG_CHANNEL_ID
else
    LOG_CHANNEL_ID="0"
fi
echo ""
info "Payment card numbers"
CARD_COUNT=""
while [[ -z "$CARD_COUNT" || ! "$CARD_COUNT" =~ ^[0-9]+$ || "$CARD_COUNT" -lt 1 ]]; do
    read -rp "How many card numbers do you want to add? (at least 1): " CARD_COUNT
    if [[ ! "$CARD_COUNT" =~ ^[0-9]+$ || "$CARD_COUNT" -lt 1 ]]; then
        warn "Please enter a whole number, at least 1."
        CARD_COUNT=""
    fi
done

CARDS=""
for ((i=1; i<=CARD_COUNT; i++)); do
    echo ""
    echo "--- Card $i ---"
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
DB_PATH=vpn_bot.db
ENVEOF

ok ".env file created at $BOT_DIR/.env"

fi
echo ""
info "Checking and installing system dependencies..."

PY_VER=""
if command -v python3 &> /dev/null; then
    PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
fi

if command -v apt-get &> /dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    PKGS="python3 python3-pip sqlite3 curl python3-venv python3-full nano"
    if [ -n "$PY_VER" ]; then
        PKGS="$PKGS python${PY_VER}-venv"
    fi
    apt-get install -y -qq $PKGS
elif command -v dnf &> /dev/null; then
    dnf install -y -q python3 python3-pip python3-virtualenv sqlite curl nano
elif command -v yum &> /dev/null; then
    yum install -y -q python3 python3-pip sqlite curl nano
else
    warn "Unknown package manager; assuming python3/pip/venv are already installed."
fi

if ! command -v python3 &> /dev/null; then
    err "Failed to install python3."
    exit 1
fi

ok "System dependencies are ready."
if [ ! -f "$BOT_DIR/requirements.txt" ]; then
    warn "requirements.txt not found in $BOT_DIR."
    warn "Make sure the bot's source files were copied to $BOT_DIR before running this script."
fi

cd "$BOT_DIR"

if [ -d ".venv" ] && [ ! -f ".venv/bin/python3" ]; then
    warn ".venv exists but looks incomplete; removing and rebuilding."
    rm -rf .venv
fi

if [ ! -d ".venv" ]; then
    info "Creating virtual environment..."
    python3 -m venv .venv
fi

if [ ! -f ".venv/bin/python3" ]; then
    err "Failed to create the virtual environment. Please check manually: python3 -m venv .venv"
    exit 1
fi
ok "Virtual environment is ready."

info "Installing packages..."
.venv/bin/python3 -m pip install --upgrade pip -q
if [ -f "requirements.txt" ]; then
    .venv/bin/python3 -m pip install -r requirements.txt -q
    ok "Packages installed."
else
    warn "requirements.txt not found; skipped package install."
fi
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
echo ""
info "Installing the vpn-bot management command..."

cat > /usr/local/bin/vpn-bot << CLIEOF
BOT_DIR="${BOT_DIR}"
SERVICE="vpnbot"
BACKUP_DIR="\${BOT_DIR}/backups"
mkdir -p "\$BACKUP_DIR"
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'
C_BLUE='\033[0;34m'
C_MAGENTA='\033[0;35m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_NC='\033[0m'

pause() { read -rp "Press Enter to continue..." _; }

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
    tar -czf "\$OUT" \\
        -C "\$BOT_DIR" \\
        .env \\
        config.py database.py main.py requirements.txt \\
        vpn_bot.db \\
        handlers keyboards middlewares services utils \\
        2>/dev/null || true
    echo -e "\${C_GREEN}✔ Backup saved:\${C_NC} \$OUT"
}

do_restore() {
    echo -e "\${C_CYAN}Available backups:\${C_NC}"
    ls -1t "\$BACKUP_DIR" 2>/dev/null | nl
    echo ""
    read -rp "Enter backup number to restore (or full file path): " CHOICE
    if [[ "\$CHOICE" =~ ^[0-9]+\$ ]]; then
        FILE=\$(ls -1t "\$BACKUP_DIR" | sed -n "\${CHOICE}p")
        FILE="\$BACKUP_DIR/\$FILE"
    else
        FILE="\$CHOICE"
    fi
    if [ ! -f "\$FILE" ]; then
        echo -e "\${C_RED}✘ File not found.\${C_NC}"
        return
    fi
    echo -e "\${C_YELLOW}⚠ Warning: this will overwrite the current bot files.\${C_NC}"
    read -rp "Are you sure? (y/n): " CONFIRM
    if [ "\$CONFIRM" != "y" ]; then
        echo "Cancelled."
        return
    fi
    systemctl stop \$SERVICE
    tar -xzf "\$FILE" -C "\$BOT_DIR"
    systemctl start \$SERVICE
    echo -e "\${C_GREEN}✔ Restore complete, bot restarted.\${C_NC}"
}

env_get() {
    local key="\$1"
    grep "^\${key}=" "\$BOT_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-
}

env_set() {
    local key="\$1"
    local value="\$2"
    if grep -q "^\${key}=" "\$BOT_DIR/.env" 2>/dev/null; then
        local esc_value
        esc_value=\$(printf '%s' "\$value" | sed -e 's/[\\/&]/\\\\&/g')
        sed -i "s|^\${key}=.*|\${key}=\${esc_value}|" "\$BOT_DIR/.env"
    else
        echo "\${key}=\${value}" >> "\$BOT_DIR/.env"
    fi
}

ask_restart() {
    read -rp "Restart the bot now to apply changes? (y/n): " R
    if [ "\$R" == "y" ]; then
        systemctl restart \$SERVICE
        echo -e "\${C_GREEN}✔ Restarted.\${C_NC}"
    fi
}

mask() {
    local v="\$1"
    local len=\${#v}
    if [ "\$len" -le 8 ]; then
        echo "****"
    else
        echo "\${v:0:4}...\${v: -4}"
    fi
}
settings_bot() {
    while true; do
        clear
        echo -e "\${C_BLUE}\${C_BOLD}--- Bot & Admins ---\${C_NC}"
        echo -e "1) Bot token         [\$(mask "\$(env_get BOT_TOKEN)")]"
        echo -e "2) Admin IDs         [\$(env_get ADMIN_IDS)]"
        echo -e "0) Back"
        read -rp "Choose: " C
        case \$C in
            1) read -rp "New bot token: " V; [ -n "\$V" ] && env_set BOT_TOKEN "\$V" && ok "Updated." && ask_restart; pause ;;
            2) read -rp "New admin IDs (comma-separated): " V; [ -n "\$V" ] && env_set ADMIN_IDS "\$V" && ok "Updated." && ask_restart; pause ;;
            0) return ;;
            *) echo "Invalid option."; pause ;;
        esac
    done
}
settings_channel() {
    while true; do
        clear
        echo -e "\${C_BLUE}\${C_BOLD}--- Mandatory Channel ---\${C_NC}"
        echo -e "1) Channel ID        [\$(env_get REQUIRED_CHANNEL_ID)]"
        echo -e "2) Invite link       [\$(env_get REQUIRED_CHANNEL_INVITE)]"
        echo -e "3) Disable channel check (set ID to 0)"
        echo -e "0) Back"
        read -rp "Choose: " C
        case \$C in
            1) read -rp "New channel ID: " V; [ -n "\$V" ] && env_set REQUIRED_CHANNEL_ID "\$V" && ok "Updated." && ask_restart; pause ;;
            2) read -rp "New invite link: " V; [ -n "\$V" ] && env_set REQUIRED_CHANNEL_INVITE "\$V" && ok "Updated." && ask_restart; pause ;;
            3) env_set REQUIRED_CHANNEL_ID "0"; ok "Channel check disabled."; ask_restart; pause ;;
            0) return ;;
            *) echo "Invalid option."; pause ;;
        esac
    done
}
settings_panel() {
    while true; do
        clear
        echo -e "\${C_BLUE}\${C_BOLD}--- 3X-UI Panel ---\${C_NC}"
        echo -e "1) Panel URL         [\$(env_get PANEL_URL)]"
        echo -e "2) Panel path        [\$(env_get PANEL_PATH)]"
        echo -e "3) API token         [\$(mask "\$(env_get PANEL_API_TOKEN)")]"
        echo -e "4) Subscription URL  [\$(env_get SUB_BASE_URL)]"
        echo -e "0) Back"
        read -rp "Choose: " C
        case \$C in
            1) read -rp "New panel URL (no trailing slash): " V; V="\${V%/}"; [ -n "\$V" ] && env_set PANEL_URL "\$V" && ok "Updated." && ask_restart; pause ;;
            2) read -rp "New panel path (no trailing slash): " V; V="\${V%/}"; [ -n "\$V" ] && env_set PANEL_PATH "\$V" && ok "Updated." && ask_restart; pause ;;
            3) read -rp "New API token: " V; [ -n "\$V" ] && env_set PANEL_API_TOKEN "\$V" && ok "Updated." && ask_restart; pause ;;
            4) read -rp "New subscription URL (no trailing slash): " V; V="\${V%/}"; [ -n "\$V" ] && env_set SUB_BASE_URL "\$V" && ok "Updated." && ask_restart; pause ;;
            0) return ;;
            *) echo "Invalid option."; pause ;;
        esac
    done
}
settings_inbounds() {
    while true; do
        clear
        echo -e "\${C_BLUE}\${C_BOLD}--- Inbounds ---\${C_NC}"
        echo "Format: id:remark:flow (flow empty for non-Reality inbounds)"
        echo ""
        IFS=',' read -ra IB_ARR <<< "\$(env_get INBOUNDS)"
        if [ \${#IB_ARR[@]} -eq 0 ] || [ -z "\${IB_ARR[0]}" ]; then
            echo -e "\${C_DIM}(none configured — falling back to INBOUND_ID=\$(env_get INBOUND_ID))\${C_NC}"
        else
            i=1
            for entry in "\${IB_ARR[@]}"; do
                echo "  \$i) \$entry"
                i=\$((i+1))
            done
        fi
        echo ""
        echo "1) Fetch inbound list from panel and rebuild selection"
        echo "2) Add one inbound manually"
        echo "3) Remove an inbound by number"
        echo "4) Clear all (fallback to single INBOUND_ID)"
        echo "0) Back"
        read -rp "Choose: " C
        case \$C in
            1)
                TOKEN=\$(env_get PANEL_API_TOKEN)
                PURL=\$(env_get PANEL_URL)
                PPATH=\$(env_get PANEL_PATH)
                echo "Fetching inbounds..."
                JSON=\$(curl -sk --max-time 15 -H "Authorization: Bearer \${TOKEN}" "\${PURL}\${PPATH}/panel/api/inbounds/list" 2>/dev/null)
                if ! echo "\$JSON" | grep -q '"success":true'; then
                    echo -e "\${C_RED}Failed to reach the panel.\${C_NC}"; pause; continue
                fi
                python3 - "\$JSON" << 'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
obj = data.get("obj", [])
for i, inb in enumerate(obj, 1):
    remark = inb.get("remark") or f"inbound-{inb.get('id')}"
    protocol = inb.get("protocol", "?")
    port = inb.get("port", "?")
    security = ""
    try:
        ss = json.loads(inb.get("streamSettings", "{}"))
        security = ss.get("security", "")
    except Exception:
        pass
    tag = protocol + (f"/{security}" if security else "")
    print(f"{i}) id={inb.get('id')}  [{tag}]  port={port}  remark=\"{remark}\"")
PYEOF
                read -rp "Enter numbers to include (comma-separated): " PICKS
                NEW_INBOUNDS=""
                IFS=',' read -ra PARR <<< "\$PICKS"
                for idx in "\${PARR[@]}"; do
                    idx="\$(echo -n "\$idx" | xargs)"
                    [ -z "\$idx" ] && continue
                    LINE=\$(python3 - "\$JSON" "\$idx" << 'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
i = int(sys.argv[2])
obj = data.get("obj", [])
if i < 1 or i > len(obj):
    print("INVALID"); sys.exit(0)
inb = obj[i-1]
remark = inb.get("remark") or f"inbound-{inb.get('id')}"
protocol = inb.get("protocol", "")
security = ""
try:
    ss = json.loads(inb.get("streamSettings", "{}"))
    security = ss.get("security", "")
except Exception:
    pass
print(f"{inb.get('id')}|{protocol}|{security}|{remark}")
PYEOF
)
                    [ "\$LINE" == "INVALID" ] && continue
                    IB_ID="\${LINE%%|*}"; REST="\${LINE#*|}"
                    IB_PROTO="\${REST%%|*}"; REST2="\${REST#*|}"
                    IB_SEC="\${REST2%%|*}"; IB_REMARK="\${REST2#*|}"
                    FLOW=""
                    if [ "\$IB_PROTO" == "vless" ] && [ "\$IB_SEC" == "reality" ]; then
                        read -rp "Inbound \"\$IB_REMARK\" is Reality. Use Vision flow? (y/n): " WV
                        [ "\$WV" == "y" ] && FLOW="xtls-rprx-vision"
                    fi
                    ENTRY="\${IB_ID}:\${IB_REMARK}:\${FLOW}"
                    if [ -z "\$NEW_INBOUNDS" ]; then NEW_INBOUNDS="\$ENTRY"; else NEW_INBOUNDS="\${NEW_INBOUNDS},\${ENTRY}"; fi
                done
                if [ -n "\$NEW_INBOUNDS" ]; then
                    env_set INBOUNDS "\$NEW_INBOUNDS"
                    env_set INBOUND_ID "\${NEW_INBOUNDS%%:*}"
                    ok "Inbounds updated: \$NEW_INBOUNDS"
                    ask_restart
                fi
                pause
                ;;
            2)
                read -rp "Inbound ID: " IID
                read -rp "Display name (remark): " IREM
                read -rp "Is this Reality? (y/n): " ISR
                FLOW=""
                if [ "\$ISR" == "y" ]; then
                    read -rp "Use Vision flow? (y/n): " WV
                    [ "\$WV" == "y" ] && FLOW="xtls-rprx-vision"
                fi
                CUR=\$(env_get INBOUNDS)
                ENTRY="\${IID}:\${IREM}:\${FLOW}"
                if [ -z "\$CUR" ]; then NEWV="\$ENTRY"; else NEWV="\${CUR},\${ENTRY}"; fi
                env_set INBOUNDS "\$NEWV"
                [ -z "\$(env_get INBOUND_ID)" ] && env_set INBOUND_ID "\$IID"
                ok "Inbound added."
                ask_restart
                pause
                ;;
            3)
                read -rp "Number to remove: " RIDX
                CUR=\$(env_get INBOUNDS)
                IFS=',' read -ra ARR <<< "\$CUR"
                NEWV=""
                i=1
                for entry in "\${ARR[@]}"; do
                    if [ "\$i" != "\$RIDX" ]; then
                        if [ -z "\$NEWV" ]; then NEWV="\$entry"; else NEWV="\${NEWV},\${entry}"; fi
                    fi
                    i=\$((i+1))
                done
                env_set INBOUNDS "\$NEWV"
                ok "Removed."
                ask_restart
                pause
                ;;
            4)
                env_set INBOUNDS ""
                ok "Cleared. Bot will fall back to single INBOUND_ID."
                ask_restart
                pause
                ;;
            0) return ;;
            *) echo "Invalid option."; pause ;;
        esac
    done
}
settings_proxy() {
    while true; do
        clear
        echo -e "\${C_BLUE}\${C_BOLD}--- SOCKS5 Proxy ---\${C_NC}"
        echo -e "1) Proxy host        [\$(env_get PROXY_HOST)]"
        echo -e "2) Proxy port        [\$(env_get PROXY_PORT)]"
        echo -e "3) Disable proxy (direct connection)"
        echo -e "0) Back"
        read -rp "Choose: " C
        case \$C in
            1) read -rp "New proxy host: " V; env_set PROXY_HOST "\$V"; ok "Updated."; ask_restart; pause ;;
            2) read -rp "New proxy port: " V; env_set PROXY_PORT "\$V"; ok "Updated."; ask_restart; pause ;;
            3) env_set PROXY_HOST ""; env_set PROXY_PORT ""; ok "Proxy disabled."; ask_restart; pause ;;
            0) return ;;
            *) echo "Invalid option."; pause ;;
        esac
    done
}
settings_log() {
    while true; do
        clear
        echo -e "\${C_BLUE}\${C_BOLD}--- Log Channel ---\${C_NC}"
        echo -e "1) Log channel ID    [\$(env_get LOG_CHANNEL_ID)]"
        echo -e "2) Disable log channel"
        echo -e "0) Back"
        read -rp "Choose: " C
        case \$C in
            1) read -rp "New log channel ID: " V; env_set LOG_CHANNEL_ID "\$V"; ok "Updated."; ask_restart; pause ;;
            2) env_set LOG_CHANNEL_ID "0"; ok "Log channel disabled."; ask_restart; pause ;;
            0) return ;;
            *) echo "Invalid option."; pause ;;
        esac
    done
}
settings_cards() {
    while true; do
        clear
        echo -e "\${C_BLUE}\${C_BOLD}--- Payment Cards ---\${C_NC}"
        IFS=',' read -ra CARD_ARR <<< "\$(env_get CARDS)"
        i=1
        for entry in "\${CARD_ARR[@]}"; do
            echo "  \$i) \$entry"
            i=\$((i+1))
        done
        echo ""
        echo "1) Add a card"
        echo "2) Remove a card by number"
        echo "0) Back"
        read -rp "Choose: " C
        case \$C in
            1)
                read -rp "Card number: " CNUM
                read -rp "Cardholder name: " CNAME
                CUR=\$(env_get CARDS)
                ENTRY="\${CNUM}:\${CNAME}"
                if [ -z "\$CUR" ]; then NEWV="\$ENTRY"; else NEWV="\${CUR},\${ENTRY}"; fi
                env_set CARDS "\$NEWV"
                ok "Card added."
                ask_restart
                pause
                ;;
            2)
                read -rp "Number to remove: " RIDX
                CUR=\$(env_get CARDS)
                IFS=',' read -ra ARR <<< "\$CUR"
                NEWV=""
                i=1
                for entry in "\${ARR[@]}"; do
                    if [ "\$i" != "\$RIDX" ]; then
                        if [ -z "\$NEWV" ]; then NEWV="\$entry"; else NEWV="\${NEWV},\${entry}"; fi
                    fi
                    i=\$((i+1))
                done
                env_set CARDS "\$NEWV"
                ok "Removed."
                ask_restart
                pause
                ;;
            0) return ;;
            *) echo "Invalid option."; pause ;;
        esac
    done
}

edit_env() {
    while true; do
        clear
        echo -e "\${C_BLUE}\${C_BOLD}╔══════════════════════════════════════════════════╗\${C_NC}"
        echo -e "\${C_BLUE}\${C_BOLD}║                Settings — Categories               ║\${C_NC}"
        echo -e "\${C_BLUE}\${C_BOLD}╚══════════════════════════════════════════════════╝\${C_NC}"
        echo -e "  1) Bot & Admins"
        echo -e "  2) Mandatory Channel"
        echo -e "  3) Panel (3X-UI)"
        echo -e "  4) Inbounds / Servers"
        echo -e "  5) SOCKS5 Proxy"
        echo -e "  6) Log Channel"
        echo -e "  7) Payment Cards"
        echo -e "  8) Raw .env editor (advanced, requires an editor installed)"
        echo -e "  0) Back to main menu"
        read -rp "Choose a category: " CAT
        case \$CAT in
            1) settings_bot ;;
            2) settings_channel ;;
            3) settings_panel ;;
            4) settings_inbounds ;;
            5) settings_proxy ;;
            6) settings_log ;;
            7) settings_cards ;;
            8)
                if command -v nano &> /dev/null; then
                    nano "\$BOT_DIR/.env"
                elif command -v vi &> /dev/null; then
                    vi "\$BOT_DIR/.env"
                else
                    echo -e "\${C_YELLOW}No editor found. Installing nano...\${C_NC}"
                    apt-get install -y -qq nano 2>/dev/null || yum install -y -q nano 2>/dev/null || dnf install -y -q nano 2>/dev/null
                    if command -v nano &> /dev/null; then
                        nano "\$BOT_DIR/.env"
                    else
                        echo -e "\${C_RED}Could not install an editor. Use the categorized menu instead.\${C_NC}"
                        pause
                        continue
                    fi
                fi
                ask_restart
                ;;
            0) return ;;
            *) echo "Invalid option."; pause ;;
        esac
    done
}

health_check() {
    echo -e "\${C_CYAN}Running health checks...\${C_NC}"
    echo ""
    printf "%-30s" "Bot service:"
    if systemctl is-active --quiet \$SERVICE; then
        echo -e "\${C_GREEN}✔ running\${C_NC}"
    else
        echo -e "\${C_RED}✘ not running\${C_NC}"
    fi
    printf "%-30s" ".env file:"
    if [ -f "\$BOT_DIR/.env" ]; then
        echo -e "\${C_GREEN}✔ found\${C_NC}"
    else
        echo -e "\${C_RED}✘ missing\${C_NC}"
    fi
    if [ -f "\$BOT_DIR/.env" ]; then
        set -a
        source "\$BOT_DIR/.env"
        set +a
    fi
    printf "%-30s" "Telegram bot token:"
    if [ -n "\$BOT_TOKEN" ]; then
        TG_RESULT=\$(curl -s --max-time 10 "https://api.telegram.org/bot\${BOT_TOKEN}/getMe" 2>/dev/null)
        if echo "\$TG_RESULT" | grep -q '"ok":true'; then
            BOT_USERNAME=\$(echo "\$TG_RESULT" | grep -oP '"username":"\K[^"]+')
            echo -e "\${C_GREEN}✔ valid (@\${BOT_USERNAME})\${C_NC}"
        else
            echo -e "\${C_RED}✘ invalid or unreachable\${C_NC}"
        fi
    else
        echo -e "\${C_YELLOW}⚠ not set\${C_NC}"
    fi
    printf "%-30s" "SOCKS5 proxy:"
    if [ -n "\$PROXY_HOST" ] && [ -n "\$PROXY_PORT" ]; then
        if command -v nc &> /dev/null; then
            if nc -z -w3 "\$PROXY_HOST" "\$PROXY_PORT" 2>/dev/null; then
                echo -e "\${C_GREEN}✔ reachable (\${PROXY_HOST}:\${PROXY_PORT})\${C_NC}"
            else
                echo -e "\${C_RED}✘ cannot connect (\${PROXY_HOST}:\${PROXY_PORT})\${C_NC}"
            fi
        else
            timeout 3 bash -c "cat < /dev/null > /dev/tcp/\$PROXY_HOST/\$PROXY_PORT" 2>/dev/null
            if [ \$? -eq 0 ]; then
                echo -e "\${C_GREEN}✔ reachable (\${PROXY_HOST}:\${PROXY_PORT})\${C_NC}"
            else
                echo -e "\${C_RED}✘ cannot connect (\${PROXY_HOST}:\${PROXY_PORT})\${C_NC}"
            fi
        fi
    else
        echo -e "\${C_DIM}– disabled (direct connection)\${C_NC}"
    fi
    printf "%-30s" "3X-UI panel:"
    if [ -n "\$PANEL_URL" ]; then
        PANEL_CODE=\$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "\${PANEL_URL}\${PANEL_PATH}/login" 2>/dev/null)
        if [ -n "\$PANEL_CODE" ] && [ "\$PANEL_CODE" != "000" ]; then
            echo -e "\${C_GREEN}✔ reachable (HTTP \$PANEL_CODE)\${C_NC}"
        else
            echo -e "\${C_RED}✘ unreachable\${C_NC}"
        fi
    else
        echo -e "\${C_YELLOW}⚠ not set\${C_NC}"
    fi
    printf "%-30s" "Panel API token:"
    if [ -n "\$PANEL_URL" ] && [ -n "\$PANEL_API_TOKEN" ]; then
        API_RESULT=\$(curl -sk --max-time 10 \\
            -H "Authorization: Bearer \${PANEL_API_TOKEN}" \\
            "\${PANEL_URL}\${PANEL_PATH}/panel/api/clients/list" 2>/dev/null)
        if echo "\$API_RESULT" | grep -q '"success":true'; then
            echo -e "\${C_GREEN}✔ valid\${C_NC}"
        else
            echo -e "\${C_RED}✘ invalid or unreachable\${C_NC}"
        fi
    else
        echo -e "\${C_YELLOW}⚠ not set\${C_NC}"
    fi
    printf "%-30s" "Database file:"
    if [ -f "\$BOT_DIR/vpn_bot.db" ]; then
        DB_SIZE=\$(du -h "\$BOT_DIR/vpn_bot.db" 2>/dev/null | cut -f1)
        echo -e "\${C_GREEN}✔ found (\${DB_SIZE})\${C_NC}"
    else
        echo -e "\${C_YELLOW}⚠ not found yet (will be created on first run)\${C_NC}"
    fi
    printf "%-30s" "Disk space:"
    DISK_FREE=\$(df -h "\$BOT_DIR" 2>/dev/null | awk 'NR==2 {print \$4}')
    echo -e "\${C_CYAN}\${DISK_FREE} free\${C_NC}"

    echo ""
}

view_db_stats() {
    DB="\$BOT_DIR/vpn_bot.db"
    if [ ! -f "\$DB" ]; then
        echo -e "\${C_RED}Database not found.\${C_NC}"
        return
    fi
    echo -e "\${C_CYAN}--- Quick database stats ---\${C_NC}"
    printf "%-16s: " "Users"
    sqlite3 "\$DB" "SELECT COUNT(*) FROM wallets;" 2>/dev/null || echo "N/A"
    printf "%-16s: " "Orders"
    sqlite3 "\$DB" "SELECT COUNT(*) FROM orders;" 2>/dev/null || echo "N/A"
    printf "%-16s: " "Total revenue"
    sqlite3 "\$DB" "SELECT COALESCE(SUM(amount_paid),0) FROM orders;" 2>/dev/null || echo "N/A"
    printf "%-16s: " "Pending payments"
    sqlite3 "\$DB" "SELECT COUNT(*) FROM pending_payments WHERE status='pending';" 2>/dev/null || echo "N/A"
}

reinstall_deps() {
    cd "\$BOT_DIR"
    echo -e "\${C_CYAN}Updating Python packages...\${C_NC}"
    .venv/bin/python3 -m pip install --upgrade pip -q
    .venv/bin/python3 -m pip install -r requirements.txt -q --upgrade
    echo -e "\${C_GREEN}✔ Packages updated.\${C_NC}"
    read -rp "Restart the bot now? (y/n): " R
    [ "\$R" == "y" ] && systemctl restart \$SERVICE
}

uninstall_bot() {
    echo -e "\${C_RED}⚠ Warning: this removes the systemd service and the vpn-bot command."
    echo -e "  Bot files in \$BOT_DIR will NOT be deleted.\${C_NC}"
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
    echo -e "  \${C_GREEN}4)\${C_NC}  📊 Service status (systemctl)"
    echo -e "  \${C_GREEN}5)\${C_NC}  📜 Live logs (Ctrl+C to exit)"
    echo -e "  \${C_GREEN}6)\${C_NC}  📄 Last 100 log lines"
    echo -e "  \${C_GREEN}7)\${C_NC}  ⚙️  Edit settings (.env)"
    echo -e "  \${C_GREEN}8)\${C_NC}  💾 Create backup (code + database + .env)"
    echo -e "  \${C_GREEN}9)\${C_NC}  ♻️  Restore from backup"
    echo -e "  \${C_GREEN}10)\${C_NC} 📈 Quick database stats"
    echo -e "  \${C_GREEN}11)\${C_NC} 📦 Update Python packages"
    echo -e "  \${C_GREEN}12)\${C_NC} 🩺 Health check (panel, proxy, token)"
    echo -e "  \${C_GREEN}13)\${C_NC} 🗑  Uninstall CLI & service"
    echo -e "  \${C_RED}0)\${C_NC}  Exit"
    echo -e "\${C_DIM}──────────────────────────────────────────────────────\${C_NC}"
}

if [ -n "\$1" ]; then
    case "\$1" in
        start) systemctl start \$SERVICE; echo -e "\${C_GREEN}✔ Started.\${C_NC}" ;;
        stop) systemctl stop \$SERVICE; echo -e "\${C_YELLOW}Stopped.\${C_NC}" ;;
        restart) systemctl restart \$SERVICE; echo -e "\${C_GREEN}✔ Restarted.\${C_NC}" ;;
        status) systemctl status \$SERVICE ;;
        logs) journalctl -u \$SERVICE -f ;;
        backup) do_backup ;;
        restore) do_restore ;;
        health) health_check ;;
        *) echo -e "\${C_RED}Unknown command:\${C_NC} \$1" ;;
    esac
    exit 0
fi

while true; do
    show_menu
    read -rp "Choose an option: " CHOICE
    case \$CHOICE in
        1) systemctl start \$SERVICE; echo -e "\${C_GREEN}✔ Started.\${C_NC}"; pause ;;
        2) systemctl stop \$SERVICE; echo -e "\${C_YELLOW}Stopped.\${C_NC}"; pause ;;
        3) systemctl restart \$SERVICE; echo -e "\${C_GREEN}✔ Restarted.\${C_NC}"; pause ;;
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
        *) echo -e "\${C_RED}Invalid option.\${C_NC}"; pause ;;
    esac
done
CLIEOF

chmod +x /usr/local/bin/vpn-bot
ok "vpn-bot command installed."
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
