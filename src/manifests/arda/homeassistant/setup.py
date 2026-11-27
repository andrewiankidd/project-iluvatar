# Home Assistant's setup, without anyone clicking through it: what the UI
# would do, through the same APIs. Run by the CronJob in setup.yaml every 10
# minutes; each step checks first and does nothing if it's already done, so
# a fresh (or restored) volume converges and a finished one is left alone.
#
#   onboarding    the owner "admin" with OWNER_PASSWORD (ARDA_HOMEASSISTANT_PASSWORD),
#                 and the other onboarding steps (their settings are
#                 configuration.yaml's; analytics stay off)
#   integrations  Whisper and Piper (Wyoming), Ollama, the Matter Server,
#                 Google Cast
#   Ollama agent  a conversation agent on MODEL that may control the house
#                 (Assist's API)
#   pipeline      "Local": Whisper, Home Assistant's own intents first, then
#                 Ollama, Piper; the preferred pipeline
#   location      the home's, if ARDA_HOMEASSISTANT_LATITUDE/LONGITUDE are set
#   metrics       a long-lived token named "prometheus", in the
#                 homeassistant-metrics Secret, for Prometheus to scrape
#                 /api/prometheus (metrics.yaml); made again if it stops working
#
# Things it won't change once made (the owner's password, the pipeline's
# settings), it doesn't fight: changes made in the UI afterwards stay.
#
# It logs in as the owner each run and revokes that login at the end. Waiting
# on something still starting (Home Assistant, a model download) is not a
# failure: it says so and the next run carries on.
import asyncio
import base64
import os
import ssl
import sys

import aiohttp
from wyoming.client import AsyncTcpClient
from wyoming.info import Describe, Info

BASE = os.environ["HA_URL"].rstrip("/")
CLIENT_ID = os.environ["CLIENT_ID"]
PASSWORD = os.environ.get("OWNER_PASSWORD", "")
MODEL = os.environ["MODEL"]
OLLAMA_URL = os.environ["OLLAMA_URL"]
MATTER_URL = os.environ["MATTER_URL"]
WYOMING = [(h, int(p)) for h, p in (x.split(":") for x in os.environ["WYOMING"].split())]
LATITUDE = os.environ.get("LATITUDE", "")
LONGITUDE = os.environ.get("LONGITUDE", "")
USERNAME = "admin"
PIPELINE = "Local"

problems = []


class Waiting(Exception):
    """Something isn't up yet; the next run will catch it."""


async def call(s, method, path, body=None, token=None, form=False, ok404=False):
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    kw = {"data": body} if form else ({"json": body} if body is not None else {})
    async with s.request(method, BASE + path, headers=headers, **kw) as r:
        if ok404 and r.status == 404:
            return None
        if r.status >= 400:
            raise RuntimeError(f"{method} {path}: {r.status} {await r.text()}")
        return await r.json(content_type=None) if r.content_length != 0 else None


async def onboard_and_login(s):
    """Finish onboarding if needed; return an auth code for the owner."""
    steps = await call(s, "GET", "/api/onboarding", ok404=True)
    todo = {x["step"] for x in steps or [] if not x["done"]}
    if "user" in todo:
        code = (await call(s, "POST", "/api/onboarding/users", {
            "client_id": CLIENT_ID, "name": "Admin", "username": USERNAME,
            "password": PASSWORD, "language": "en-GB",
        }))["auth_code"]
        print("onboarding: created the owner, admin")
        return code, todo
    flow = await call(s, "POST", "/auth/login_flow", {
        "client_id": CLIENT_ID, "handler": ["homeassistant", None], "redirect_uri": CLIENT_ID,
    })
    result = await call(s, "POST", f"/auth/login_flow/{flow['flow_id']}", {
        "client_id": CLIENT_ID, "username": USERNAME, "password": PASSWORD,
    })
    if result.get("type") != "create_entry":
        raise RuntimeError(f"logging in as admin failed: {result.get('errors')}")
    return result["result"], todo


async def flow(s, token, handler, *inputs, ws=None):
    """Run a config flow with the given form inputs, in order. If discovery
    already has one open for this integration (Cast does), confirm that one."""
    r = await call(s, "POST", "/api/config/config_entries/flow",
                   {"handler": handler, "show_advanced_options": False}, token=token)
    if r["type"] == "abort" and r.get("reason") == "already_in_progress" and ws:
        found = [f for f in await ws("config_entries/flow/progress") if f["handler"] == handler]
        if found:
            r = {"type": "form", "flow_id": found[0]["flow_id"]}
    for data in inputs:
        if r["type"] != "form":
            break
        r = await call(s, "POST", f"/api/config/config_entries/flow/{r['flow_id']}", data, token=token)
    if r["type"] == "create_entry":
        print(f"integration: added {handler} ({r.get('title')})")
    elif r["type"] == "abort" and r.get("reason") in (
            "already_configured", "single_instance_allowed", "already_in_progress"):
        pass
    else:
        if r["type"] == "form":
            await call(s, "DELETE", f"/api/config/config_entries/flow/{r['flow_id']}", token=token)
        problems.append(f"{handler}: {r['type']} {r.get('reason') or r.get('errors')}")


