# UST – DayZ AO Server Manager

Dieses Projekt enthält ein Bash-Werkzeug zum Einrichten und Verwalten eines
DayZ-Servers unter Linux. Es bietet ein interaktives Dashboard und Befehle für
Serverstart und -stopp, Mod-Verwaltung, Backups, Statusabfragen und automatische
Überwachung mit Recovery.

## Voraussetzungen

- Debian- oder Ubuntu-Server mit `systemd`, Internetzugriff und `apt`
- Root-Zugriff für die Installation
- Ein DayZ-Server-Name, der nur Buchstaben, Ziffern, `-` und `_` enthält
- Ein Steam-Konto, das für die benötigten Workshop-Downloads berechtigt ist
- `bercon-cli` für RCON-Steuerung; es muss im `PATH` des Dienstbenutzers
  verfügbar sein

Der Installationsassistent führt die nötigen Infrastruktur-Schritte nacheinander
aus: Dienstbenutzer, Systempakete, Verzeichnisse, SteamCMD, Manager, Firewall-
Berechtigung und Monitor-Dienst. Er konfiguriert **nicht** automatisch den
DayZ-Server, RCON oder die Mod-Liste. Diese Schritte sind unten beschrieben.

## Installation

Im Verzeichnis des ausgecheckten Projekts starten:

```bash
sudo ./setup/install.sh
```

Der Assistent fragt nach dem Servernamen und dem Linux-Dienstbenutzer. Für den
Benutzer `dayz_ao` kann einfach Enter gedrückt werden. Danach zeigt er die
Einstellungen zur Bestätigung an und führt die Installation durch. Für einen
neuen oder noch gesperrten Benutzer wird ein Passwort abgefragt; ein bereits
aktiver Passwortzugang bleibt bei erneuten Installationsläufen unverändert.

Der Servername kann auch direkt übergeben werden, dann entfällt diese Frage:

```bash
sudo ./setup/install.sh chernarus
```

Standardmäßig wird `dayz_ao` als Systembenutzer vorgeschlagen und das Tool zum
Beispiel nach `/home/dayz_ao/chernarus/server_manager` kopiert. Ein anderer
Benutzer kann im Assistenten eingegeben oder als Vorschlag vorgegeben werden:

```bash
sudo env SERVICE_USER=dayz ./setup/install.sh chernarus
```

Das Setup installiert unter anderem `tmux`, `qstat`, Python 3, `ufw`,
`iptables`, `curl` und SteamCMD. Es richtet außerdem eine eingeschränkte
`sudoers`-Regel für die Firewall ein. Falls `systemd` vorhanden ist, wird der
Monitor-Dienst angelegt und für den Systemstart aktiviert; er wird durch das
Setup noch nicht gestartet. Der Assistent benötigt ein interaktives Terminal.

## Erstkonfiguration

Alle folgenden Pfade verwenden im Beispiel den Namen `chernarus` und den
Standardbenutzer `dayz_ao`.

1. Bearbeite
   `/home/dayz_ao/chernarus/server_manager/server.cfg`. Setze mindestens:
   - `RCON_PASSWORD` auf dasselbe Passwort wie in der Serverkonfiguration.
   - `STEAM_USER` auf das Steam-Konto für SteamCMD.
   - `GAME_PORT`, `QUERY_PORT` und `RCON_PORT` passend zur Serverkonfiguration.
   - Optional `DISCORD_WEBHOOK_URL` für Benachrichtigungen.

   Die Datei enthält ein RCON-Passwort und sollte nur für den Dienstbenutzer
   lesbar sein. Das Setup setzt die Dateirechte auf `600`.

2. SteamCMD muss sich mit dem konfigurierten Steam-Konto anmelden können. Beim
   ersten Login können Passwort- oder Steam-Guard-Eingaben erforderlich sein.
   SteamCMD liegt unter
   `/home/dayz_ao/chernarus/steamcmd/steamcmd.sh`.

3. Stelle sicher, dass der DayZ-Server und seine Konfiguration unter
   `/home/dayz_ao/chernarus/server_data` liegen. Das Setup lädt den
   DayZ-Server nicht automatisch herunter. Nach der SteamCMD-Konfiguration
   kann der Server im gestoppten Zustand mit `ao-chernarus update-server` aktualisiert
   werden.

4. Trage in `server_manager/mods.cfg` Workshop-IDs ein, jeweils eine pro Zeile.
   Zeilen mit `#` sind Kommentare. Die Datei enthält anfangs nur ein Beispiel.
   Für zeitgesteuerte Neustarts trage in `server_manager/schedule.cfg` Zeiten
   im Format `HH:MM` ein. Die Zeiten beziehen sich auf die Serverzeit; die
   Warnung beginnt entsprechend `SHUTDOWN_WARN_MINUTES` vorher.

