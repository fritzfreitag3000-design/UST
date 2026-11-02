#!/usr/bin/env bash
# Epic 5: Auto-Recovery Stufen 1-3. Als Skript: recover.sh [soft|hard|rollback]; als Bibliothek: source.

LOG_TAG="${LOG_TAG:-recover}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Stufe 1: reguläre Stopp- und Start-Prozedur ohne Warnzeit.
soft_restart() {
    log "Recovery Stufe 1: Soft-Restart."
    notify "Recovery Stufe 1: Soft-Restart."
    "$MANAGER_DIR/stop.sh" 0 || return 1
    "$MANAGER_DIR/start.sh"
}

# Stufe 2: alle Server-Prozesse hart beenden, Ports freigeben, neu starten.
hard_reboot() {
    log "Recovery Stufe 2: Hard-Reboot."
    notify "Recovery Stufe 2: Hard-Reboot."
    hard_kill
    firewall_unblock
    wait_ports_free 30 || log "Ports hängen weiterhin (Zombie)."
    set_state STOPPED
    "$MANAGER_DIR/start.sh"
}

# Server beenden, storage_1 beiseite legen und das Archiv $1 entpacken. Startet den Server nicht.
apply_backup() {
    local backup="$1" broken=""
    if [[ ! -f $backup ]]; then
        log "Backup $backup nicht gefunden."
        return 1
    fi

    touch "$LOCK_FILE"
    hard_kill
    firewall_unblock
    wait_ports_free 30 || log "Ports hängen weiterhin (Zombie)."

    if [[ -e $STORAGE_DIR ]]; then
        broken="${STORAGE_DIR}.corrupt_$(date +%Y%m%d_%H%M%S)"
        mv "$STORAGE_DIR" "$broken" || { log "storage_1 konnte nicht umbenannt werden."; rm -f "$LOCK_FILE"; return 1; }
    fi
    if ! tar -xzf "$backup" -C "$(dirname "$STORAGE_DIR")"; then
        log "Backup konnte nicht entpackt werden - stelle Original wieder her."
        rm -rf "$STORAGE_DIR"
        [[ -n $broken ]] && mv "$broken" "$STORAGE_DIR"
        rm -f "$LOCK_FILE"
        return 1
    fi
    log "Backup $backup eingespielt (vorherige Daten: ${broken:-keine})."
    rm -f "$LOCK_FILE"
    set_state STOPPED
}

# Stufe 3: letztes Backup einspielen und neu starten.
rollback() {
    local backup
    log "Recovery Stufe 3: Rollback."
    backup="$(latest_backup)"
    if [[ -z $backup ]]; then
        log "Kein Backup vorhanden - Rollback nicht möglich."
        notify "Rollback nicht möglich: kein Backup vorhanden."
        return 1
    fi
    notify "Recovery Stufe 3: Rollback auf $(basename "$backup")."
    apply_backup "$backup" && "$MANAGER_DIR/start.sh"
}

# Manuelles Wiederherstellen (nur bei gestopptem Server), ohne anschließenden Start.
restore_backup() {
    if [[ "$(server_state)" != OFFLINE ]]; then
        log "Wiederherstellen nur bei gestopptem Server möglich."
        return 1
    fi
    apply_backup "${1:-}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    case "${1:-}" in
        soft) soft_restart ;;
        hard) hard_reboot ;;
        rollback) rollback ;;
        restore) restore_backup "${2:-$(latest_backup)}" ;;
        *) echo "Verwendung: $0 [soft|hard|rollback|restore [Archiv]]" >&2; exit 1 ;;
    esac
fi
