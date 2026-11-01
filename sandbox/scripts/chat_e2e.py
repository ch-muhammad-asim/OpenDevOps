"""End-to-end test of the dashboard Chat page (the /api/pty terminal).

Logs in, mints a WebSocket ticket, opens a fresh chat PTY exactly like the
browser's "Start new session", asks a sum of two random numbers and waits for
that exact answer (so no incidental terminal output can match).

By default it sends NO prompt (no model cost): it proves login, WebSocket and
PTY session start, then exits. Set LLM_CHECKS=1 to also ask the model.

Exit codes: 0 = session started (and answered, with LLM_CHECKS=1),
3 = session started but no answer, 1 = login/WebSocket/PTY failure.

    HERMES_DASHBOARD_PASSWORD=... python3 chat_e2e.py http://127.0.0.1

Needs the `websockets` package (the Hermes image has it). Exit 0 on success.
"""
import asyncio
import http.cookiejar
import json
import os
import re
import secrets
import sys
import urllib.request

import websockets

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1").rstrip("/")
USER = os.environ.get("HERMES_DASHBOARD_USERNAME", "admin")
PASSWORD = os.environ["HERMES_DASHBOARD_PASSWORD"]
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-B]")

jar = http.cookiejar.CookieJar()
http_ = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
# Cloudflare's Browser Integrity Check blocks urllib's default User-Agent
# ("Python-urllib/3.x") with "error code: 1010" (HTTP 403), so send our own.
# HTTPS/WSS work as-is: urllib and websockets verify certificates by default,
# BASE.replace("http", "ws", 1) turns https:// into wss://, and the Origin
# header (BASE) is the https:// URL the browser would send.
http_.addheaders = [("User-Agent", "hermes-chat-e2e/1.0")]


def post(path, body=None):
    req = urllib.request.Request(BASE + path, data=json.dumps(body or {}).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with http_.open(req, timeout=20) as r:
        return json.load(r)


async def main() -> int:
    post("/auth/password-login", {"provider": "basic", "username": USER, "password": PASSWORD})
    print("login: ok")
    ticket = post("/api/auth/ws-ticket")["ticket"]
    channel = "chat-e2e-" + secrets.token_hex(4)
    url = BASE.replace("http", "ws", 1) + f"/api/pty?channel={channel}&fresh=1&profile=default&ticket={ticket}"
    out = ""
    async with websockets.connect(url, origin=BASE, max_size=None) as ws:
        print("pty websocket: open")
        # Terminal resize in Hermes's own format (web_server_chat._RESIZE_RE);
        # anything else is typed into the chat and ends up in the session title.
        await ws.send("\x1b[RESIZE:120;40]")

        async def read_for(seconds, until=None):
            nonlocal out
            loop = asyncio.get_running_loop()
            end = loop.time() + seconds
            while loop.time() < end:
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=1)
                except asyncio.TimeoutError:
                    continue
                out += ANSI.sub("", msg.decode("utf-8", "replace") if isinstance(msg, bytes) else msg)
                if "out of pty devices" in out or "Chat could not start" in out:
                    return False
                if until and until(out):
                    return True
            return bool(until is None)

        if not await read_for(45, until=lambda s: len(s.strip()) > 40):
            print("FAIL: chat did not start:\n" + out[-800:])
            return 1
        print("chat session: started")
        if os.environ.get("LLM_CHECKS") != "1":
            print("no prompt sent (set LLM_CHECKS=1 to ask the model)")
            return 0
        a, b = 1000 + secrets.randbelow(8000), 1000 + secrets.randbelow(8000)
        answer = str(a + b)
        # The E2E-CHECK: prefix lets cleanup find and delete this test session.
        prompt = f"E2E-CHECK: What is {a}+{b}? Reply with only the number."
        prompt_len = len(out)
        await ws.send(prompt)
        await asyncio.sleep(0.5)
        await ws.send("\r")
        if await read_for(180, until=lambda s: answer in s[prompt_len:]):
            print(f"answer received: {answer}")
            return 0
        print("NO ANSWER: session started but the model did not reply. Last output:\n" + out[-600:])
        return 3


sys.exit(asyncio.run(main()))
