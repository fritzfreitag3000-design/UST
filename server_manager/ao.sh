#!/usr/bin/env bash
# Hauptdatei: CLI-Dashboard mit Logo, Live-Status und numerischem Menü (Task 5.1).

LOG_TAG=ao
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
source "$MANAGER_DIR/mods.sh"

REFRESH_SECONDS=5

state_label() {
    case "$1" in
        OFFLINE) echo "Offline" ;;
        STARTING) echo "Startet" ;;
        INIT_HIVE) echo "Initialisiert Hive" ;;
        STOPPING) echo "Fährt herunter" ;;
        *) echo "Online" ;;
    esac
}

render() {
    local state players="-" max="-" ping="-" version="-" key value
    state="$(server_state)"
    if [[ $state != OFFLINE ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                players) players="$value" ;;
                max_players) max="$value" ;;
                ping_ms) ping="$value" ;;
                version) version="$value" ;;
            esac
        done < <(python3 "$MANAGER_DIR/query.py" 127.0.0.1 "$QUERY_PORT" 2 2>/dev/null)
    fi

    clear
    cat "$MANAGER_DIR/logo.txt"
    echo
    printf '  Status:   %s\n' "$(state_label "$state")"
    printf '  Spieler:  %s / %s\n' "$players" "$max"
    printf '  Ping:     %s ms\n' "$ping"
    printf '  Version:  %s\n' "$version"
    printf '  Monitor:  %s\n' "$("$MANAGER_DIR/monitor.sh" status 2>&1)"
    echo
    echo "  1) Server starten"
    echo "  2) Server stoppen"
    echo "  3) Mods aktualisieren"
    echo "  4) Backup erstellen"
    echo "  5) Monitor starten/stoppen"
    echo "  0) Beenden"
    echo
}

run_action() {
    "$@"
    read -r -p "Weiter mit Enter ..." _
}

require_offline() {
    if [[ "$(server_state)" != OFFLINE ]]; then
        echo "Nur bei gestopptem Server möglich."
        return 1
    fi
}

toggle_monitor() {
    if "$MANAGER_DIR/monitor.sh" status >/dev/null 2>&1; then
        "$MANAGER_DIR/monitor.sh" stop
    else
        "$MANAGER_DIR/monitor.sh" start
    fi
}

while true; do
    render
    if read -r -t "$REFRESH_SECONDS" -p "Auswahl: " choice; then
        case "$choice" in
            1) run_action "$MANAGER_DIR/start.sh" ;;
            2) run_action "$MANAGER_DIR/stop.sh" ;;
            3) require_offline && run_action sync_mods || read -r -p "Weiter mit Enter ..." _ ;;
            4) require_offline && run_action create_backup || read -r -p "Weiter mit Enter ..." _ ;;
            5) run_action toggle_monitor ;;
            0) exit 0 ;;
        esac
    elif (( $? <= 128 )); then
        exit 0
    fi
done
