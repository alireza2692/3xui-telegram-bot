#!/bin/bash
BOT_DIR="{{BOT_DIR}}"
SERVICE="vpnbot"
BACKUP_DIR="${BOT_DIR}/backups"
mkdir -p "$BACKUP_DIR"

C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'
C_BLUE='\033[0;34m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_NC='\033[0m'

info()  { echo -e "${C_CYAN}[*]${C_NC} $1"; }
ok()    { echo -e "${C_GREEN}[OK]${C_NC} $1"; }
warn()  { echo -e "${C_YELLOW}[!]${C_NC} $1"; }
err()   { echo -e "${C_RED}[X]${C_NC} $1"; }
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
" "$1" "$BOT_DIR/.env"
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
" "$1" "$2" "$BOT_DIR/.env"
}

mask() {
    local v="$1"
    local len=${#v}
    if [ "$len" -le 8 ]; then
        echo "****"
    else
        echo "${v:0:4}****${v: -4}"
    fi
}

maybe_restart() {
    read -rp "Restart the bot now to apply changes? (y/n): " R
    if [ "$R" == "y" ]; then
        systemctl restart $SERVICE
        ok "Restarted."
    fi
}

status_line() {
    if systemctl is-active --quiet $SERVICE; then
        echo -e "${C_GREEN}${C_BOLD}● RUNNING${C_NC}"
    else
        echo -e "${C_RED}${C_BOLD}● STOPPED${C_NC}"
    fi
}

do_backup() {
    TS=$(date +%Y%m%d_%H%M%S)
    OUT="$BACKUP_DIR/backup_$TS.tar.gz"
    echo -e "${C_CYAN}Creating backup...${C_NC}"
    tar -czf "$OUT" -C "$BOT_DIR" \
        .env config.py database.py main.py requirements.txt vpn_bot.db \
        handlers keyboards middlewares services utils scripts 2>/dev/null || true
    ok "Backup saved: $OUT"
}

do_restore() {
    echo -e "${C_CYAN}Available backups:${C_NC}"
    ls -1t "$BACKUP_DIR" 2>/dev/null | nl
    echo ""
    read -rp "Enter backup number (or full file path): " CHOICE
    if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
        FILE=$(ls -1t "$BACKUP_DIR" | sed -n "${CHOICE}p")
        FILE="$BACKUP_DIR/$FILE"
    else
        FILE="$CHOICE"
    fi
    [ ! -f "$FILE" ] && { err "File not found."; return; }
    warn "This will overwrite the current bot files."
    read -rp "Are you sure? (y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && { echo "Cancelled."; return; }
    systemctl stop $SERVICE
    tar -xzf "$FILE" -C "$BOT_DIR"
    systemctl start $SERVICE
    ok "Restore complete, bot restarted."
}

view_db_stats() {
    DB="$BOT_DIR/vpn_bot.db"
    [ ! -f "$DB" ] && { err "Database not found."; return; }
    echo -e "${C_CYAN}--- Quick database stats ---${C_NC}"
    printf "%-16s: " "Users";            sqlite3 "$DB" "SELECT COUNT(*) FROM wallets;" 2>/dev/null || echo "N/A"
    printf "%-16s: " "Orders";           sqlite3 "$DB" "SELECT COUNT(*) FROM orders;" 2>/dev/null || echo "N/A"
    printf "%-16s: " "Total revenue";    sqlite3 "$DB" "SELECT COALESCE(SUM(amount_paid),0) FROM orders;" 2>/dev/null || echo "N/A"
    printf "%-16s: " "Pending payments"; sqlite3 "$DB" "SELECT COUNT(*) FROM pending_payments WHERE status='pending';" 2>/dev/null || echo "N/A"
}

reinstall_deps() {
    cd "$BOT_DIR"
    echo -e "${C_CYAN}Updating Python packages...${C_NC}"
    .venv/bin/python3 -m pip install --upgrade pip -q
    .venv/bin/python3 -m pip install -r requirements.txt -q --upgrade
    ok "Packages updated."
    read -rp "Restart the bot now? (y/n): " R
    [ "$R" == "y" ] && systemctl restart $SERVICE
}

health_check() {
    echo -e "${C_CYAN}Running health checks...${C_NC}"
    echo ""
    printf "%-30s" "Bot service:"
    systemctl is-active --quiet $SERVICE && echo -e "${C_GREEN}running${C_NC}" || echo -e "${C_RED}not running${C_NC}"

    printf "%-30s" ".env file:"
    [ -f "$BOT_DIR/.env" ] && echo -e "${C_GREEN}found${C_NC}" || echo -e "${C_RED}missing${C_NC}"

    [ -f "$BOT_DIR/.env" ] && { set -a; source "$BOT_DIR/.env"; set +a; }

    printf "%-30s" "Telegram bot token:"
    if [ -n "$BOT_TOKEN" ]; then
        TG=$(curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null)
        if echo "$TG" | grep -q '"ok":true'; then
            U=$(echo "$TG" | grep -oP '"username":"\K[^"]+')
            echo -e "${C_GREEN}valid (@${U})${C_NC}"
        else
            echo -e "${C_RED}invalid or unreachable${C_NC}"
        fi
    else
        echo -e "${C_YELLOW}not set${C_NC}"
    fi

    printf "%-30s" "SOCKS5 proxy:"
    if [ -n "$PROXY_HOST" ] && [ -n "$PROXY_PORT" ]; then
        if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$PROXY_HOST/$PROXY_PORT" 2>/dev/null; then
            echo -e "${C_GREEN}reachable (${PROXY_HOST}:${PROXY_PORT})${C_NC}"
        else
            echo -e "${C_RED}cannot connect${C_NC}"
        fi
    else
        echo -e "${C_DIM}disabled (direct connection)${C_NC}"
    fi

    printf "%-30s" "3X-UI panel:"
    if [ -n "$PANEL_URL" ]; then
        CODE=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "${PANEL_URL}${PANEL_PATH}/login" 2>/dev/null)
        [ -n "$CODE" ] && [ "$CODE" != "000" ] && echo -e "${C_GREEN}reachable (HTTP $CODE)${C_NC}" || echo -e "${C_RED}unreachable${C_NC}"
    else
        echo -e "${C_YELLOW}not set${C_NC}"
    fi

    printf "%-30s" "Panel API token:"
    if [ -n "$PANEL_URL" ] && [ -n "$PANEL_API_TOKEN" ]; then
        RES=$(curl -sk --max-time 10 -H "Authorization: Bearer ${PANEL_API_TOKEN}" "${PANEL_URL}${PANEL_PATH}/panel/api/clients/list" 2>/dev/null)
        echo "$RES" | grep -q '"success":true' && echo -e "${C_GREEN}valid${C_NC}" || echo -e "${C_RED}invalid or unreachable${C_NC}"
    else
        echo -e "${C_YELLOW}not set${C_NC}"
    fi

    printf "%-30s" "Database file:"
    if [ -f "$BOT_DIR/vpn_bot.db" ]; then
        SZ=$(du -h "$BOT_DIR/vpn_bot.db" 2>/dev/null | cut -f1)
        echo -e "${C_GREEN}found (${SZ})${C_NC}"
    else
        echo -e "${C_YELLOW}not found yet${C_NC}"
    fi

    printf "%-30s" "Disk space:"
    echo -e "${C_CYAN}$(df -h "$BOT_DIR" 2>/dev/null | awk 'NR==2 {print $4}') free${C_NC}"
    echo ""
}

