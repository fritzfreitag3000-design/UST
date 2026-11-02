#!/usr/bin/env bash
# Epic 5: Hintergrund-Monitor (Zeitplan + Auto-Recovery). Verwendung: monitor.sh [run|start|stop|status]

LOG_TAG=monitor
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
source "$MANAGER_DIR/recover.sh"

PID_FILE="$MANAGER_DIR/monitor.pid"
fails=0
rollbacks=0
healthy_streak=0
last_slot=""

# Task 5.2: Auslösezeit = Restart-Zeit minus Warnzeit.
schedule_due() {
    local line trigger now
    now="$(date +%H:%M)"
    [[ -r $SCHEDULE_CFG ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ $line =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || continue
        trigger="$(date -d "$line ${SHUTDOWN_WARN_MINUTES} minutes ago" +%H:%M)"
        [[ $trigger == "$now" ]] && return 0
    done < "$SCHEDULE_CFG"
    return 1
}

has_corruption() {
    local rpt
    rpt="$(latest_rpt)"
    [[ -n $rpt ]] && grep -qE "$CORRUPT_PATTERN" "$rpt"
}

# Task 5.3: Stufe 1, bei Fehlschlag Stufe 2.
recover_unresponsive() {
    soft_restart || hard_reboot
}

recover_crash() {
    if ports_busy || tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        hard_reboot
    else
        set_state STOPPED
        "$MANAGER_DIR/start.sh" || hard_reboot
    fi
}

# Task 5.4
handle_corruption() {
    healthy_streak=0
    if (( rollbacks >= MAX_ROLLBACKS )); then
        log "Datenbankfehler nach $rollbacks Rollbacks weiterhin vorhanden - Wartungssperre gesetzt."
        touch "$LOCK_FILE"
        notify "Wartungssperre gesetzt: Datenbankfehler besteht nach $rollbacks Rollbacks weiter."
        return
    fi
    rollbacks=$((rollbacks + 1))
    log "Datenbankfehler im RPT-Log erkannt (Rollback $rollbacks/$MAX_ROLLBACKS)."
    rollback
}

check_once() {
    local slot

    [[ -e $LOCK_FILE ]] && return
    operation_running && return

    case "$(server_state)" in
        ONLINE) ;;
        OFFLINE)
            if [[ "$(get_state)" == ONLINE ]]; then
                log "Serverprozess fehlt (Crash)."
                notify "Serverprozess fehlt (Crash) - Recovery läuft."
                recover_crash
            fi
            return ;;
        *) return ;;
    esac

    if has_corruption; then
        handle_corruption
        return
    fi

    slot="$(date +%F_%H:%M)"
    if [[ $slot != "$last_slot" ]] && schedule_due; then
        last_slot="$slot"
        log "Geplanter Neustart."
        "$MANAGER_DIR/stop.sh" "$SHUTDOWN_WARN_MINUTES" && "$MANAGER_DIR/start.sh"
        return
    fi

    if rcon players >/dev/null 2>&1; then
        fails=0
        healthy_streak=$((healthy_streak + 1))
        (( healthy_streak >= 30 )) && rollbacks=0
    else
        healthy_streak=0
        fails=$((fails + 1))
        log "RCON antwortet nicht ($fails/$RCON_FAIL_LIMIT)."
        if (( fails >= RCON_FAIL_LIMIT )); then
            fails=0
            recover_unresponsive
        fi
    fi
}

run_loop() {
    local other
    other="$(monitor_pid)"
    if [[ -n $other && $other != "$$" ]]; then
        log "Monitor läuft bereits (PID $other)."
        exit 0
    fi
    echo $$ > "$PID_FILE"
    trap 'rm -f "$PID_FILE"' EXIT
    trap 'exit 0' INT TERM
    log "Monitor gestartet (PID $$)."
    while true; do
        check_once
        sleep $((60 - 10#$(date +%S)))
    done
}

monitor_pid() {
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

case "${1:-status}" in
    run) run_loop ;;
    start)
        if monitor_pid >/dev/null; then
            echo "Monitor läuft bereits (PID $(monitor_pid))."
        else
            mkdir -p "$LOG_DIR"
            setsid nohup "$0" run >>"$LOG_DIR/ao.log" 2>&1 9>&- &
            echo "Monitor gestartet (PID $!)."
        fi ;;
    stop)
        if pid="$(monitor_pid)"; then
            kill "$pid" && rm -f "$PID_FILE"
            echo "Monitor gestoppt."
        else
            echo "Monitor läuft nicht."
        fi ;;
    status)
        if pid="$(monitor_pid)"; then echo "Monitor läuft (PID $pid)."; else echo "Monitor läuft nicht."; exit 1; fi ;;
    *) echo "Verwendung: $0 [run|start|stop|status]" >&2; exit 1 ;;
esac
