#!/usr/bin/env bash
# Epic 4: Stopp-Prozedur mit RCON-Shutdown, Warteschleife, Backup und Fallback-Kill.
# Verwendung: stop.sh [Warnminuten]   (0 = ohne Warnung)

LOG_TAG=stop
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

minutes="${1:-$SHUTDOWN_WARN_MINUTES}"
if [[ ! $minutes =~ ^[0-9]+$ ]]; then
    echo "Verwendung: $0 [Warnminuten]" >&2
    exit 1
fi

# BattlEye kennt kein "alle kicken": Spielernummern aus 'players' lesen und einzeln kicken.
kick_all_players() {
    local list num
    list="$(rcon players)" || return 1
    while read -r num _; do
        [[ $num =~ ^[0-9]+$ ]] && rcon "kick $num" >/dev/null
    done <<< "$list"
    return 0
}

# Task 4.2
graceful_shutdown() {
    if (( minutes > 0 )); then
        rcon "say -1 Server restart in $minutes minutes!" >/dev/null || return 1
        sleep $((minutes * 60))
    fi
    rcon "$RCON_LOCK_CMD" >/dev/null || return 1
    kick_all_players || return 1
    rcon "$RCON_SHUTDOWN_CMD" >/dev/null || return 1
}

# Task 4.3
wait_for_exit() {
    local pid="$1" deadline=$((SECONDS + SHUTDOWN_TIMEOUT))
    while kill -0 "$pid" 2>/dev/null; do
        (( SECONDS >= deadline )) && return 1
        sleep 1
    done
}

acquire_lock

# Task 4.1
case "$(server_state)" in
    OFFLINE)
        log "Server läuft nicht."
        set_state STOPPED
        exit 0 ;;
    STARTING|INIT_HIVE)
        log "Stopp verweigert: Server befindet sich noch im Startvorgang."
        exit 1 ;;
esac

pid="$(server_pid)"
set_state STOPPING

if graceful_shutdown && wait_for_exit "$pid"; then
    log "Server sauber beendet."
else
    # Task 4.5
    log "Shutdown nicht erfolgreich - erzwinge Beenden."
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    kill -9 "$pid" 2>/dev/null || true
    sleep 1
fi
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

# Task 4.4
backup_rc=0
create_backup || backup_rc=1
set_state STOPPED
exit "$backup_rc"
