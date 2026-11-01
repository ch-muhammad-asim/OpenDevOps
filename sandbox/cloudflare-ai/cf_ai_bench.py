#!/usr/bin/env python3
"""Test Cloudflare Workers AI text models on the free allocation.

Workers AI is free up to a daily allocation of Neurons (Cloudflare's usage
unit) on every plan. For each text-generation model in the account's
catalogue this checks, through the OpenAI-compatible endpoint:
availability (one probe), arithmetic correctness, tool calling (call +
follow-up turn with the tool result, only for models that advertise function
calling) and latency.

    python3 sandbox/cloudflare-ai/cf_ai_bench.py [--models a,b] [--rounds N]
                                                 [--out-dir DIR] [--rpm 30]

Credentials: the file named by CLOUDFLARE_AI_CREDS_FILE (default
~/Desktop/sandbox/creds/cloudflare/AI/api.txt, chmod 600) with the lines
"Account ID: <id>" and "API: <token>", or CLOUDFLARE_ACCOUNT_ID and
CLOUDFLARE_AI_TOKEN. The token is only sent in the Authorization header; the
token and the account ID are redacted from all output. Stdlib only.

Exit codes: 0 ok, 2 daily free allocation used up (partial results written),
1 other fatal error (no credentials, catalogue unreachable, unknown --models
id, unexpected error; a report is still written once testing started),
130 interrupted (Ctrl-C).
"""
import argparse
import datetime as dt
import http.client
import json
import os
import random
import re
import socket
import stat
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.cloudflare.com/client/v4/accounts/{acct}/ai"
DEFAULT_CREDS = os.path.expanduser("~/Desktop/sandbox/creds/cloudflare/AI/api.txt")
TIMEOUT = 90.0
UA = "hermes-cloudflare-ai-bench/1.0"

TOOLS = [{
    "type": "function",
    "function": {
        "name": "list_dir",
        "description": "List the files in a directory on the user's machine.",
        "parameters": {
            "type": "object",
            "properties": {"path": {"type": "string", "description": "Absolute directory path"}},
            "required": ["path"],
        },
    },
}]

_SECRETS = []


def redact(s):
    s = str(s)
    for v in _SECRETS:
        s = s.replace(v, "***")
    return s


def log(*a):
    print(redact(" ".join(str(x) for x in a)), flush=True)


def load_creds():
    acct = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "").strip()
    token = os.environ.get("CLOUDFLARE_AI_TOKEN", "").strip()
    if not (acct and token):
        path = os.environ.get("CLOUDFLARE_AI_CREDS_FILE", DEFAULT_CREDS)
        mode = stat.S_IMODE(os.stat(path).st_mode)
        if mode & 0o077:
            raise SystemExit(f"{path} must be chmod 600 (it is {mode:o})")
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                k, _, v = line.partition(":")
                k = k.strip().lower()
                if k in ("account id", "account_id", "account"):
                    acct = acct or v.strip()
                elif k in ("api", "token", "api token"):
                    token = token or v.strip()
    if not re.fullmatch(r"[0-9a-f]{32}", acct or ""):
        raise SystemExit("no valid Cloudflare account ID (32 hex characters) found")
    if not token:
        raise SystemExit("no Cloudflare API token found")
    _SECRETS.extend([token, acct])
    return acct, token


class Neurons(Exception):
    """The daily free allocation is used up."""


class Client:
    def __init__(self, acct, token, rpm):
        self.base = API.format(acct=acct)
        self._token = token
        self.interval = 60.0 / rpm if rpm > 0 else 0
        self.last = 0.0
        self.sent = 0
        self.r429 = 0

    def call(self, method, path, body=None):
        """Returns dict(ok, code, err, data, secs)."""
        for attempt in range(4):
            wait = self.last + self.interval - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            self.last = time.monotonic()
            self.sent += 1
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(self.base + path, data=data, method=method)
            req.add_header("Authorization", "Bearer " + self._token)
            req.add_header("User-Agent", UA)
            if data is not None:
                req.add_header("Content-Type", "application/json")
            t0 = time.monotonic()
            try:
                with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                    return {"ok": True, "code": resp.status, "secs": time.monotonic() - t0,
                            "data": json.loads(resp.read().decode())}
            except urllib.error.HTTPError as e:
                # Redact the whole body first, so a cut can't leave part of a secret.
                text = redact(e.read().decode("utf-8", "replace"))[:600]
                # Cloudflare error 3036 (HTTP 429): "You have used up your
                # daily free allocation of 10,000 neurons".
                if re.search(r'"code":\s*3036\b|daily free allocation', text, re.I):
                    raise Neurons(text[:200])
                if (e.code == 429 or e.code >= 500) and attempt < 3:
                    self.r429 += 1
                    time.sleep(2 ** (attempt + 1))
                    continue
                return {"ok": False, "code": e.code, "err": text}
            except (socket.timeout, TimeoutError):
                return {"ok": False, "code": None, "err": "timeout", "timeout": True}
            except urllib.error.URLError as e:
                return {"ok": False, "code": None, "err": redact(f"url error: {e.reason}")}
            except (OSError, http.client.HTTPException, ValueError) as e:
                # Dropped connections, TLS errors, a non-JSON 200 body.
                return {"ok": False, "code": None, "err": redact(f"{type(e).__name__}: {e}")}
        return {"ok": False, "code": 429, "err": "rate limited (4 tries)"}


