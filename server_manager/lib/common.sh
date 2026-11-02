#!/usr/bin/env bash
# Gemeinsame Pfade, Konfiguration und Hilfsfunktionen des AO-Server Tools.

MANAGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="$(dirname "$MANAGER_DIR")"

STEAMCMD_DIR="$BASE_DIR/steamcmd"
SERVER_DIR="$BASE_DIR/server_data"
BACKUP_DIR="$BASE_DIR/backups"
LOG_DIR="$MANAGER_DIR/logs"
PROFILES_DIR="$SERVER_DIR/profiles"
KEYS_DIR="$SERVER_DIR/keys"
MODS_CFG="$MANAGER_DIR/mods.cfg"
SCHEDULE_CFG="$MANAGER_DIR/schedule.cfg"
STATE_FILE="$MANAGER_DIR/state"
LOCK_FILE="$MANAGER_DIR/maintenance.lock"
OP_LOCK_FILE="$MANAGER_DIR/.lock"

# shellcheck source=../server.cfg
source "$MANAGER_DIR/server.cfg"

log() {
    mkdir -p "$LOG_DIR"
    printf '%s [%s] %s\n' "$(date '+%F %T')" "${LOG_TAG:-ao}" "$*" | tee -a "$LOG_DIR/ao.log" >&2
}

# Zustand, den start.sh/stop.sh setzen: STARTING, ONLINE, STOPPING, STOPPED.
set_state() { echo "$1" > "$STATE_FILE"; }
get_state() { cat "$STATE_FILE" 2>/dev/null || echo STOPPED; }

server_pid() { pgrep -u "$(id -u)" -x "$PROCESS_NAME" | head -n1; }
latest_rpt() { ls -1t "$PROFILES_DIR"/*.RPT 2>/dev/null | head -n1; }

# Ausgabe: OFFLINE, STARTING, INIT_HIVE, ONLINE oder STOPPING.
server_state() {
    local state rpt
    state="$(get_state)"
    if [[ -z "$(server_pid)" ]]; then
        if [[ $state == STARTING ]] && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            echo STARTING
        else
            echo OFFLINE
        fi
        return
    fi
    case "$state" in
        STARTING)
            rpt="$(latest_rpt)"
            if [[ -n $rpt && $rpt -nt $STATE_FILE ]]; then echo INIT_HIVE; else echo STARTING; fi ;;
        STOPPING) echo STOPPING ;;
        *) echo ONLINE ;;
    esac
}

port_in_use() { ss -H -lntu sport = ":$1" 2>/dev/null | grep -q .; }

ports_busy() {
    local p busy=1
    for p in "$GAME_PORT" "$QUERY_PORT" "$RCON_PORT"; do
        port_in_use "$p" && busy=0
    done
    return "$busy"
}

wait_ports_free() {
    local deadline=$((SECONDS + $1))
    while (( SECONDS < deadline )); do
        ports_busy || return 0
        sleep 1
    done
    return 1
}

# Sudoers-Regeln dafür legt setup/install.sh an.
firewall_block() { sudo -n iptables -I INPUT -p udp --dport "$GAME_PORT" -j DROP; }
firewall_unblock() {
    while sudo -n iptables -D INPUT -p udp --dport "$GAME_PORT" -j DROP 2>/dev/null; do :; done
    return 0
}

rcon() {
    timeout "$RCON_TIMEOUT" "$RCON_BIN" -i 127.0.0.1 -p "$RCON_PORT" -P "$RCON_PASSWORD" "$@"
}

hard_kill() {
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    pkill -9 -u "$(id -u)" -x "$PROCESS_NAME" 2>/dev/null || true
    pkill -9 -u "$(id -u)" -x "$(basename "$RCON_BIN")" 2>/dev/null || true
    return 0
}

create_backup() {
    local file
    if [[ ! -d $STORAGE_DIR ]]; then
        log "Backup nicht möglich: $STORAGE_DIR existiert nicht."
        return 1
    fi
    mkdir -p "$BACKUP_DIR"
    file="$BACKUP_DIR/storage_1_$(date +%Y%m%d_%H%M%S).tar.gz"
    if tar -czf "$file" -C "$(dirname "$STORAGE_DIR")" "$(basename "$STORAGE_DIR")"; then
        log "Backup erstellt: $file"
    else
        rm -f "$file"
        log "Backup fehlgeschlagen."
        return 1
    fi
}

latest_backup() { ls -1t "$BACKUP_DIR"/storage_1_*.tar.gz 2>/dev/null | head -n1; }

# Verhindert parallele Start-/Stopp-Vorgänge. Fd 9 beim Start von Hintergrundprozessen mit 9>&- schließen.
acquire_lock() {
    exec 9>"$OP_LOCK_FILE"
    if ! flock -n 9; then
        log "Ein anderer Start-/Stopp-Vorgang läuft bereits."
        exit 1
    fi
}

operation_running() { ! ( flock -n 8 ) 8>"$OP_LOCK_FILE"; }
