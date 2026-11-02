#!/usr/bin/env bash
# Epic 1: System- & Infrastruktur-Setup (Tasks 1.1 - 1.4). Muss als root laufen.
set -euo pipefail

SERVICE_USER="${SERVICE_USER:-dayz_ao}"
SERVER_NAME="${1:-}"
GAME_PORT="${GAME_PORT:-2302}"
STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"

if [[ $EUID -ne 0 ]]; then
    echo "Fehler: Bitte als root ausführen (sudo $0 <servername>)." >&2
    exit 1
fi

if [[ ! "$SERVER_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Verwendung: $0 <servername>   (erlaubt: Buchstaben, Ziffern, _ und -)" >&2
    exit 1
fi

BASE_DIR="/home/${SERVICE_USER}/${SERVER_NAME}"

# Task 1.3: Abhängigkeiten
install_dependencies() {
    echo "[1.3] Installiere Abhängigkeiten ..."
    dpkg --add-architecture i386
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        tmux qstat python3 ufw iptables tar curl ca-certificates lib32gcc-s1
}

# Task 1.1: Systembenutzer ohne Passwort-Login
create_user() {
    if id "$SERVICE_USER" &>/dev/null; then
        echo "[1.1] Benutzer ${SERVICE_USER} existiert bereits."
    else
        echo "[1.1] Lege Benutzer ${SERVICE_USER} an ..."
        useradd --create-home --shell /bin/bash --comment "DayZ AO-Server" "$SERVICE_USER"
        passwd --lock "$SERVICE_USER" >/dev/null
    fi
    chmod 750 "/home/${SERVICE_USER}"
}

# Task 1.2: Verzeichnisstruktur
create_directories() {
    echo "[1.2] Erstelle Verzeichnisse unter ${BASE_DIR} ..."
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 750 \
        "$BASE_DIR" \
        "$BASE_DIR/steamcmd" \
        "$BASE_DIR/server_data" \
        "$BASE_DIR/server_manager"
}

# Task 1.4: SteamCMD laden und Erstdurchlauf
init_steamcmd() {
    local dir="$BASE_DIR/steamcmd"
    if [[ ! -x "$dir/steamcmd.sh" ]]; then
        echo "[1.4] Lade SteamCMD ..."
        sudo -u "$SERVICE_USER" bash -c \
            "curl -fsSL '$STEAMCMD_URL' | tar -xz -C '$dir'"
    fi
    echo "[1.4] SteamCMD-Erstdurchlauf (Selbst-Update) ..."
    sudo -u "$SERVICE_USER" "$dir/steamcmd.sh" +quit
}

# Tool-Skripte kopieren; vorhandene Konfigurationen bleiben unangetastet.
deploy_manager() {
    local src
    src="$(cd "$(dirname "$0")/../server_manager" && pwd)"
    echo "[deploy] Kopiere Tool nach ${BASE_DIR}/server_manager ..."
    cp -r --update=none "$src/." "$BASE_DIR/server_manager/"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$BASE_DIR/server_manager"
    chmod +x "$BASE_DIR"/server_manager/*.sh "$BASE_DIR"/server_manager/query.py
    chmod 600 "$BASE_DIR/server_manager/server.cfg"
}

# Erlaubt dem Dienstbenutzer nur die beiden Firewall-Regeln für den Game-Port (GAME_PORT muss zu server.cfg passen).
install_sudoers() {
    local tmp target="/etc/sudoers.d/ao-${SERVICE_USER}-${SERVER_NAME}"
    tmp="$(mktemp)"
    echo "${SERVICE_USER} ALL=(root) NOPASSWD: /usr/sbin/iptables -I INPUT -p udp --dport ${GAME_PORT} -j DROP, /usr/sbin/iptables -D INPUT -p udp --dport ${GAME_PORT} -j DROP" > "$tmp"
    if visudo -cf "$tmp" >/dev/null; then
        install -m 440 -o root -g root "$tmp" "$target"
    else
        rm -f "$tmp"
        echo "Fehler: sudoers-Regel ungültig." >&2
        exit 1
    fi
    rm -f "$tmp"
}

# Monitor beim Booten starten; KillMode=process, damit ein Dienst-Neustart den Gameserver nicht beendet.
install_service() {
    local unit="ao-monitor-${SERVER_NAME}.service"
    if ! command -v systemctl >/dev/null || [[ ! -d /run/systemd/system ]]; then
        echo "[service] systemd nicht verfügbar - übersprungen (Monitor per 'ao.sh monitor start')."
        return 0
    fi
    cat > "/etc/systemd/system/${unit}" <<EOF
[Unit]
Description=AO-Server Monitor (${SERVER_NAME})
After=network-online.target
Wants=network-online.target

[Service]
User=${SERVICE_USER}
ExecStart=${BASE_DIR}/server_manager/monitor.sh run
Restart=on-failure
RestartSec=10
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$unit" >/dev/null
    echo "[service] ${unit} aktiviert (Start nach Konfiguration: systemctl start ${unit})."
}

install_dependencies
create_user
create_directories
init_steamcmd
deploy_manager
install_sudoers
install_service

echo "Setup für '${SERVER_NAME}' abgeschlossen: ${BASE_DIR}"
