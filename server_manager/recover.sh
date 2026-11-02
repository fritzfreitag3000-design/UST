#!/usr/bin/env bash
# Epic 5: Auto-Recovery Stufen 1-3. Als Skript: recover.sh [soft|hard|rollback]; als Bibliothek: source.

LOG_TAG="${LOG_TAG:-recover}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Stufe 1: reguläre Stopp- und Start-Prozedur ohne Warnzeit.
soft_restart() {
    log "Recovery Stufe 1: Soft-Restart."
    "$MANAGER_DIR/stop.sh" 0 || return 1
    "$MANAGER_DIR/start.sh"
}

# Stufe 2: alle Server-Prozesse hart beenden, Ports freigeben, neu starten.
hard_reboot() {
    log "Recovery Stufe 2: Hard-Reboot."
    hard_kill
    firewall_unblock
    wait_ports_free 30 || log "Ports hängen weiterhin (Zombie)."
    set_state STOPPED
    "$MANAGER_DIR/start.sh"
}

# Stufe 3: storage_1 beiseite legen, letztes Backup einspielen, neu starten.
rollback() {
    local backup broken
    log "Recovery Stufe 3: Rollback."
    backup="$(latest_backup)"
    if [[ -z $backup ]]; then
        log "Kein Backup vorhanden - Rollback nicht möglich."
        return 1
    fi

    touch "$LOCK_FILE"
    hard_kill
    firewall_unblock
    wait_ports_free 30 || log "Ports hängen weiterhin (Zombie)."

    broken="${STORAGE_DIR}.corrupt_$(date +%Y%m%d_%H%M%S)"
    mv "$STORAGE_DIR" "$broken" || { log "storage_1 konnte nicht umbenannt werden."; rm -f "$LOCK_FILE"; return 1; }
    if ! tar -xzf "$backup" -C "$(dirname "$STORAGE_DIR")"; then
        log "Backup konnte nicht entpackt werden - stelle Original wieder her."
        rm -rf "$STORAGE_DIR"
        mv "$broken" "$STORAGE_DIR"
        rm -f "$LOCK_FILE"
        return 1
    fi
    log "Rollback auf $backup (defekte Daten: $broken)."
    rm -f "$LOCK_FILE"
    set_state STOPPED
    "$MANAGER_DIR/start.sh"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    case "${1:-}" in
        soft) soft_restart ;;
        hard) hard_reboot ;;
        rollback) rollback ;;
        *) echo "Verwendung: $0 [soft|hard|rollback]" >&2; exit 1 ;;
    esac
fi
