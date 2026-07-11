#!/bin/bash
set -e
REPO_URL="https://github.com/alireza2692/3xui-telegram-bot.git"
REPO_BRANCH="main"

if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root (sudo)."
    exit 1
fi

echo ""
echo "======================================================"
echo "   3XUI Telegram Bot - Lightweight Installer"
echo "======================================================"
echo ""

read -rp "Install directory [default: /root/bot]: " BOT_DIR
[ -z "$BOT_DIR" ] && BOT_DIR="/root/bot"
mkdir -p "$BOT_DIR"

echo ""
echo "Setup mode"
echo "  1) Fresh install - download source from GitHub and answer all questions"
echo "  2) Restore from an existing backup (.tar.gz made by 'vpn-bot backup')"
SETUP_MODE=""
while [[ "$SETUP_MODE" != "1" && "$SETUP_MODE" != "2" ]]; do
    read -rp "Choose (1/2): " SETUP_MODE
done

RESTORE_MODE="n"
if [ "$SETUP_MODE" == "2" ]; then
    RESTORE_MODE="y"
    read -rp "Full path to the backup .tar.gz file: " BACKUP_FILE
    [ ! -f "$BACKUP_FILE" ] && { echo "File not found: $BACKUP_FILE"; exit 1; }
    tar -xzf "$BACKUP_FILE" -C "$BOT_DIR"
    [ ! -f "$BOT_DIR/.env" ] && { echo "Backup did not contain a .env file."; exit 1; }
fi

if [ "$RESTORE_MODE" == "n" ]; then
    if ! command -v git &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq && apt-get install -y -qq git
        elif command -v dnf &> /dev/null; then dnf install -y -q git
        elif command -v yum &> /dev/null; then yum install -y -q git
        fi
    fi

    TMP_ENV=""
    if [ -f "$BOT_DIR/.env" ]; then
        TMP_ENV=$(mktemp)
        cp "$BOT_DIR/.env" "$TMP_ENV"
    fi

    TMP_CLONE=$(mktemp -d)
    if git clone -b "$REPO_BRANCH" --depth 1 "$REPO_URL" "$TMP_CLONE" 2>/dev/null; then
        rsync -a --exclude='.git' --exclude='.env' "$TMP_CLONE"/ "$BOT_DIR"/ 2>/dev/null || cp -r "$TMP_CLONE"/. "$BOT_DIR"/
        rm -rf "$TMP_CLONE"
    else
        echo "Failed to clone the repository."
        exit 1
    fi

    if [ -n "$TMP_ENV" ]; then
        cp "$TMP_ENV" "$BOT_DIR/.env"
        rm -f "$TMP_ENV"
    fi
fi

source "$BOT_DIR/scripts/utils.sh"

