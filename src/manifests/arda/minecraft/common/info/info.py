"""Per-server facts for the portal, served at :8099/info.json.

Runs beside each server (sidecarContainers in common/values.yaml) and asks
it over RCON on localhost, so the RCON password never leaves the pod:

  versions  from Geyser: the Java version and the Bedrock range it accepts
  map       from squaremap: the overworld, its spawn, and the tile zooms

The world map is rendered in full once if its spawn has never been drawn;
after that squaremap keeps it current as chunks change.
"""

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
MAP = os.environ.get("MAP_URL", "http://127.0.0.1:8080")
PORT = int(os.environ.get("PORT", "8099"))
INTERVAL = int(os.environ.get("INTERVAL", "300"))
TILE_BLOCKS = 512          # squaremap: one tile is 512 px, 1 block per px at max zoom

state = {"updated": None, "versions": None, "map": None}
render_requested = set()


def rcon(command):
    with socket.create_connection(("127.0.0.1", RCON_PORT), timeout=10) as s:
        def send(req_id, kind, body):
            data = struct.pack("<ii", req_id, kind) + body.encode() + b"\x00\x00"
            s.sendall(struct.pack("<i", len(data)) + data)

        def recv():
            size = struct.unpack("<i", _exact(s, 4))[0]
            data = _exact(s, size)
            req_id, kind = struct.unpack("<ii", data[:8])
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


def get_json(path):
    with urllib.request.urlopen(MAP + path, timeout=10) as r:
        return json.load(r)


def tile_drawn(world, zoom, x, z):
    url = f"{MAP}/tiles/{world}/{zoom}/{x}_{z}.png"
    with urllib.request.urlopen(url, timeout=10) as r:
        return len(r.read()) > 0      # squaremap answers undrawn tiles with an empty 200


def map_info():
    worlds = get_json("/tiles/settings.json")["worlds"]
    world = next(w for w in worlds if w["type"] == "normal")
    settings = get_json(f"/tiles/{world['name']}/settings.json")
    spawn = settings["spawn"]
    zoom = settings["zoom"]["max"]
    drawn = tile_drawn(world["name"], zoom, spawn["x"] // TILE_BLOCKS, spawn["z"] // TILE_BLOCKS)
    if not drawn and world["name"] not in render_requested:
        print(rcon(f"squaremap fullrender {world['display_name']}").strip(), flush=True)
        render_requested.add(world["name"])
    return {"world": world["name"], "spawn": spawn, "zoom": {"max": zoom, "default": settings["zoom"]["def"]},
            "tile_blocks": TILE_BLOCKS, "drawn": drawn}


def refresh():
    while True:
        for key, fetch in (("versions", versions), ("map", map_info)):
            try:
                state[key] = fetch()
            except Exception as e:      # the server may still be starting
                print(f"{key}: {e}", flush=True)
        state["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        time.sleep(INTERVAL if state["versions"] and state["map"] else 30)


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
