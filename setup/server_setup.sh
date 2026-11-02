#!/usr/bin/env bash
# Lädt den DayZ-Server per SteamCMD nach <BASE_DIR>/server_data. Läuft als Dienstbenutzer.
set -Eeuo pipefail

BASE_DIR="${1:-$PWD}"
APPID="${SERVER_APPID:-223350}"
STEAMCMD="$BASE_DIR/steamcmd/steamcmd.sh"
CFG="$BASE_DIR/server_manager/server.cfg"

if [[ $EUID -eq 0 ]]; then
    echo "Fehler: Dieses Skript muss als Dienstbenutzer laufen, nicht als root." >&2
    exit 1
fi

if [[ ! -x "$STEAMCMD" ]]; then
    echo "Fehler: SteamCMD nicht gefunden: $STEAMCMD" >&2
    exit 1
fi

echo "DayZ-Server-Download nach ${BASE_DIR}/server_data"
echo "Hinweis: Der Server (App ${APPID}) erfordert einen Steam-Account, der DayZ besitzt."

read -r -p "Steam-Benutzername: " STEAM_USER
if [[ -z "$STEAM_USER" || ! "$STEAM_USER" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "Fehler: Ungültiger Steam-Benutzername." >&2
    exit 1
fi

# SteamCMD fragt Passwort und ggf. Steam-Guard-Code selbst ab.
"$STEAMCMD" +force_install_dir "$BASE_DIR/server_data" +login "$STEAM_USER" \
    +app_update "$APPID" validate +quit

if [[ -f "$CFG" ]] && grep -q '^STEAM_USER="CHANGE_ME"' "$CFG"; then
    sed -i "s/^STEAM_USER=\"CHANGE_ME\"/STEAM_USER=\"${STEAM_USER}\"/" "$CFG"
    echo "STEAM_USER in server.cfg gesetzt."
fi

echo "DayZ-Server-Download abgeschlossen. Starte ao.sh ..."
exec "$BASE_DIR/server_manager/ao.sh"
