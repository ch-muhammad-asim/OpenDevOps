"""Hold the dashboard's WebSockets open while idle, like a browser on /chat.

Opens the chat terminal (/api/pty), the side panel (/api/ws) and the event
stream (/api/events), sends nothing for SECONDS, then checks each socket is
still open (Hermes pings every 20 s; Cloudflare drops sockets idle > 100 s).

    HERMES_DASHBOARD_PASSWORD=... python3 ws_soak.py https://hermes.example.com [SECONDS]

Exit 0 = all stayed connected. Needs the `websockets` package.
"""
import asyncio
import http.cookiejar
import json
import os
import secrets
import sys
import time
import urllib.request

import websockets

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1").rstrip("/")
SECONDS = int(sys.argv[2]) if len(sys.argv) > 2 else 240
USER = os.environ.get("HERMES_DASHBOARD_USERNAME", "admin")
PASSWORD = os.environ["HERMES_DASHBOARD_PASSWORD"]

jar = http.cookiejar.CookieJar()
http_ = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
# Cloudflare's Browser Integrity Check rejects urllib's default User-Agent.
http_.addheaders = [("User-Agent", "hermes-ws-soak/1.0")]


def post(path, body=None):
    req = urllib.request.Request(BASE + path, data=json.dumps(body or {}).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with http_.open(req, timeout=20) as r:
        return json.load(r)


async def hold(name, path):
    ticket = post("/api/auth/ws-ticket")["ticket"]
    sep = "&" if "?" in path else "?"
    url = BASE.replace("http", "ws", 1) + f"{path}{sep}ticket={ticket}"
    start = time.monotonic()
    frames = 0
    try:
        async with websockets.connect(url, origin=BASE, max_size=None,
                                      user_agent_header="hermes-ws-soak/1.0") as ws:
            while time.monotonic() - start < SECONDS:
                try:
                    await asyncio.wait_for(ws.recv(), timeout=5)
                    frames += 1
                except asyncio.TimeoutError:
                    pass
            await ws.ping()
            return name, True, f"open after {SECONDS}s idle ({frames} frames received)"
    except Exception as e:
        return name, False, f"closed after {time.monotonic() - start:.0f}s: {type(e).__name__}: {str(e)[:120]}"


async def main():
    post("/auth/password-login", {"provider": "basic", "username": USER, "password": PASSWORD})
    channel = "chat-soak-" + secrets.token_hex(4)
    results = await asyncio.gather(
        hold("chat terminal /api/pty", f"/api/pty?channel={channel}&fresh=1&profile=default"),
        hold("side panel /api/ws", "/api/ws"),
        hold("events /api/events", f"/api/events?channel={channel}"),
    )
    ok = True
    for name, good, detail in results:
        print(f"{'PASS' if good else 'FAIL'}  {name}: {detail}")
        ok &= good
    return 0 if ok else 1


sys.exit(asyncio.run(main()))