uninstall_bot() {
    warn "This removes the systemd service and the vpn-bot command."
    echo "Bot files in $BOT_DIR will NOT be deleted."
    read -rp "Are you sure? (y/n): " CONFIRM
    if [ "$CONFIRM" == "y" ]; then
        systemctl stop $SERVICE 2>/dev/null || true
        systemctl disable $SERVICE 2>/dev/null || true
        rm -f /etc/systemd/system/${SERVICE}.service
        systemctl daemon-reload
        rm -f /usr/local/bin/vpn-bot
        echo "Removed. Bot files remain in $BOT_DIR."
    fi
}

settings_bot() {
    clear
    echo -e "${C_CYAN}--- Bot & Admins ---${C_NC}"
    echo "Token: $(mask "$(env_get BOT_TOKEN)")"
    echo "Admin IDs: $(env_get ADMIN_IDS)"
    echo ""
    echo "1) Change bot token"
    echo "2) Change admin IDs"
    echo "0) Back"
    read -rp "Choose: " C
    case $C in
        1) read -rp "New bot token: " V; env_set BOT_TOKEN "$V"; maybe_restart ;;
        2) read -rp "New admin IDs (comma-separated): " V; env_set ADMIN_IDS "$V"; maybe_restart ;;
    esac
}

settings_channel() {
    clear
    echo -e "${C_CYAN}--- Mandatory Channel ---${C_NC}"
    echo "Channel ID: $(env_get REQUIRED_CHANNEL_ID)"
    echo "Invite link: $(env_get REQUIRED_CHANNEL_INVITE)"
    echo ""
    echo "1) Enable / change channel ID"
    echo "2) Change invite link"
    echo "3) Disable mandatory channel"
    echo "0) Back"
    read -rp "Choose: " C
    case $C in
        1) read -rp "Channel numeric ID: " V; env_set REQUIRED_CHANNEL_ID "$V"; maybe_restart ;;
        2) read -rp "New invite link: " V; env_set REQUIRED_CHANNEL_INVITE "$V"; maybe_restart ;;
        3) env_set REQUIRED_CHANNEL_ID "0"; env_set REQUIRED_CHANNEL_INVITE ""; ok "Disabled."; maybe_restart ;;
    esac
}

