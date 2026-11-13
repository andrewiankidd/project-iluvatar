"""Writes servers.json for the portal page.

Every INTERVAL seconds: list the Services in this namespace labelled
minecraft.kidd.network/server, ping each one over the Java server-list
protocol and the Bedrock (RakNet) unconnected ping, and write the result
where nginx serves it. The page renders whatever this file says, so a new
server appears here as soon as its Service exists.
"""

import json
import os
import socket
import ssl
import struct
import time
import urllib.request

NAMESPACE = os.environ.get("NAMESPACE", "minecraft")
OUT = os.environ.get("OUT", "/data/servers.json")
INTERVAL = int(os.environ.get("INTERVAL", "30"))
TIMEOUT = 3.0
LABEL = "minecraft.kidd.network/server"
ANN = "minecraft.kidd.network/"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"


def list_services():
    with open(f"{SA}/token") as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    url = (f"https://kubernetes.default.svc/api/v1/namespaces/{NAMESPACE}"
           f"/services?labelSelector={LABEL}")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        return json.load(r)["items"]


def _varint(n):
    out = b""
    n &= 0xFFFFFFFF
    while True:
        b = n & 0x7F
        n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


def _read_varint(sock):
    n = shift = 0
    while True:
        b = sock.recv(1)
        if not b:
            raise ConnectionError("closed mid-varint")
        n |= (b[0] & 0x7F) << shift
        if not b[0] & 0x80:
            return n
        shift += 7


def _recv_exact(sock, size):
    buf = b""
    while len(buf) < size:
        chunk = sock.recv(size - len(buf))
        if not chunk:
            raise ConnectionError("closed mid-packet")
        buf += chunk
    return buf


def java_status(host, port):
    """Server List Ping: version, players, motd."""
    with socket.create_connection((host, port), timeout=TIMEOUT) as s:
        h = host.encode()
        hs = _varint(0) + _varint(-1) + _varint(len(h)) + h + struct.pack(">H", port) + _varint(1)
        s.sendall(_varint(len(hs)) + hs + b"\x01\x00")
        _read_varint(s)                      # packet length
        _read_varint(s)                      # packet id
        data = _recv_exact(s, _read_varint(s))
    st = json.loads(data)
    motd = st.get("description", "")
    if isinstance(motd, dict):
        motd = motd.get("text", "") + "".join(e.get("text", "") for e in motd.get("extra") or [])
    players = st.get("players", {})
    return {
        "version": st.get("version", {}).get("name"),
        "online": players.get("online"),
        "max": players.get("max"),
        "players": [p.get("name") for p in players.get("sample") or []],
        "motd": motd,
    }


RAKNET_MAGIC = bytes.fromhex("00ffff00fefefefefdfdfdfd12345678")


def bedrock_status(host, port):
    """RakNet unconnected ping, answered by Geyser."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(TIMEOUT)
        s.sendto(b"\x01" + struct.pack(">q", int(time.time() * 1000)) + RAKNET_MAGIC + struct.pack(">q", 2), (host, port))
        data, _ = s.recvfrom(2048)
    if data[0] != 0x1C:
        raise ValueError("not an unconnected pong")
    # id(1) time(8) guid(8) magic(16) len(2) "MCPE;motd;protocol;version;online;max;..."
    fields = data[35:].decode("utf-8", "replace").split(";")
    return {"version": fields[3], "online": int(fields[4]), "max": int(fields[5])}


def describe(svc):
    meta = svc["metadata"]
    ann = meta.get("annotations") or {}
    ports = {p["name"]: p["port"] for p in svc["spec"].get("ports", [])}
    internal = f"{meta['name']}.{NAMESPACE}.svc"
    ingress = (svc.get("status", {}).get("loadBalancer", {}).get("ingress") or [{}])[0]
    entry = {
        "name": meta["labels"][LABEL],
        "title": ann.get(ANN + "title", meta["labels"][LABEL]),
        "description": ann.get(ANN + "description", ""),
        "order": ann.get(ANN + "order", "99"),
        "host": ann.get("external-dns.kubernetes.io/hostname"),
        "address": ingress.get("ip") or ingress.get("hostname"),
        "map": ann.get(ANN + "map"),
        "java": None,
        "bedrock": None,
    }
    if "minecraft" in ports:
        entry["java"] = {"port": ports["minecraft"]}
        try:
            started = time.monotonic()
            status = java_status(internal, ports["minecraft"])
            entry["java"].update(up=True, latency_ms=round((time.monotonic() - started) * 1000), **status)
        except Exception as e:
            entry["java"].update(up=False, error=str(e))
    if "bedrock" in ports:
        entry["bedrock"] = {"port": ports["bedrock"]}
        try:
            entry["bedrock"].update(up=True, **bedrock_status(internal, ports["bedrock"]))
        except Exception as e:
            entry["bedrock"].update(up=False, error=str(e))
    # Versions and the spawn map, from the server's info sidecar.
    try:
        url = f"http://{meta['name']}-info.{NAMESPACE}.svc:8099/info.json"
        with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
            info = json.load(r)
        entry["versions"] = info.get("versions")
        entry["spawn_map"] = info.get("map")
    except Exception as e:
        entry["versions"] = entry["spawn_map"] = None
        print(f"{entry['name']}: no info ({e})", flush=True)
    return entry


def main():
    while True:
        try:
            servers = sorted((describe(s) for s in list_services()),
                             key=lambda e: (int(e["order"]) if e["order"].isdigit() else 99, e["name"]))
            doc = {"updated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "servers": servers}
            tmp = OUT + ".tmp"
            with open(tmp, "w") as f:
                json.dump(doc, f)
            os.replace(tmp, OUT)
            print(f"wrote {len(servers)} server(s)", flush=True)
        except Exception as e:
            print(f"refresh failed: {e}", flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