if [ "$RESTORE_MODE" == "n" ]; then
    echo ""
    info "Telegram bot info"
    ask_required "Bot token (BOT_TOKEN)" BOT_TOKEN
    ask_required "Admin numeric IDs (from @userinfobot,comma-separated, e.g. 123,456)" ADMIN_IDS
    ask_required "Support Username (@support)" SUPPORT

    echo ""
    info "Mandatory channel membership"
    ask_yesno "Enable mandatory channel membership check?" WANT_CHANNEL
    if [ "$WANT_CHANNEL" == "y" ]; then
        ask_required "Channel numeric ID" REQUIRED_CHANNEL_ID
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
    ask_required "Subscription base URL" SUB_BASE_URL
    PANEL_URL="${PANEL_URL%/}"
    PANEL_PATH="${PANEL_PATH%/}"
    SUB_BASE_URL="${SUB_BASE_URL%/}"

    echo ""
    info "Fetching the inbound list from the panel..."
    INBOUNDS_JSON=$(curl -sk --max-time 15 -H "Authorization: Bearer ${PANEL_API_TOKEN}" "${PANEL_URL}${PANEL_PATH}/panel/api/inbounds/list" 2>/dev/null || true)
    if ! echo "$INBOUNDS_JSON" | grep -q '"success":true'; then
        INBOUNDS_JSON=$(curl -sk --max-time 15 -H "Authorization: Bearer ${PANEL_API_TOKEN}" "${PANEL_URL}${PANEL_PATH}/panel/inbounds/list" 2>/dev/null || true)
    fi

    INBOUNDS=""
    if echo "$INBOUNDS_JSON" | grep -q '"success":true'; then
        ok "Connected. Available inbounds:"
        python3 "$BOT_DIR/scripts/parse_panel.py" --action list --json "$INBOUNDS_JSON"
        echo ""
        read -rp "Enter the inbound ID(s) to use, comma-separated: " INB_CHOICES

        echo ""
        ask_yesno "Enable Vision flow (xtls-rprx-vision) for these inbounds?" WANT_VISION
        FLOW=""
        [ "$WANT_VISION" == "y" ] && FLOW="xtls-rprx-vision"

        IFS=',' read -ra CHOICE_ARR <<< "$INB_CHOICES"
        for idx in "${CHOICE_ARR[@]}"; do
            idx="$(echo -n "$idx" | xargs)"
            [ -z "$idx" ] && continue
            LINE=$(python3 "$BOT_DIR/scripts/parse_panel.py" --action validate --json "$INBOUNDS_JSON" --id "$idx")
            if [ "$LINE" == "INVALID" ]; then
                warn "Invalid selection: $idx (skipped)"
                continue
            fi
            IB_ID=$(echo "$LINE" | cut -d'|' -f1)
            IB_REMARK=$(echo "$LINE" | cut -d'|' -f2)
            IB_IS_REALITY=$(echo "$LINE" | cut -d'|' -f3)
            [ "$IB_IS_REALITY" == "y" ] && ENTRY_FLOW="$FLOW" || ENTRY_FLOW=""
            ENTRY="${IB_ID}:${IB_REMARK}:${ENTRY_FLOW}"
            [ -z "$INBOUNDS" ] && INBOUNDS="$ENTRY" || INBOUNDS="${INBOUNDS},${ENTRY}"
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
    ask_yesno "Are you using a local SOCKS5 proxy?" WANT_PROXY
    if [ "$WANT_PROXY" == "y" ]; then
        ask_required "Proxy host" PROXY_HOST
        ask_required "Proxy port" PROXY_PORT
    else
        PROXY_HOST=""
        PROXY_PORT=""
    fi

    echo ""
    info "Log channel"
    ask_yesno "Enable the log channel?" WANT_LOG
    [ "$WANT_LOG" == "y" ] && ask_required "Log channel numeric ID" LOG_CHANNEL_ID || LOG_CHANNEL_ID="0"

    echo ""
    info "Expiry reminder system"
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
        ask_number "How many card numbers do you want to add (at least 1)" CARD_COUNT
    done

    CARDS=""
    for ((i=1; i<=CARD_COUNT; i++)); do
        echo ""
        echo "--- Card $i ---"
        ask_required "Card number" CARD_NUM
        ask_required "Cardholder name" CARD_NAME
        [ -z "$CARDS" ] && CARDS="${CARD_NUM}:${CARD_NAME}" || CARDS="${CARDS},${CARD_NUM}:${CARD_NAME}"
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
SUPPORT=${SUPPORT}
DB_PATH=vpn_bot.db
ENVEOF
    ok ".env file created at $BOT_DIR/.env"
fi

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
elif command -v dnf &> /dev/null; then dnf install -y -q python3 python3-pip python3-virtualenv sqlite curl nano git rsync
elif command -v yum &> /dev/null; then yum install -y -q python3 python3-pip sqlite curl nano git rsync
fi

cd "$BOT_DIR"
[ -d ".venv" ] && [ ! -f ".venv/bin/python3" ] && rm -rf .venv
[ ! -d ".venv" ] && python3 -m venv .venv
.venv/bin/python3 -m pip install --upgrade pip -q
if [ -f "requirements.txt" ]; then .venv/bin/python3 -m pip install -r requirements.txt -q
fi

echo ""
info "Creating systemd service..."
cp "$BOT_DIR/scripts/vpnbot.service" /etc/systemd/system/vpnbot.service
sed -i "s|{{BOT_DIR}}|$BOT_DIR|g" /etc/systemd/system/vpnbot.service
systemctl daemon-reload
systemctl enable vpnbot -q
ok "vpnbot service created and enabled."

echo ""
info "Installing the vpn-bot management command..."
cp "$BOT_DIR/scripts/vpn-bot.sh" /usr/local/bin/vpn-bot
sed -i "s|{{BOT_DIR}}|$BOT_DIR|g" /usr/local/bin/vpn-bot
chmod +x /usr/local/bin/vpn-bot
ok "vpn-bot command installed."

echo ""
ask_yesno "Start the bot right now?" START_NOW
if [ "$START_NOW" == "y" ]; then
    systemctl start vpnbot
    sleep 2
    systemctl is-active --quiet vpnbot && ok "Bot started successfully!" || err "Bot failed to start. Check: journalctl -u vpnbot -n 50"
fi

echo ""
echo "======================================================"
ok "Installation complete! Run 'vpn-bot' to manage the bot."
echo "======================================================"