settings_panel() {
    clear
    echo -e "${C_CYAN}--- Panel (3X-UI) ---${C_NC}"
    echo "URL: $(env_get PANEL_URL)"
    echo "Path: $(env_get PANEL_PATH)"
    echo "API token: $(mask "$(env_get PANEL_API_TOKEN)")"
    echo "Subscription URL: $(env_get SUB_BASE_URL)"
    echo ""
    echo "1) Change panel URL"
    echo "2) Change panel path"
    echo "3) Change API token"
    echo "4) Change subscription URL"
    echo "0) Back"
    read -rp "Choose: " C
    case $C in
        1) read -rp "New panel URL (no trailing slash): " V; env_set PANEL_URL "${V%/}"; maybe_restart ;;
        2) read -rp "New panel path (no trailing slash): " V; env_set PANEL_PATH "${V%/}"; maybe_restart ;;
        3) read -rp "New API token: " V; env_set PANEL_API_TOKEN "$V"; maybe_restart ;;
        4) read -rp "New subscription URL (no trailing slash): " V; env_set SUB_BASE_URL "${V%/}"; maybe_restart ;;
    esac
}

settings_inbounds() {
    clear
    echo -e "${C_CYAN}--- Inbounds ---${C_NC}"
    echo "Format: id:remark:flow (flow empty for non-Reality inbounds)"
    echo ""
    CURRENT=$(env_get INBOUNDS)
    IFS=',' read -ra ARR <<< "$CURRENT"
    i=1
    for e in "${ARR[@]}"; do
        [ -n "$e" ] && echo "$i) $e"
        i=$((i+1))
    done
    echo ""
    echo "1) Fetch inbound list from panel and rebuild selection"
    echo "2) Add one inbound manually"
    echo "3) Remove an inbound by number"
    echo "4) Clear all (fallback to single INBOUND_ID)"
    echo "0) Back"
    read -rp "Choose: " C

    case $C in
        1)
            P_URL=$(env_get PANEL_URL)
            P_PATH=$(env_get PANEL_PATH)
            P_TOKEN=$(env_get PANEL_API_TOKEN)
            echo "Fetching inbounds..."
            JSON=$(curl -sk --max-time 15 -H "Authorization: Bearer ${P_TOKEN}" "${P_URL}${P_PATH}/panel/api/inbounds/list" 2>/dev/null)
            if ! echo "$JSON" | grep -q '"success":true'; then
                err "Could not fetch inbounds from the panel."
                return
            fi
            
            python3 "$BOT_DIR/scripts/parse_panel.py" --action list --json "$JSON"
            echo ""
            read -rp "Enter the inbound ID(s) to include, comma-separated (use the number after id=): " PICKS

            HAS_REALITY=$(python3 - "$JSON" "$PICKS" << 'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
picks = [p.strip() for p in sys.argv[2].split(",") if p.strip()]
obj = data.get("obj", [])
for inb in obj:
    if str(inb.get("id")) in picks:
        ss_raw = inb.get("streamSettings", {})
        if isinstance(ss_raw, str):
            try: ss = json.loads(ss_raw)
            except Exception: ss = {}
        else: ss = ss_raw or {}
        if ss.get("security") == "reality":
            print("y")
            sys.exit(0)
print("n")
PYEOF
)
            FLOW=""
            if [ "$HAS_REALITY" == "y" ]; then
                echo ""
                read -rp "One or more selected inbounds are Reality. Enable Vision flow for them? (y/n): " ISV
                [ "$ISV" == "y" ] && FLOW="xtls-rprx-vision"
            fi
            NEW_INBOUNDS=""
            IFS=',' read -ra PICK_ARR <<< "$PICKS"
            for idx in "${PICK_ARR[@]}"; do
                idx="$(echo -n "$idx" | xargs)"
                [ -z "$idx" ] && continue
                LINE=$(python3 "$BOT_DIR/scripts/parse_panel.py" --action validate --json "$JSON" --id "$idx")
                [ "$LINE" == "INVALID" ] && { warn "Invalid: $idx"; continue; }
                IB_ID=$(echo "$LINE" | cut -d'|' -f1)
                IB_REMARK=$(echo "$LINE" | cut -d'|' -f2)
                IB_IS_REALITY=$(echo "$LINE" | cut -d'|' -f3)
                if [ "$IB_IS_REALITY" == "y" ]; then
                    ENTRY_FLOW="$FLOW"
                else
                    ENTRY_FLOW=""
                fi
                ENTRY="${IB_ID}:${IB_REMARK}:${ENTRY_FLOW}"
                [ -z "$NEW_INBOUNDS" ] && NEW_INBOUNDS="$ENTRY" || NEW_INBOUNDS="${NEW_INBOUNDS},${ENTRY}"
            done
            if [ -n "$NEW_INBOUNDS" ]; then
                env_set INBOUNDS "$NEW_INBOUNDS"
                env_set INBOUND_ID "${NEW_INBOUNDS%%:*}"
                ok "Inbounds updated."
                maybe_restart
            fi
            ;;
        2)
            read -rp "Inbound ID: " IB_ID
            read -rp "Display name (remark): " IB_REMARK
            read -rp "Enable Vision flow? (y/n): " ISV
            FLOW=""
            [ "$ISV" == "y" ] && FLOW="xtls-rprx-vision"
            ENTRY="${IB_ID}:${IB_REMARK}:${FLOW}"
            CURRENT=$(env_get INBOUNDS)
            if [ -z "$CURRENT" ]; then NEW="$ENTRY"
            else NEW="${CURRENT},${ENTRY}"
            fi
            env_set INBOUNDS "$NEW"
            env_set INBOUND_ID "${NEW%%:*}"
            ok "Added."
            maybe_restart
            ;;
        3)
            read -rp "Enter the number to remove: " N
            CURRENT=$(env_get INBOUNDS)
            IFS=',' read -ra ARR <<< "$CURRENT"
            NEW=""
            i=1
            for e in "${ARR[@]}"; do
                if [ "$i" != "$N" ]; then
                    [ -z "$NEW" ] && NEW="$e" || NEW="${NEW},${e}"
                fi
                i=$((i+1))
            done
            env_set INBOUNDS "$NEW"
            [ -n "$NEW" ] && env_set INBOUND_ID "${NEW%%:*}"
            ok "Removed."
            maybe_restart
            ;;
        4)
            read -rp "Fallback single Inbound ID: " V
            read -rp "Enable Vision flow? (y/n): " ISV
            FLOW=""
            [ "$ISV" == "y" ] && FLOW="xtls-rprx-vision"
            env_set INBOUNDS "${V}:default:${FLOW}"
            env_set INBOUND_ID "$V"
            ok "Cleared."
            maybe_restart
            ;;
    esac
}

