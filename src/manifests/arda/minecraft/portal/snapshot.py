"""Photographs each server's spawn as a player standing there sees it.

Every INTERVAL seconds, for each server in servers.json (written by
refresh.py) that knows its spawn and BlueMap map: open the server's BlueMap
in headless Chromium, in free-flight mode at spawn's position, eye height
and facing, hide BlueMap's controls, and save the view as
shots/<server>.jpg beside servers.json, where the portal shows it.
"""

import asyncio
import json
import math
import os
import time

from playwright.async_api import async_playwright

DATA = os.environ.get("DATA", "/data")
INTERVAL = int(os.environ.get("INTERVAL", "3600"))
WIDTH, HEIGHT = 960, 540
EYE = 1.62                 # a standing player's eyes, in blocks above their feet
SETTLE_MS = 6000           # after the network quietens, for the last tiles to draw

HIDE_UI = """
  #app > :not(#map-container), .zoom-buttons, .control-bar { display: none !important; }
"""


def camera(spawn):
    """BlueMap's URL camera for free flight at spawn, as BlueMap itself
    converts a player's yaw and pitch (FreeFlightControls.js)."""
    rotation = math.radians(spawn.get("yaw", 0.0) - 180)
    angle = math.radians(90 - spawn.get("pitch", 0.0))
    return f"{spawn['x'] + 0.5}:{spawn['y'] + EYE}:{spawn['z'] + 0.5}:0:{rotation:.3f}:{angle:.3f}:0:0:free"


async def shoot(browser, server, out):
    page = await browser.new_page(viewport={"width": WIDTH, "height": HEIGHT})
    try:
        url = f"{server['map_internal']}/#{server['bluemap']['id']}:{camera(server['spawn'])}"
        await page.goto(url, wait_until="networkidle", timeout=120_000)
        await page.add_style_tag(content=HIDE_UI)
        await page.wait_for_timeout(SETTLE_MS)
        await page.screenshot(path=out + ".tmp.jpg", type="jpeg", quality=82)
        os.replace(out + ".tmp.jpg", out)
        print(f"{server['name']}: {url}", flush=True)
    finally:
        await page.close()


async def round_():
    try:
        with open(f"{DATA}/servers.json") as f:
            servers = json.load(f)["servers"]
    except (OSError, ValueError) as e:
        print(f"no server list yet ({e})", flush=True)
        return False
    ready = [s for s in servers if s.get("spawn") and s.get("bluemap") and s.get("map_internal")]
    if not ready:
        return False
    os.makedirs(f"{DATA}/shots", exist_ok=True)
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"])
        try:
            for s in ready:
                try:
                    await shoot(browser, s, f"{DATA}/shots/{s['name']}.jpg")
                except Exception as e:
                    print(f"{s['name']}: {e}", flush=True)
        finally:
            await browser.close()
    return True


async def main():
    while True:
        done = await round_()
        await asyncio.sleep(INTERVAL if done else 60)


if __name__ == "__main__":
    asyncio.run(main())
