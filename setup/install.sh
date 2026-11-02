#!/usr/bin/env bash
# Epic 1: System- & Infrastruktur-Setup (Tasks 1.1 - 1.4). Muss als root laufen.
set -Eeuo pipefail

SERVICE_USER="${SERVICE_USER:-dayz_ao}"
SERVER_NAME="${1:-}"
GAME_PORT="${GAME_PORT:-2302}"
STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"

usage() {
    echo "Verwendung: sudo $0 [servername]"
    echo "Ohne Servernamen startet der interaktive Installationsassistent."
}

prompt_value() {
    local label="$1" default="${2:-}" value
    if [[ -n "$default" ]]; then
        read -r -p "$label [$default]: " value
        printf '%s' "${value:-$default}"
    else
        read -r -p "$label: " value
        printf '%s' "$value"
    fi
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

if (( $# > 1 )); then
    usage >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Fehler: Bitte mit sudo starten (sudo $0)." >&2
    exit 1
fi

if [[ ! -t 0 ]]; then
    echo "Fehler: Der Installationsassistent benötigt ein interaktives Terminal." >&2
    exit 1
fi

echo "AO DayZ Server - Installation"
echo "Der Assistent fragt die Grunddaten ab und führt danach alle Setup-Schritte aus."

if [[ -z "$SERVER_NAME" ]]; then
    while true; do
        SERVER_NAME="$(prompt_value "Servername (Buchstaben, Ziffern, _ und -)" "")"
        if [[ "$SERVER_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
            break
        fi
        echo "Bitte einen gültigen Servernamen eingeben." >&2
    done
elif [[ ! "$SERVER_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Fehler: Servername darf nur Buchstaben, Ziffern, _ und - enthalten." >&2
    exit 1
fi

SERVICE_USER="$(prompt_value "Linux-Dienstbenutzer" "$SERVICE_USER")"
while [[ ! "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; do
    echo "Bitte einen gültigen Linux-Benutzernamen eingeben (max. 32 Zeichen)." >&2
    SERVICE_USER="$(prompt_value "Linux-Dienstbenutzer" "dayz_ao")"
done

if [[ ! "$GAME_PORT" =~ ^[0-9]+$ ]] || (( GAME_PORT < 1 || GAME_PORT > 65535 )); then
    echo "Fehler: GAME_PORT muss eine Zahl zwischen 1 und 65535 sein." >&2
    exit 1
fi

BASE_DIR="/home/${SERVICE_USER}/${SERVER_NAME}"

echo
echo "Bitte Angaben prüfen:"
echo "  Servername:       ${SERVER_NAME}"
echo "  Dienstbenutzer:   ${SERVICE_USER}"
echo "  Installationsort: ${BASE_DIR}"
echo "  Game-Port:        ${GAME_PORT}/UDP"
while true; do
    read -r -p "Installation starten? [J/n] " CONFIRM
    case "${CONFIRM,,}" in
        n|nein) echo "Installation abgebrochen."; exit 0 ;;
        ""|j|ja) break ;;
        *) echo "Bitte mit j oder n antworten." >&2 ;;
    esac
done

# Task 1.3: Abhängigkeiten
install_dependencies() {
    echo "[2/8] Installiere Systempakete ..."
    dpkg --add-architecture i386
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        sudo tmux qstat python3 ufw iptables tar curl ca-certificates lib32gcc-s1
}

# Task 1.1: Systembenutzer mit Passwort-Login
create_user() {
    local created=false password_state
    echo "[1/8] Richte den Dienstbenutzer ein ..."
    if id "$SERVICE_USER" &>/dev/null; then
        echo "[1.1] Benutzer ${SERVICE_USER} existiert bereits."
    else
        echo "[1.1] Lege Benutzer ${SERVICE_USER} an ..."
        useradd --create-home --shell /bin/bash --comment "DayZ AO-Server" "$SERVICE_USER"
        created=true
    fi
    password_state="$(passwd -S "$SERVICE_USER" | awk '{print $2}')"
    if [[ "$created" == true || "$password_state" != P ]]; then
        echo "Legen Sie jetzt das Passwort für ${SERVICE_USER} fest."
        passwd "$SERVICE_USER"
    else
        echo "Der bestehende Passwortzugang bleibt unverändert."
    fi
    chmod 750 "/home/${SERVICE_USER}"
}

# Task 1.2: Verzeichnisstruktur
create_directories() {
    echo "[3/8] Erstelle Serververzeichnisse unter ${BASE_DIR} ..."
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 750 \
        "$BASE_DIR" \
        "$BASE_DIR/steamcmd" \
        "$BASE_DIR/server_data" \
        "$BASE_DIR/server_manager"
}

# Task 1.4: SteamCMD laden und Erstdurchlauf
init_steamcmd() {
    local dir="$BASE_DIR/steamcmd"
    echo "[4/8] Installiere und initialisiere SteamCMD ..."
    if [[ ! -x "$dir/steamcmd.sh" ]]; then
        sudo -u "$SERVICE_USER" bash -c \
            "curl -fsSL '$STEAMCMD_URL' | tar -xz -C '$dir'"
    fi
    sudo -u "$SERVICE_USER" "$dir/steamcmd.sh" +quit
}

# Tool-Skripte kopieren; vorhandene Konfigurationen bleiben unangetastet.
deploy_manager() {
    local src
    src="$(cd "$(dirname "$0")/../server_manager" && pwd)"
    echo "[5/8] Installiere Server-Manager ..."
    cp -r --update=none "$src/." "$BASE_DIR/server_manager/"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$BASE_DIR/server_manager"
    chmod +x "$BASE_DIR"/server_manager/*.sh "$BASE_DIR"/server_manager/query.py
    chmod 600 "$BASE_DIR/server_manager/server.cfg"
}

install_launcher() {
    local launcher="/usr/local/bin/ao-${SERVER_NAME}"
    echo "[6/8] Installiere globalen Befehl ..."
    ln -sfn "$BASE_DIR/server_manager/ao.sh" "$launcher"
    echo "[launcher] Globaler Befehl installiert: ${launcher}"
}

# Erlaubt dem Dienstbenutzer nur die beiden Firewall-Regeln für den Game-Port (GAME_PORT muss zu server.cfg passen).
install_sudoers() {
    local tmp target="/etc/sudoers.d/ao-${SERVICE_USER}-${SERVER_NAME}"
    echo "[7/8] Richte eingeschränkte Firewall-Berechtigung ein ..."
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
    echo "[8/8] Richte den Monitor-Dienst ein ..."
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

create_user
install_dependencies
create_directories
init_steamcmd
deploy_manager
install_launcher
install_sudoers
install_service

echo "Setup für '${SERVER_NAME}' abgeschlossen: ${BASE_DIR}"
echo "Startbefehl: sudo -u ${SERVICE_USER} ao-${SERVER_NAME}"
echo "Vor dem Serverstart bitte server.cfg, DayZ-Serverdaten und bercon-cli konfigurieren."