settings_proxy() {
    clear
    echo -e "${C_CYAN}--- SOCKS5 Proxy ---${C_NC}"
    echo "Host: $(env_get PROXY_HOST)"
    echo "Port: $(env_get PROXY_PORT)"
    echo ""
    echo "1) Enable / change proxy"
    echo "2) Disable proxy"
    echo "0) Back"
    read -rp "Choose: " C
    case $C in
        1) read -rp "Proxy host: " H; read -rp "Proxy port: " P; env_set PROXY_HOST "$H"; env_set PROXY_PORT "$P"; maybe_restart ;;
        2) env_set PROXY_HOST ""; env_set PROXY_PORT ""; ok "Disabled."; maybe_restart ;;
    esac
}

settings_log() {
    clear
    echo -e "${C_CYAN}--- Log Channel ---${C_NC}"
    echo "Channel ID: $(env_get LOG_CHANNEL_ID)"
    echo ""
    echo "1) Enable / change log channel"
    echo "2) Disable log channel"
    echo "0) Back"
    read -rp "Choose: " C
    case $C in
        1) read -rp "Log channel numeric ID: " V; env_set LOG_CHANNEL_ID "$V"; maybe_restart ;;
        2) env_set LOG_CHANNEL_ID "0"; ok "Disabled."; maybe_restart ;;
    esac
}

