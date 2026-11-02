#!/usr/bin/env bash
# Epic 2: Mod- & Key-Management. Als Skript: mods.sh [sync|update|keys|clean|list]; als Bibliothek: source.

LOG_TAG="${LOG_TAG:-mods}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

WORKSHOP_CONTENT="$SERVER_DIR/steamapps/workshop/content/$WORKSHOP_APPID"

# Task 2.1: mods.cfg zeilenweise einlesen, gibt gültige Mod-IDs aus.
mod_ids() {
    local line id
    [[ -r $MODS_CFG ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        line="${line%%#*}"
        id="${line//[[:space:]]/}"
        [[ -z $id ]] && continue
        if [[ $id =~ ^[0-9]+$ ]]; then
            echo "$id"
        else
            log "Ungültige Zeile in mods.cfg ignoriert: '$line'"
        fi
    done < "$MODS_CFG"
}

# Wert für den -mod= Startparameter, z. B. "@123;@456".
mod_param() {
    local id param=""
    while read -r id; do
        param+="@$id;"
    done < <(mod_ids)
    echo "${param%;}"
}

# Task 2.2: SteamCMD-Befehl aus den IDs zusammenbauen und ausführen.
update_mods() {
    local ids id src rc=0
    mapfile -t ids < <(mod_ids)
    if (( ${#ids[@]} == 0 )); then
        log "mods.cfg enthält keine Mods - nichts zu laden."
        return 0
    fi
    if [[ $STEAM_USER == CHANGE_ME ]]; then
        log "STEAM_USER in server.cfg ist nicht gesetzt."
        return 1
    fi

    local args=(+force_install_dir "$SERVER_DIR" +login "$STEAM_USER")
    for id in "${ids[@]}"; do
        args+=(+workshop_download_item "$WORKSHOP_APPID" "$id" validate)
    done
    args+=(+quit)

    log "Lade ${#ids[@]} Mod(s) via SteamCMD ..."
    "$STEAMCMD_DIR/steamcmd.sh" "${args[@]}" || { log "SteamCMD fehlgeschlagen."; return 1; }

    for id in "${ids[@]}"; do
        src="$WORKSHOP_CONTENT/$id"
        if [[ -d $src ]]; then
            ln -sfn "$src" "$SERVER_DIR/@$id"
        else
            log "Mod $id wurde nicht heruntergeladen."
            rc=1
        fi
    done
    return "$rc"
}

# Task 2.3: alle .bikey-Dateien flach nach keys/ verlinken. Alte Key-Links werden vorher entfernt.
extract_keys() {
    local key count=0
    mkdir -p "$KEYS_DIR"
    find "$KEYS_DIR" -maxdepth 1 -type l -delete
    while IFS= read -r -d '' key; do
        ln -sf "$key" "$KEYS_DIR/$(basename "$key")"
        count=$((count + 1))
    done < <(find -L "$SERVER_DIR" -mindepth 2 -path "$SERVER_DIR/@*" -type f -iname '*.bikey' -print0 2>/dev/null)
    log "$count Key(s) nach $KEYS_DIR verlinkt."
}

# Task 2.4: Mods löschen, die nicht mehr in mods.cfg stehen (nur numerische Workshop-IDs).
cleanup_mods() {
    local keep id path
    keep=" $(mod_ids | tr '\n' ' ') "

    for path in "$SERVER_DIR"/@[0-9]*; do
        [[ -e $path || -L $path ]] || continue
        id="${path##*/@}"
        [[ $id =~ ^[0-9]+$ ]] || continue
        if [[ $keep != *" $id "* ]]; then
            log "Entferne Mod $id (nicht mehr in mods.cfg)."
            rm -rf -- "$path"
        fi
    done

    for path in "$WORKSHOP_CONTENT"/[0-9]*; do
        [[ -d $path ]] || continue
        id="${path##*/}"
        if [[ $keep != *" $id "* ]]; then
            log "Entferne Workshop-Daten von Mod $id."
            rm -rf -- "$path"
        fi
    done
    # Verwaiste Key-Links werden in extract_keys() neu aufgebaut.
}

sync_mods() {
    cleanup_mods
    update_mods || { extract_keys; return 1; }
    extract_keys
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    case "${1:-sync}" in
        sync) sync_mods ;;
        update) update_mods ;;
        keys) extract_keys ;;
        clean) cleanup_mods; extract_keys ;;
        list) mod_ids ;;
        *) echo "Verwendung: $0 [sync|update|keys|clean|list]" >&2; exit 1 ;;
    esac
fi