async def wyoming_name(host, port):
    """The title Home Assistant gives a Wyoming server's entry: its first
    installed speech-to-text or text-to-speech program's name."""
    async with AsyncTcpClient(host, port) as client:
        await client.write_event(Describe().event())
        while (event := await client.read_event()) is not None:
            if Info.is_type(event.type):
                info = Info.from_event(event)
                return next((p.name for p in [*info.asr, *info.tts] if p.installed), None)
    return None


async def integrations(s, token, ws):
    """Add each integration that isn't there. Wyoming's flow doesn't refuse
    a second entry for the same server, so its entries are told apart by
    title, and any duplicate (newest first) is removed."""
    entries = await call(s, "GET", "/api/config/config_entries/entry", token=token)
    domains = {e["domain"] for e in entries}
    wyoming = sorted((e for e in entries if e["domain"] == "wyoming"), key=lambda e: e["created_at"])
    seen = set()
    for e in wyoming:
        if e["title"] in seen:
            await call(s, "DELETE", f"/api/config/config_entries/entry/{e['entry_id']}", token=token)
            print(f"integration: removed a duplicate wyoming entry ({e['title']})")
        seen.add(e["title"])
    for host, port in WYOMING:
        try:
            name = await wyoming_name(host, port)
        except OSError as e:
            raise Waiting(f"{host}:{port} isn't answering ({e})")
        if name not in seen:
            await flow(s, token, "wyoming", {"host": host, "port": port})
    if "ollama" not in domains:
        await flow(s, token, "ollama", {"url": OLLAMA_URL})
    if "matter" not in domains:
        await flow(s, token, "matter", {"url": MATTER_URL})
    if "cast" not in domains:
        await flow(s, token, "cast", {}, ws=ws)


class WS:
    def __init__(self, ws):
        self.ws, self.n = ws, 0

    async def __call__(self, type_, **kw):
        self.n += 1
        await self.ws.send_json({"id": self.n, "type": type_, **kw})
        while True:
            msg = await self.ws.receive_json()
            if msg.get("id") == self.n and msg.get("type") == "result":
                if not msg["success"]:
                    raise RuntimeError(f"{type_}: {msg['error']}")
                return msg["result"]


async def ollama_agent(s, token, ws, entries):
    entry = next((e for e in entries if e["domain"] == "ollama"), None)
    if entry is None or entry["state"] != "loaded":
        raise Waiting("Ollama's integration isn't loaded yet")
    subs = await ws("config_entries/subentries/list", entry_id=entry["entry_id"])
    if any(x["subentry_type"] == "conversation" for x in subs):
        return
    async with s.get(f"{OLLAMA_URL}/api/tags") as r:
        models = {m["model"] for m in (await r.json())["models"]}
    if MODEL not in models and f"{MODEL}:latest" not in models:
        raise Waiting(f"Ollama is still pulling {MODEL}")
    r = await call(s, "POST", "/api/config/config_entries/subentries/flow",
                   {"handler": [entry["entry_id"], "conversation"]}, token=token)
    r = await call(s, "POST", f"/api/config/config_entries/subentries/flow/{r['flow_id']}", {
        "name": "Ollama Conversation", "model": MODEL, "llm_hass_api": ["assist"],
    }, token=token)
    if r["type"] != "create_entry":
        problems.append(f"Ollama agent: {r['type']} {r.get('reason') or r.get('errors')}")
    else:
        print(f"Ollama: conversation agent on {MODEL}")


async def pipeline(ws):
    reg = await ws("config/entity_registry/list")
    def find(platform, domain, hint=""):
        return next((e["entity_id"] for e in reg if e["platform"] == platform
                     and e["entity_id"].startswith(domain + ".") and hint in e["entity_id"]), None)
    stt, tts = find("wyoming", "stt"), find("wyoming", "tts")
    agent = find("ollama", "conversation")
    if not (stt and tts and agent):
        raise Waiting(f"the pipeline's parts aren't all there yet (stt={stt} tts={tts} agent={agent})")
    found = await ws("assist_pipeline/pipeline/list")
    local = next((p for p in found["pipelines"] if p["name"] == PIPELINE), None)
    if local is None:
        local = await ws("assist_pipeline/pipeline/create",
                         name=PIPELINE, language="en", conversation_engine=agent,
                         conversation_language="en", prefer_local_intents=True,
                         stt_engine=stt, stt_language="en",
                         tts_engine=tts, tts_language="en_GB", tts_voice="en_GB-alba-medium",
                         wake_word_entity=None, wake_word_id=None)
        print(f"pipeline: made {PIPELINE} ({stt}, {agent}, {tts})")
    if found.get("preferred_pipeline") != local["id"]:
        await ws("assist_pipeline/pipeline/set_preferred", pipeline_id=local["id"])
        print(f"pipeline: {PIPELINE} is preferred")