settings_reminder() {
    clear
    echo -e "${C_CYAN}--- Expiry Reminder ---${C_NC}"
    echo "Enabled: $(env_get REMINDER_ENABLED)"
    echo "GB threshold: $(env_get REMINDER_GB_THRESHOLD)"
    echo "Days threshold: $(env_get REMINDER_DAYS_THRESHOLD)"
    echo ""
    echo "1) Enable"
    echo "2) Disable"
    echo "3) Change GB threshold"
    echo "4) Change days threshold"
    echo "0) Back"
    read -rp "Choose: " C
    case $C in
        1) env_set REMINDER_ENABLED "y"; ok "Enabled."; maybe_restart ;;
        2) env_set REMINDER_ENABLED "n"; ok "Disabled."; maybe_restart ;;
        3) read -rp "New GB threshold: " V; env_set REMINDER_GB_THRESHOLD "$V"; maybe_restart ;;
        4) read -rp "New days threshold: " V; env_set REMINDER_DAYS_THRESHOLD "$V"; maybe_restart ;;
    esac
}

settings_cards() {
    clear
    echo -e "${C_CYAN}--- Payment Cards ---${C_NC}"
    CURRENT=$(env_get CARDS)
    IFS=',' read -ra ARR <<< "$CURRENT"
    i=1
    for e in "${ARR[@]}"; do
        [ -n "$e" ] && echo "$i) $e"
        i=$((i+1))
    done
    echo ""
    echo "1) Add a card"
    echo "2) Remove a card by number"
    echo "3) Replace all cards"
    echo "0) Back"
    read -rp "Choose: " C
    case $C in
        1)
            read -rp "Card number: " NUM
            read -rp "Cardholder name: " NAME
            [ -z "$CURRENT" ] && NEW="${NUM}:${NAME}" || NEW="${CURRENT},${NUM}:${NAME}"
            env_set CARDS "$NEW"
            ok "Added."
            maybe_restart
            ;;
        2)
            read -rp "Number to remove: " N
            NEW=""
            i=1
            for e in "${ARR[@]}"; do
                if [ "$i" != "$N" ]; then
                    [ -z "$NEW" ] && NEW="$e" || NEW="${NEW},${e}"
                fi
                i=$((i+1))
            done
            env_set CARDS "$NEW"
            ok "Removed."
            maybe_restart
            ;;
        3)
            read -rp "How many cards: " CNT
            NEW=""
            for ((k=1; k<=CNT; k++)); do
                read -rp "Card number: " NUM
                read -rp "Cardholder name: " NAME
                [ -z "$NEW" ] && NEW="${NUM}:${NAME}" || NEW="${NEW},${NUM}:${NAME}"
            done
            env_set CARDS "$NEW"
            ok "Cards replaced."
            maybe_restart
            ;;
    esac
}

