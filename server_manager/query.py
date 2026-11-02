#!/usr/bin/env python3
"""Steam-A2S_INFO-Abfrage. Verwendung: query.py HOST PORT [TIMEOUT]. Gibt key=value-Zeilen aus, Exit 1 bei Fehler."""
import socket
import sys
import time

REQUEST = b"\xFF\xFF\xFF\xFFTSource Engine Query\x00"


def read_cstr(buf, pos):
    end = buf.index(b"\x00", pos)
    return buf[pos:end].decode("utf-8", "replace"), end + 1


def query(host, port, timeout):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        start = time.monotonic()
        sock.sendto(REQUEST, (host, port))
        data, _ = sock.recvfrom(4096)
        ping = int((time.monotonic() - start) * 1000)
        if data[4:5] == b"\x41":  # Challenge-Antwort
            sock.sendto(REQUEST + data[5:9], (host, port))
            data, _ = sock.recvfrom(4096)
    if data[4:5] != b"\x49":
        raise ValueError("unerwartete Antwort")

    pos = 6  # 4 Byte Header, 'I', Protokoll
    name, pos = read_cstr(data, pos)
    _, pos = read_cstr(data, pos)  # Karte
    _, pos = read_cstr(data, pos)  # Ordner
    _, pos = read_cstr(data, pos)  # Spiel
    pos += 2  # App-ID
    players, max_players = data[pos], data[pos + 1]
    pos += 7  # Spieler, Max, Bots, Typ, Umgebung, Sichtbarkeit, VAC
    version, _ = read_cstr(data, pos)
    return {"name": name, "players": players, "max_players": max_players, "ping_ms": ping, "version": version}


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
    try:
        info = query(sys.argv[1], int(sys.argv[2]), timeout)
    except (OSError, ValueError, IndexError):
        return 1
    for key, value in info.items():
        print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