async def location(ws):
    if not (LATITUDE and LONGITUDE):
        return
    lat, lon = float(LATITUDE), float(LONGITUDE)
    conf = await ws("get_config")
    if (round(conf["latitude"], 5), round(conf["longitude"], 5)) != (round(lat, 5), round(lon, 5)):
        await ws("config/core/update", latitude=lat, longitude=lon)
        print("location: set from ARDA_HOMEASSISTANT_LATITUDE/LONGITUDE")


SA = "/var/run/secrets/kubernetes.io/serviceaccount"
METRICS_SECRET = "homeassistant-metrics"
METRICS_TOKEN_NAME = "prometheus"


async def kube(s, method, path, body=None):
    """The Kubernetes API, as this pod's ServiceAccount (setup.yaml's Role)."""
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    headers = {"Authorization": "Bearer " + open(f"{SA}/token").read().strip()}
    async with s.request(method, "https://kubernetes.default.svc" + path, headers=headers,
                         json=body, ssl=ctx) as r:
        return r.status, (await r.json(content_type=None) if r.status != 204 else None)


async def metrics_token(s, ws):
    """Prometheus's long-lived token: kept while it works, made again if not."""
    ns = open(f"{SA}/namespace").read().strip()
    secrets = f"/api/v1/namespaces/{ns}/secrets"
    status, secret = await kube(s, "GET", f"{secrets}/{METRICS_SECRET}")
    if status == 200 and secret.get("data", {}).get("token"):
        have = base64.b64decode(secret["data"]["token"]).decode()
        async with s.get(BASE + "/api/", headers={"Authorization": f"Bearer {have}"}) as r:
            if r.status == 200:
                return
    # Token names are unique: the old one goes first.
    for t in await ws("auth/refresh_tokens"):
        if t.get("client_name") == METRICS_TOKEN_NAME:
            await ws("auth/delete_refresh_token", refresh_token_id=t["id"])
    token = await ws("auth/long_lived_access_token", client_name=METRICS_TOKEN_NAME, lifespan=3650)
    body = {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": METRICS_SECRET},
            "stringData": {"token": token}}
    if status == 200:
        status, _ = await kube(s, "PUT", f"{secrets}/{METRICS_SECRET}", body)
    else:
        status, _ = await kube(s, "POST", secrets, body)
    if status >= 300:
        raise RuntimeError(f"saving {METRICS_SECRET}: {status}")
    print(f"metrics: made Prometheus's token ({METRICS_SECRET})")


async def main():
    if not PASSWORD:
        sys.exit("no owner password (ARDA_HOMEASSISTANT_PASSWORD); leaving Home Assistant alone")
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=60)) as s:
        try:
            code, todo = await onboard_and_login(s)
        except aiohttp.ClientConnectionError as e:
            print(f"Home Assistant isn't answering yet ({e}); next time")
            return
        tokens = await call(s, "POST", "/auth/token", {
            "grant_type": "authorization_code", "code": code, "client_id": CLIENT_ID,
        }, form=True)
        token = tokens["access_token"]
        try:
            for step in ("core_config", "analytics"):
                if step in todo:
                    await call(s, "POST", f"/api/onboarding/{step}", {}, token=token)
            if "integration" in todo:
                await call(s, "POST", "/api/onboarding/integration",
                           {"client_id": CLIENT_ID, "redirect_uri": CLIENT_ID}, token=token)
            if todo:
                print("onboarding: done")

            async with s.ws_connect(BASE + "/api/websocket") as raw:
                await raw.receive_json()
                await raw.send_json({"type": "auth", "access_token": token})
                if (await raw.receive_json())["type"] != "auth_ok":
                    raise RuntimeError("websocket auth failed")
                ws = WS(raw)
                await location(ws)
                try:
                    await metrics_token(s, ws)
                except Exception as e:
                    problems.append(f"metrics token: {e}")
                try:
                    await integrations(s, token, ws)
                    entries = await call(s, "GET", "/api/config/config_entries/entry", token=token)
                    await ollama_agent(s, token, ws, entries)
                    await pipeline(ws)
                except Waiting as w:
                    print(f"waiting: {w}; next time")
                    return
        finally:
            await call(s, "POST", "/auth/revoke", {"token": tokens["refresh_token"]}, form=True)
            if problems:
                sys.exit("problems: " + "; ".join(problems))
    print("setup: all in place")


asyncio.run(main())
