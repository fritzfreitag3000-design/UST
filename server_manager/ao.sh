#!/usr/bin/env bash
# Hauptdatei: CLI-Dashboard (ohne Argumente) und Kommandozeilen-Steuerung (mit Argumenten).

LOG_TAG=ao
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
source "$MANAGER_DIR/mods.sh"
source "$MANAGER_DIR/recover.sh"

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

monitor_text() { "$MANAGER_DIR/monitor.sh" status 2>&1; }
monitor_running() { "$MANAGER_DIR/monitor.sh" status >/dev/null 2>&1; }

# Füllt STATE, PLAYERS, MAX, PING, VERSION per Steam-Query.
collect_status() {
    local key value
    PLAYERS="-"; MAX="-"; PING="-"; VERSION="-"
    STATE="$(server_state)"
    [[ $STATE == OFFLINE ]] && return 0
    while IFS='=' read -r key value; do
        case "$key" in
            players) PLAYERS="$value" ;;
            max_players) MAX="$value" ;;
            ping_ms) PING="$value" ;;
            version) VERSION="$value" ;;
        esac
    done < <(python3 "$MANAGER_DIR/query.py" 127.0.0.1 "$QUERY_PORT" 2 2>/dev/null)
    return 0
}

print_status() {
    collect_status
    printf '  Status:   %s\n' "$(state_label "$STATE")"
    printf '  Spieler:  %s / %s\n' "$PLAYERS" "$MAX"
    printf '  Ping:     %s ms\n' "$PING"
    printf '  Version:  %s\n' "$VERSION"
    printf '  Monitor:  %s\n' "$(monitor_text)"
}

status_json() {
    local mon=false
    collect_status
    monitor_running && mon=true
    python3 - "$STATE" "$PLAYERS" "$MAX" "$PING" "$VERSION" "$mon" <<'EOF'
import json
import sys

state, players, max_players, ping, version, monitor = sys.argv[1:7]


def num(value):
    return int(value) if value.isdigit() else None


print(json.dumps({
    "state": state,
    "players": num(players),
    "max_players": num(max_players),
    "ping_ms": num(ping),
    "version": None if version == "-" else version,
    "monitor": monitor == "true",
}))
EOF
}

require_offline() {
    if [[ "$(server_state)" != OFFLINE ]]; then
        echo "Nur bei gestopptem Server möglich." >&2
        return 1
    fi
}

offline_only() { require_offline && "$@"; }

show_logs() {
    local rpt
    echo "--- ao.log (letzte 20 Zeilen)"
    tail -n 20 "$LOG_DIR/ao.log" 2>/dev/null
    rpt="$(latest_rpt)"
    if [[ -n $rpt ]]; then
        echo "--- $(basename "$rpt") (letzte 20 Zeilen)"
        tail -n 20 "$rpt"
    fi
}

toggle_monitor() {
    if monitor_running; then
        "$MANAGER_DIR/monitor.sh" stop
    else
        "$MANAGER_DIR/monitor.sh" start
    fi
}

restore_menu() {
    local files choice answer i
    require_offline || return 1
    mapfile -t files < <(ls -1t "$BACKUP_DIR"/storage_1_*.tar.gz 2>/dev/null)
    if (( ${#files[@]} == 0 )); then
        echo "Keine Backups vorhanden."
        return 1
    fi
    for i in "${!files[@]}"; do
        printf '  %d) %s\n' $((i + 1)) "$(basename "${files[$i]}")"
    done
    read -r -p "Backup wählen (Enter = Abbruch): " choice
    if ! [[ $choice =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#files[@]} )); then
        echo "Abgebrochen."
        return 1
    fi
    read -r -p "storage_1 durch dieses Backup ersetzen? (ja/nein): " answer
    [[ $answer == ja ]] || { echo "Abgebrochen."; return 1; }
    restore_backup "${files[$((choice - 1))]}"
}

render() {
    clear
    cat "$MANAGER_DIR/logo.txt"
    echo
    print_status
    echo
    echo "  1) Server starten"
    echo "  2) Server stoppen"
    echo "  3) Mods aktualisieren"
    echo "  4) DayZ-Server aktualisieren"
    echo "  5) Backup erstellen"
    echo "  6) Backup wiederherstellen"
    echo "  7) Logs anzeigen"
    echo "  8) Monitor starten/stoppen"
    echo "  0) Beenden"
    echo
}

run_action() {
    "$@"
    read -r -p "Weiter mit Enter ..." _
}

usage() {
    cat >&2 <<EOF
Verwendung: $0 [Befehl]
  (ohne Befehl)        interaktives Dashboard
  start                Server starten
  stop [Minuten]       Server stoppen (Warnzeit optional)
  status [--json]      Status anzeigen
  backup               Backup erstellen
  restore [Archiv]     Backup einspielen (Standard: neuestes)
  update               Mods synchronisieren
  update-server        DayZ-Server aktualisieren
  logs                 letzte Logzeilen anzeigen
  monitor [start|stop|status]
EOF
}

run_cli() {
    local cmd="$1"
    shift
    case "$cmd" in
        start) exec "$MANAGER_DIR/start.sh" ;;
        stop) exec "$MANAGER_DIR/stop.sh" "$@" ;;
        status) if [[ ${1:-} == --json ]]; then status_json; else print_status; fi ;;
        backup) offline_only create_backup ;;
        restore) offline_only restore_backup "${1:-$(latest_backup)}" ;;
        update) offline_only sync_mods ;;
        update-server) offline_only update_server ;;
        logs) show_logs ;;
        monitor) "$MANAGER_DIR/monitor.sh" "${1:-status}" ;;
        -h|--help|help) usage ;;
        *) usage; exit 1 ;;
    esac
}

if (( $# > 0 )); then
    run_cli "$@"
    exit $?
fi

while true; do
    render
    if read -r -t "$REFRESH_SECONDS" -p "Auswahl: " choice; then
        case "$choice" in
            1) run_action "$MANAGER_DIR/start.sh" ;;
            2) run_action "$MANAGER_DIR/stop.sh" ;;
            3) run_action offline_only sync_mods ;;
            4) run_action offline_only update_server ;;
            5) run_action offline_only create_backup ;;
            6) run_action restore_menu ;;
            7) run_action show_logs ;;
            8) run_action toggle_monitor ;;
            0) exit 0 ;;
        esac
    elif (( $? <= 128 )); then
        exit 0
    fi
done