def catalogue(cl):
    """Text-generation models: [{id, beta, function_calling, context, price}]."""
    out, page = [], 1
    while True:
        q = urllib.parse.urlencode({"task": "Text Generation", "per_page": 100, "page": page})
        r = cl.call("GET", f"/models/search?{q}")
        if not r["ok"]:
            raise SystemExit(f"catalogue failed: HTTP {r['code']} {r['err'][:200]}")
        rows = r["data"].get("result") or []
        for m in rows:
            props = {p.get("property_id"): p.get("value") for p in m.get("properties") or []}
            price = props.get("price")
            if isinstance(price, list):
                price = "; ".join(f"{p.get('price')} {p.get('unit')}" for p in price
                                  if isinstance(p, dict))
            out.append({"id": m["name"], "beta": str(props.get("beta", "")).lower() == "true",
                        "function_calling": str(props.get("function_calling", "")).lower() == "true",
                        "context": props.get("context_window"), "price": price,
                        "deprecated": bool(props.get("planned_deprecation_date"))})
        info = r["data"].get("result_info") or {}
        if len(rows) < 100 or page * 100 >= (info.get("total_count") or 0):
            break
        page += 1
    return sorted(out, key=lambda m: m["id"])


def chat(cl, model, messages, max_tokens, tools=None):
    body = {"model": model, "messages": messages, "max_tokens": max_tokens, "temperature": 0}
    if tools:
        body["tools"] = tools
    r = cl.call("POST", "/v1/chat/completions", body)
    if r["ok"]:
        msg = ((r["data"].get("choices") or [{}])[0].get("message") or {})
        r["content"] = str(msg.get("content") or "")
        r["tool_calls"] = msg.get("tool_calls") or []
        r["usage"] = r["data"].get("usage") or {}
    return r


def bench(cl, m, rounds, max_tokens):
    res = {"model": m["id"], "rounds": [], "secs": [], "errors": [], "notes": [],
           "tokens": 0, "neurons": 0.0}

    def rec(r, kind):
        if r["ok"]:
            res["secs"].append(r["secs"])
            res["tokens"] += int(r["usage"].get("total_tokens") or 0)
            res["neurons"] += float(r["usage"].get("neurons") or 0)
        else:
            res["errors"].append(f"{kind}: HTTP {r.get('code')} {(r.get('err') or '')[:100]}")

    for _ in range(rounds):
        rd = {"correct": False, "tool": None}
        a, b = random.randint(100, 9999), random.randint(100, 9999)
        r = chat(cl, m["id"], [{"role": "user", "content":
                 f"What is {a} + {b}? Reply with only the number."}], max_tokens)
        rec(r, "sum")
        if r["ok"]:
            rd["correct"] = str(a + b) in [n.replace(",", "") for n in
                                           re.findall(r"-?\d[\d,]*", r["content"])]
            if not rd["correct"]:
                res["notes"].append(f"sum: wanted {a + b}, got {r['content'][:60]!r}")
        if m["function_calling"]:
            rd["tool"] = False
            user = {"role": "user", "content": "Use the list_dir tool to list the files in "
                    "/etc/hermes, then tell me how many files there are."}
            r = chat(cl, m["id"], [user], max_tokens, TOOLS)
            rec(r, "tool")
            tc = r["tool_calls"][0] if r["ok"] and r["tool_calls"] else None
            if r["ok"] and not tc:
                res["notes"].append(f"no tool call, replied {r['content'][:60]!r}")
            if tc:
                fn = tc.get("function") or {}
                raw = fn.get("arguments") or "{}"
                try:
                    args = json.loads(raw) if isinstance(raw, str) else raw
                except ValueError:
                    args = None
                if fn.get("name") == "list_dir" and isinstance(args, dict) and \
                        isinstance(args.get("path"), str):
                    tid = tc.get("id") or "call_bench_0"
                    # Workers AI rejects `content: null` here (standard OpenAI
                    # form) with "Bad input ... 'string' not in 'null'".
                    msgs = [user,
                            {"role": "assistant", "content": "", "tool_calls": [{
                                "id": tid, "type": "function", "function": {
                                    "name": "list_dir", "arguments": json.dumps(args)}}]},
                            {"role": "tool", "tool_call_id": tid, "content": json.dumps(
                                {"files": ["config.yaml", "agents.yaml", "keys.env"]})}]
                    r = chat(cl, m["id"], msgs, max_tokens, TOOLS)
                    rec(r, "follow-up")
                    rd["tool"] = bool(r["ok"] and r["content"].strip())
                    if r["ok"] and not rd["tool"]:
                        res["notes"].append("follow-up: no final text")
                else:
                    res["notes"].append(f"bad tool call: {fn.get('name')} {str(raw)[:60]!r}")
        res["rounds"].append(rd)
        if not rd["correct"] or rd["tool"] is False:
            break
    n = len(res["rounds"]) or 1
    res["correct_rate"] = sum(r["correct"] for r in res["rounds"]) / n
    res["tool_rate"] = (None if not m["function_calling"] else
                        sum(bool(r["tool"]) for r in res["rounds"]) / n)
    res["p50"] = statistics.median(res["secs"]) if res["secs"] else None
    res["max"] = max(res["secs"]) if res["secs"] else None
    res["passed"] = (len(res["rounds"]) == rounds and res["correct_rate"] == 1
                     and res["tool_rate"] in (None, 1) and not res["errors"])
    return res