edit_env() {
    while true; do
        clear
        echo -e "${C_CYAN}${C_BOLD}--- Edit Settings ---${C_NC}"
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
        case $C in
            1) settings_bot; pause ;;
            2) settings_channel; pause ;;
            3) settings_panel; pause ;;
            4) settings_inbounds; pause ;;
            5) settings_proxy; pause ;;
            6) settings_log; pause ;;
            7) settings_reminder; pause ;;
            8) settings_cards; pause ;;
            9)
                EDITOR_BIN="${EDITOR:-nano}"
                command -v "$EDITOR_BIN" &> /dev/null || EDITOR_BIN="vi"
                "$EDITOR_BIN" "$BOT_DIR/.env"
                maybe_restart
                ;;
            0) break ;;
        esac
    done
}

show_menu() {
    clear
    echo -e "${C_BLUE}${C_BOLD}╔══════════════════════════════════════════════════╗${C_NC}"
    echo -e "${C_BLUE}${C_BOLD}║          🤖  VPN Sales Bot — Control Panel         ║${C_NC}"
    echo -e "${C_BLUE}${C_BOLD}╚══════════════════════════════════════════════════╝${C_NC}"
    echo -e "  Service status: $(status_line)"
    echo -e "${C_DIM}──────────────────────────────────────────────────────${C_NC}"
    echo -e "  ${C_GREEN}1)${C_NC}  🟢 Start bot"
    echo -e "  ${C_GREEN}2)${C_NC}  🔴 Stop bot"
    echo -e "  ${C_GREEN}3)${C_NC}  🔄 Restart bot"
    echo -e "  ${C_GREEN}4)${C_NC}  📊 Service status"
    echo -e "  ${C_GREEN}5)${C_NC}  📜 Live logs (Ctrl+C to exit)"
    echo -e "  ${C_GREEN}6)${C_NC}  📄 Last 100 log lines"
    echo -e "  ${C_GREEN}7)${C_NC}  ⚙️  Edit settings"
    echo -e "  ${C_GREEN}8)${C_NC}  💾 Create backup"
    echo -e "  ${C_GREEN}9)${C_NC}  ♻️  Restore from backup"
    echo -e "  ${C_GREEN}10)${C_NC} 📈 Quick database stats"
    echo -e "  ${C_GREEN}11)${C_NC} 📦 Update Python packages"
    echo -e "  ${C_GREEN}12)${C_NC} 🩺 Health check"
    echo -e "  ${C_GREEN}13)${C_NC} 🗑  Uninstall CLI & service"
    echo -e "  ${C_RED}0)${C_NC}  Exit"
    echo -e "${C_DIM}──────────────────────────────────────────────────────${C_NC}"
}

if [ -n "$1" ]; then
    case "$1" in
        start) systemctl start $SERVICE; ok "Started." ;;
        stop) systemctl stop $SERVICE; warn "Stopped." ;;
        restart) systemctl restart $SERVICE; ok "Restarted." ;;
        status) systemctl status $SERVICE ;;
        logs) journalctl -u $SERVICE -f ;;
        backup) do_backup ;;
        restore) do_restore ;;
        health) health_check ;;
        *) err "Unknown command: $1" ;;
    esac
    exit 0
fi

while true; do
    show_menu
    read -rp "Choose an option: " CHOICE
    case $CHOICE in
        1) systemctl start $SERVICE; ok "Started."; pause ;;
        2) systemctl stop $SERVICE; warn "Stopped."; pause ;;
        3) systemctl restart $SERVICE; ok "Restarted."; pause ;;
        4) systemctl status $SERVICE --no-pager; pause ;;
        5) journalctl -u $SERVICE -f ;;
        6) journalctl -u $SERVICE -n 100 --no-pager; pause ;;
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