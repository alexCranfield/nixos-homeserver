# A stand-in Minecraft server for tests/observability.nix: it answers the
# status ping (Server List Ping) on 127.0.0.1:25565 with the player count
# held in the file given as the first argument and, if the second argument
# names a file, the player sample listed there (a JSON list of names; like
# the real server's, it can be shorter than the count). Names are made up. The
# build sandbox has no internet to pull the real image.
import json
import socket
import struct
import sys
import threading

COUNT_FILE = sys.argv[1]
SAMPLE_FILE = sys.argv[2] if len(sys.argv) > 2 else None


def varint(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


def read_varint(conn):
    n = shift = 0
    while True:
        b = conn.recv(1)
        if not b:
            raise EOFError
        n |= (b[0] & 0x7F) << shift
        if not b[0] & 0x80:
            return n
        shift += 7


def read_packet(conn):
    length = read_varint(conn)
    data = b""
    while len(data) < length:
        chunk = conn.recv(length - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data


def send(conn, payload):
    conn.sendall(varint(len(payload)) + payload)


def handle(conn):
    try:
        while True:
            pkt = read_packet(conn)
            if pkt[0] == 0x00 and len(pkt) == 1:
                online = int(open(COUNT_FILE).read())
                players = {"max": 20, "online": online}
                if SAMPLE_FILE:
                    names = json.load(open(SAMPLE_FILE))
                    players["sample"] = [
                        {"name": n, "id": "00000000-0000-0000-0000-000000000000"}
                        for n in names
                    ]
                status = {
                    "version": {"name": "fake 1.20.1", "protocol": 763},
                    "players": players,
                    "description": {"text": "test"},
                }
                body = json.dumps(status).encode()
                send(conn, b"\x00" + varint(len(body)) + body)
            elif pkt[0] == 0x01:
                send(conn, pkt)
    except (EOFError, OSError):
        pass
    finally:
        conn.close()


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 25565))
srv.listen()
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