5. Installiere `bercon-cli` separat und stelle sicher, dass es für den
   Dienstbenutzer im `PATH` verfügbar ist. RCON wird für geordnetes Stoppen und
   die RCON-Gesundheitsprüfung des Monitors verwendet.

Konfigurationsdateien können direkt unter
`/home/dayz_ao/chernarus/server_manager` bearbeitet werden. Das Setup kopiert
die Dateien nur, wenn sie noch nicht vorhanden sind; ein erneuter Setup-Lauf
überschreibt bestehende Konfigurationen nicht.

## Server steuern

Das Setup installiert den globalen Befehl `ao-<server-name>` in
`/usr/local/bin`. Er ist damit von jedem Verzeichnis aus aufrufbar. Für das
Beispiel `chernarus`:

```bash
sudo -u dayz_ao ao-chernarus
```

Ohne Argument öffnet der Befehl ein Dashboard, das den Status regelmäßig
aktualisiert. Alternativ sind die folgenden Befehle verfügbar:

```text
ao-chernarus start                  Server starten
ao-chernarus stop [Minuten]         Server mit Warnung stoppen (Standard: 5 Minuten)
ao-chernarus status                 Status im Textformat
ao-chernarus status --json          Status als JSON
ao-chernarus update                 Mods synchronisieren und Keys aktualisieren
ao-chernarus update-server          DayZ-Server aktualisieren
ao-chernarus backup                 storage_1 sichern
ao-chernarus restore [Archiv]       storage_1 aus Backup wiederherstellen
ao-chernarus logs                   letzte Logzeilen anzeigen
ao-chernarus monitor start|stop|status
```

Der Befehl muss als Dienstbenutzer laufen, damit er Zugriff auf Serverdateien
und tmux-Sitzung hat. Für andere Servernamen wird der jeweilige Name verwendet,
zum Beispiel `ao-livonia`. Auch als Einmal-Befehl funktioniert er aus jedem
Verzeichnis:

```bash
sudo -u dayz_ao ao-chernarus status
```

Mod- und DayZ-Server-Updates sowie manuelle Backups und Wiederherstellungen
sind nur bei gestopptem Server möglich. Beim Stoppen wird automatisch ein
Backup der `storage_1` erstellt. Wiederherstellen verschiebt vorhandene Daten
zur Sicherung auf einen Namen mit `.corrupt_<Zeitstempel>` und startet den
Server anschließend **nicht** automatisch.

## Monitor und Recovery

Der Monitor prüft den Server regelmäßig, erkennt Abstürze, RCON-Probleme und
Konfigurationsfehler in den RPT-Logs. Er kann den Server neu starten und bei
Erkennung eines Datenbankfehlers ein Backup einspielen. Bei wiederholten
Fehlern kann er eine Wartungssperre setzen; in diesem Zustand wird ein Start
verweigert, bis die Sperre nach Prüfung manuell entfernt wurde.

Wenn das Setup einen systemd-Dienst angelegt hat:

```bash
sudo systemctl start ao-monitor-chernarus.service
sudo systemctl status ao-monitor-chernarus.service
```

Der Dienst ist für den Systemstart aktiviert. Ohne systemd kann der Monitor
manuell gestartet und verwaltet werden:

```bash
sudo -u dayz_ao ao-chernarus monitor start
sudo -u dayz_ao ao-chernarus monitor status
sudo -u dayz_ao ao-chernarus monitor stop
```

## Backups und Logs

Backups liegen unter
`/home/dayz_ao/chernarus/backups`. `BACKUP_KEEP` in `server.cfg` begrenzt die
Anzahl aufbewahrter Backups (Standard: 14; `0` bedeutet unbegrenzt).
Die Manager-Logs befinden sich unter
`/home/dayz_ao/chernarus/server_manager/logs`; `LOG_MAX_BYTES` legt die Größe
fest, ab der das Log rotiert wird.

## Projektstruktur

- `setup/install.sh` – Systemabhängigkeiten, Benutzer, Verzeichnisse und
  Monitor-Dienst einrichten
- `server_manager/ao.sh` – Dashboard und zentrale Kommandozeile
- `server_manager/server.cfg` – zentrale Server- und Tool-Konfiguration
- `server_manager/mods.cfg` – Workshop-Mod-IDs
- `server_manager/schedule.cfg` – geplante Neustartzeiten
- `server_manager/start.sh`, `stop.sh`, `monitor.sh`, `recover.sh` – Start,
  Stopp, Überwachung und Recovery
- `docs/` – Pflichtenheft und Backlog