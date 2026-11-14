"""Per-server facts for the portal, served at :8099/info.json.

Runs beside each server (sidecarContainers in common/values.yaml):

  versions  asked of Geyser over RCON on localhost, so the RCON password
            never leaves the pod: the Java version and the Bedrock range
  spawn     read from the world's level.dat (mounted read-only): where a
            new player appears and which way they face
  map       the BlueMap map that shows that world
"""

import gzip
import json
import os
import re
import socket
import struct
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RCON_PORT = int(os.environ.get("RCON_PORT", "25575"))
RCON_PASSWORD = os.environ["RCON_PASSWORD"]
MAP = os.environ.get("MAP_URL", "http://127.0.0.1:8100")
DATA = os.environ.get("DATA", "/data")
LEVEL = os.environ.get("LEVEL", "world")
PORT = int(os.environ.get("PORT", "8099"))
INTERVAL = int(os.environ.get("INTERVAL", "60"))

state = {"updated": None, "versions": None, "spawn": None, "map": None}


# --- RCON ------------------------------------------------------------------

def rcon(command):
    with socket.create_connection(("127.0.0.1", RCON_PORT), timeout=10) as s:
        def send(req_id, kind, body):
            data = struct.pack("<ii", req_id, kind) + body.encode() + b"\x00\x00"
            s.sendall(struct.pack("<i", len(data)) + data)

        def recv():
            size = struct.unpack("<i", _exact(s, 4))[0]
            data = _exact(s, size)
            req_id, _ = struct.unpack("<ii", data[:8])
            return req_id, data[8:-2].decode("utf-8", "replace")

        send(1, 3, RCON_PASSWORD)
        if recv()[0] == -1:
            raise PermissionError("RCON refused the password")
        send(2, 2, command)
        return recv()[1]


def _exact(s, size):
    buf = b""
    while len(buf) < size:
        chunk = s.recv(size - len(buf))
        if not chunk:
            raise ConnectionError("RCON closed")
        buf += chunk
    return buf


def versions():
    out = re.sub(r"§.", "", rcon("geyser version"))
    m = re.search(r"\(Java: ([^,]+), Bedrock: ([^)]+)\)", out)
    if not m:
        raise ValueError(f"unexpected geyser version output: {out!r}")
    bedrock = [v.strip() for v in m.group(2).split("-")]
    return {"java": {"min": m.group(1).strip(), "max": m.group(1).strip()},
            "bedrock": {"min": bedrock[0], "max": bedrock[-1]}}


# --- level.dat (gzipped NBT) -----------------------------------------------

class _Nbt:
    def __init__(self, data):
        self.d, self.i = data, 0

    def take(self, fmt):
        v = struct.unpack_from(fmt, self.d, self.i)
        self.i += struct.calcsize(fmt)
        return v[0]

    def string(self):
        n = self.take(">H")
        s = self.d[self.i:self.i + n].decode("utf-8", "replace")
        self.i += n
        return s

    def payload(self, tag):
        if tag == 1: return self.take(">b")
        if tag == 2: return self.take(">h")
        if tag == 3: return self.take(">i")
        if tag == 4: return self.take(">q")
        if tag == 5: return self.take(">f")
        if tag == 6: return self.take(">d")
        if tag == 7: n = self.take(">i"); self.i += n; return None
        if tag == 8: return self.string()
        if tag == 9:
            inner, n = self.take(">b"), self.take(">i")
            return [self.payload(inner) for _ in range(n)]
        if tag == 10:
            out = {}
            while (t := self.take(">b")) != 0:
                name = self.string()
                out[name] = self.payload(t)
            return out
        if tag == 11: n = self.take(">i"); return [self.take(">i") for _ in range(n)]
        if tag == 12: n = self.take(">i"); return [self.take(">q") for _ in range(n)]
        raise ValueError(f"NBT tag {tag}")

    def root(self):
        tag = self.take(">b")
        self.string()
        return self.payload(tag)


def spawn():
    with gzip.open(f"{DATA}/{LEVEL}/level.dat") as f:
        data = _Nbt(f.read()).root()["Data"]
    if isinstance(data.get("spawn"), dict):                 # 1.21.9 and later
        s = data["spawn"]
        x, y, z = s["pos"]
        return {"x": x, "y": y, "z": z, "yaw": s.get("yaw", 0.0), "pitch": s.get("pitch", 0.0)}
    return {"x": data["SpawnX"], "y": data["SpawnY"], "z": data["SpawnZ"],
            "yaw": data.get("SpawnAngle", 0.0), "pitch": 0.0}


# --- BlueMap ---------------------------------------------------------------

def bluemap():
    with urllib.request.urlopen(MAP + "/settings.json", timeout=10) as r:
        maps = json.load(r)["maps"]
    overworld = next((m for m in maps if m in ("world", "overworld")), maps[0])
    return {"id": overworld}


# --- serving ---------------------------------------------------------------

def refresh():
    while True:
        for key, fetch in (("versions", versions), ("spawn", spawn), ("map", bluemap)):
            try:
                state[key] = fetch()
            except Exception as e:      # the server may still be starting
                print(f"{key}: {e}", flush=True)
        state["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        time.sleep(INTERVAL if all(state[k] for k in ("versions", "spawn", "map")) else 30)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/info.json":
            self.send_error(404)
            return
        body = json.dumps(state).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    threading.Thread(target=refresh, daemon=True).start()
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