def fmt(x):
    return "-" if x is None else f"{x:.2f}"


def write_report(out_dir, stamp, state):
    os.makedirs(out_dir, exist_ok=True)
    jpath = os.path.join(out_dir, f"cloudflare-{stamp}.json")
    mpath = os.path.join(out_dir, f"cloudflare-{stamp}.md")
    with open(jpath, "w", encoding="utf-8") as fh:
        fh.write(redact(json.dumps(state, indent=2, default=str)) + "\n")
    cat = {m["id"]: m for m in state["catalogue"]}
    res = sorted(state["results"], key=lambda r: (not r["passed"],
                 r["tool_rate"] is None, r["p50"] or 1e9))
    L = [f"# Cloudflare Workers AI free-model test ({stamp})", "",
         "- Endpoint: `https://api.cloudflare.com/client/v4/accounts/<account>/ai/v1/chat/completions` "
         "(OpenAI-compatible)  ",
         f"- Started {state['started']} UTC, finished {state.get('finished')} UTC; "
         f"rounds={state['args']['rounds']}, max_tokens={state['args']['max_tokens']}, "
         f"rpm={state['args']['rpm']}  ",
         f"- Requests: {state['requests_sent']}, 429 retries: {state['r429']}, "
         f"tokens used: {sum(r['tokens'] for r in state['results'])}, Neurons used: "
         f"{sum(r['neurons'] for r in state['results']) + state.get('probe_neurons', 0):.1f} "
         f"of the 10,000 free per day (incl. {state.get('probe_neurons', 0):.1f} for probes)  ",
         f"- Run result: **{state['result']}**", "",
         "Per round: (a) random a+b, the exact number must be in the reply; (b) only for "
         "models that advertise function calling: an OpenAI `tools` call to `list_dir` "
         "with valid JSON arguments, then (c) a follow-up turn with the tool result "
         "must give a final text answer. A failed round stops that model. "
         "**Passed** = all rounds run, 100% correct, tools 100% (where supported), no errors.",
         "", f"## Models tested ({len(res)} of {len(state['catalogue'])} text-generation models)", "",
         "| Model | Passed | Rounds | Correct | Tools | Latency p50 / max s | Neurons | Beta | Notes |",
         "|---|---|---|---|---|---|---|---|---|"]
    for r in res:
        m = cat.get(r["model"], {})
        tools = "n/a" if r["tool_rate"] is None else f"{r['tool_rate'] * 100:.0f}%"
        notes = redact("; ".join(r["errors"] + r["notes"]))[:160].replace("|", "/")
        L.append(f"| `{r['model']}` | {'✅' if r['passed'] else '❌'} | {len(r['rounds'])} | "
                 f"{r['correct_rate'] * 100:.0f}% | {tools} | {fmt(r['p50'])} / {fmt(r['max'])} | "
                 f"{r['neurons']:.1f} | {'yes' if m.get('beta') else ''} | {notes} |")
    skipped = [m for m in state["catalogue"] if m.get("status") not in (None, "available")]
    if skipped:
        L += ["", "## Not tested", "", "| Model | Status |", "|---|---|"]
        L += [f"| `{m['id']}` | {redact(m['status'])[:160].replace('|', '/').replace(chr(10), ' ')} |"
          for m in skipped]
    with open(mpath, "w", encoding="utf-8") as fh:
        fh.write(redact("\n".join(L)) + "\n")
    # The reports get committed: refuse to keep one that contains a secret.
    for path in (jpath, mpath):
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        if any(v in text for v in _SECRETS):
            os.remove(path)
            raise SystemExit(f"refusing to keep {path}: it contained a credential")
    return jpath, mpath


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--models", help="comma-separated model ids (default: all text models)")
    ap.add_argument("--rounds", type=int, default=1)
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--rpm", type=float, default=30)
    ap.add_argument("--out-dir", default=os.path.join(here, "results"))
    ap.add_argument("--stamp", help="file name suffix (default: UTC date)")
    ap.add_argument("--list", action="store_true", help="only list the catalogue")
    args = ap.parse_args()
    os.umask(0o022)  # reports are not secret (redacted) and get committed
    try:
        acct, token = load_creds()
    except (OSError, SystemExit) as e:
        print(redact(f"cannot read credentials: {e}"), file=sys.stderr)
        return 1
    cl = Client(acct, token, args.rpm)
    del token
    try:
        cat = catalogue(cl)
    except (SystemExit, Neurons) as e:
        print(redact(e), file=sys.stderr)
        return 1
    log(f"catalogue: {len(cat)} text-generation models")
    if args.list:
        for m in cat:
            log(f"  {m['id']}  fc={m['function_calling']} beta={m['beta']} "
                f"ctx={m['context']} price={m['price']}")
        return 0
    wanted = [x.strip() for x in args.models.split(",")] if args.models else None
    unknown = sorted(set(wanted or []) - {m["id"] for m in cat})
    if unknown:
        print("unknown model ids: " + ", ".join(unknown), file=sys.stderr)
        return 1
    now = dt.datetime.now(dt.timezone.utc)
    stamp = args.stamp or now.strftime("%Y-%m-%d")
    # Relative out_dir: the JSON gets committed, local paths don't belong in it.
    state = {"started": now.strftime("%Y-%m-%d %H:%M:%S"),
             "args": {**vars(args), "out_dir": os.path.relpath(args.out_dir, here)},
             "catalogue": cat, "results": [], "result": "completed",
             "probe_neurons": 0.0, "probe_tokens": 0}
    code = 0
    try:
        for m in cat:
            if wanted and m["id"] not in wanted:
                m["status"] = None
                continue
            # LoRA bases need a fine-tune adapter; Llama Guard classifies, it doesn't chat.
            if not wanted and re.search(r"-lora$|llama-guard", m["id"]):
                m["status"] = "not a chat model (LoRA base or safety classifier)"
                continue
            m["status"] = "stopped mid-test"
            pr = chat(cl, m["id"], [{"role": "user", "content": "Reply with only: OK"}], 8)
            if pr["ok"]:
                state["probe_neurons"] += float(pr["usage"].get("neurons") or 0)
                state["probe_tokens"] += int(pr["usage"].get("total_tokens") or 0)
                m["status"] = "available"
            elif "not available on the Workers Free plan" in pr.get("err", ""):
                m["status"] = "paid plan only (Workers Paid)"
            elif "Model Agreement" in pr.get("err", ""):
                m["status"] = "needs a one-time licence agreement (send the prompt 'agree')"
            elif re.search(r"required properties at '/' are 'model,(fields|state)", pr.get("err", "")):
                m["status"] = "not a chat model (Cloudflare task-specific input schema)"
            else:
                m["status"] = f"probe HTTP {pr.get('code')}: {pr.get('err', '')[:140]}"
            log(f"probe {m['id']}: {m['status']}")
            if not pr["ok"]:
                continue
            m["status"] = "stopped mid-test"  # until bench() returns
            r = bench(cl, m, args.rounds, args.max_tokens)
            m["status"] = "available"
            state["results"].append(r)
            log(f"  {m['id']}: {'PASS' if r['passed'] else 'FAIL'} correct {r['correct_rate']:.0%} "
                f"tools {'n/a' if r['tool_rate'] is None else format(r['tool_rate'], '.0%')} "
                f"p50 {fmt(r['p50'])}s")
    except Neurons as e:
        code, state["result"] = 2, f"STOPPED: daily free allocation used up ({redact(e)[:160]})"
        log(state["result"])
    except KeyboardInterrupt:
        code, state["result"] = 130, "interrupted"
    except Exception as e:  # keep the partial report, whatever went wrong
        code, state["result"] = 1, redact(f"ABORTED: {e!r}")[:300]
        log(state["result"])
    if code:
        for mm in cat:
            if "status" not in mm:
                mm["status"] = "not reached (run stopped)"
    state["finished"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    state["requests_sent"], state["r429"] = cl.sent, cl.r429
    jp, mp = write_report(args.out_dir, stamp, state)
    log(f"requests sent: {cl.sent}, 429 retries: {cl.r429}\nwrote {jp}\nwrote {mp}")
    return code


if __name__ == "__main__":
    sys.exit(main())
