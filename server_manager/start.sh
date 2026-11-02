#!/usr/bin/env bash
# Epic 3: Start-Prozedur (Pre-Flight, Firewall-Sperre, Start, Hive-Monitoring, Timeout).

LOG_TAG=start
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
source "$MANAGER_DIR/mods.sh"

# Task 3.1
preflight() {
    local ok=0 port
    if [[ -e $LOCK_FILE ]]; then
        log "Wartungssperre aktiv ($LOCK_FILE)."
        return 1
    fi
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        log "tmux-Sitzung '$TMUX_SESSION' existiert bereits."
        ok=1
    fi
    if [[ -n "$(server_pid)" ]]; then
        log "$PROCESS_NAME läuft bereits."
        ok=1
    fi
    for port in "$GAME_PORT" "$QUERY_PORT" "$RCON_PORT"; do
        if port_in_use "$port"; then
            log "Port $port ist belegt."
            ok=1
        fi
    done
    return "$ok"
}

# Task 3.3
build_start_command() {
    local mods
    mods="$(mod_param)"
    START_CMD=("./$PROCESS_NAME" "-config=$SERVER_CONFIG" "-port=$GAME_PORT" "-profiles=$PROFILES_DIR"
        "-BEpath=battleye" "-dologs" "-adminlog" "-netlog" "-freezecheck")
    if [[ -n $mods ]]; then
        START_CMD+=("-mod=$mods")
    fi
}

launch() {
    local cmd
    mkdir -p "$PROFILES_DIR"
    set_state STARTING
    cmd="cd $(printf '%q' "$SERVER_DIR") && exec $(printf '%q ' "${START_CMD[@]}")"
    log "Starte: ${START_CMD[*]}"
    tmux new-session -d -s "$TMUX_SESSION" "$cmd" 9>&-
}

# Task 3.4 + 3.5: RPT per tail -F auslesen, Erfolg bei HIVE_PATTERN, Fehlschlag bei Timeout oder Prozessende.
wait_for_hive() {
    local deadline=$((SECONDS + START_TIMEOUT)) rpt="" line rc=1 tail_pid
    while (( SECONDS < deadline )); do
        rpt="$(latest_rpt)"
        [[ -n $rpt && $rpt -nt $STATE_FILE ]] && break
        rpt=""
        sleep 2
    done
    [[ -n $rpt ]] || { log "Keine neue RPT-Datei gefunden."; return 1; }

    exec 8< <(tail -F -n +1 "$rpt" 2>/dev/null)
    tail_pid=$!
    while (( SECONDS < deadline )); do
        if IFS= read -r -t 2 -u 8 line; then
            if [[ $line == *"$HIVE_PATTERN"* ]]; then
                rc=0
                break
            fi
        elif (( $? <= 128 )); then
            break
        fi
        if [[ -z "$(server_pid)" ]]; then
            log "Serverprozess während des Starts beendet."
            break
        fi
    done
    kill "$tail_pid" 2>/dev/null
    exec 8<&-
    return "$rc"
}

START_OK=0
cleanup_on_exit() {
    if (( START_OK == 0 )); then
        firewall_unblock
        [[ -n "$(server_pid)" ]] || set_state STOPPED
    fi
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

acquire_lock

if [[ ! -x $SERVER_DIR/$PROCESS_NAME ]]; then
    log "$SERVER_DIR/$PROCESS_NAME nicht gefunden."
    exit 1
fi

preflight || exit 1
build_start_command

for (( attempt = 1; attempt <= START_RETRIES; attempt++ )); do
    log "Startversuch $attempt/$START_RETRIES"
    if (( attempt > 1 )); then
        hard_kill
        wait_ports_free 30 || log "Ports nach Kill noch belegt."
    fi

    firewall_unblock
    if ! firewall_block; then
        log "Firewall-Sperre fehlgeschlagen (sudo-Regel fehlt?) - Abbruch."
        exit 1
    fi

    launch || { log "tmux-Start fehlgeschlagen."; exit 1; }

    if wait_for_hive; then
        firewall_unblock
        set_state ONLINE
        START_OK=1
        log "Server online (Hive geladen)."
        exit 0
    fi
    log "Hive wurde nicht innerhalb von ${START_TIMEOUT}s initialisiert."
done

hard_kill
log "Start nach $START_RETRIES Versuchen fehlgeschlagen."
exit 1
