#!/usr/bin/env python3
"""Benchmark NVIDIA API Catalog chat models for Hermes Agent.

Hermes needs reliable OpenAI-style tool calling and low latency, so for every
chat model the key can reach this measures: availability (one probe),
arithmetic correctness, tool calling (call + follow-up turn with the tool
result) and streaming latency (time to first token, total).

    python3 sandbox/scripts/nvidia_bench.py [--models a,b] [--requests N]
                                            [--out-dir DIR] [--rpm 30]

Key: read from the file named by NVIDIA_API_KEY_FILE (default
~/Desktop/sandbox/creds/nvidia/api, one line "API: nvapi-...") or
from NVIDIA_API_KEY. It is only ever sent in the Authorization header and is
redacted (any "nvapi-..." string) from all output. Stdlib only.

Two-step workflow:
  1. Screening (default --requests 1): every chat model gets 1 probe + 1 round
     (correctness, tool call, tool follow-up) = at most 4 requests per model.
  2. Confirmation of the top 3 qualified models (5 rounds, <= 16 requests each),
     merged into the screening report; the recommendation then uses ONLY the
     confirmed results:
       python3 sandbox/scripts/nvidia_bench.py --models a,b,c --requests 5 \
           --confirm-of sandbox/benchmarks/nvidia-<date>.json
     --confirm-of may be repeated (e.g. for a promoted candidate); later runs
     replace earlier confirmation results for the same model.
A model that fails or errors in a round gets no further rounds.

Exit codes: 0 ok, 2 quota/credit exhaustion (partial results written),
1 other fatal error (e.g. no key, catalogue unreachable).
"""
import argparse
import datetime as dt
import json
import os
import random
import re
import socket
import statistics
import sys
import time
import urllib.error
import urllib.request

BASE = "https://integrate.api.nvidia.com/v1"
DEFAULT_KEY_FILE = os.path.expanduser("~/Desktop/sandbox/creds/nvidia/api")
CONNECT_TIMEOUT = 30.0  # connect / first byte / per-read
TOTAL_TIMEOUT = 90.0
UA = "hermes-nvidia-bench/1.0"
REDACT = re.compile(r"nvapi-[A-Za-z0-9_\-]+")
# NVIDIA error bodies name the account ("... Not found for account 'xyz'").
ACCOUNT = re.compile(r"account '[^']+'")

NON_CHAT = [
    ("embedding", r"embed|nv-?clip|\bclip\b|arctic-embed|bge-|e5-|colbert"),
    ("rerank", r"rerank"),
    ("retriever", r"retriev"),
    ("guard/safety", r"guard|safety|nemoguard|shieldgemma|jailbreak|topic-control|pii"),
    ("parse/ocr", r"parse|ocr|nemoretriever-page|table-structure|graphic-element"),
    ("vision-only", r"detector|grounding-dino|dino|segformer|deplot|"
                    r"florence|paligemma|kosmos|fuyu|neva|vila|streampetr|"
                    r"changenet|ocdrnet|visual-changenet|retinanet|yolo"),
    ("translate", r"translat|riva-translate|madlad"),
    ("reward", r"reward"),
    ("speech/audio", r"whisper|parakeet|canary|asr|tts|fastpitch|magpie|audio2face|riva"),
    ("image-gen", r"sdxl|stable-diffusion|flux|edify|bria|consistory|sana"),
    ("bio/science", r"esm|diffdock|molmim|genmol|alphafold|openfold|evo2|proteinmt|"
                    r"rfdiffusion|boltz|msa-search|corrdiff|fourcastnet"),
]

TOOLS = [{
    "type": "function",
    "function": {
        "name": "list_dir",
        "description": "List the files in a directory on the user's machine.",
        "parameters": {
            "type": "object",
            "properties": {"path": {"type": "string",
                                    "description": "Absolute directory path"}},
            "required": ["path"],
        },
    },
}]


def redact(s):
    return ACCOUNT.sub("account '***'", REDACT.sub("nvapi-***REDACTED***", str(s)))


def log(*a):
    print(redact(" ".join(str(x) for x in a)), flush=True)


def load_key():
    key = os.environ.get("NVIDIA_API_KEY", "").strip()
    if key:
        return key
    path = os.environ.get("NVIDIA_API_KEY_FILE", DEFAULT_KEY_FILE)
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.upper().startswith("API:"):
                line = line[4:].strip()
            return line
    raise SystemExit("no key found in key file")


class QuotaExhausted(Exception):
    pass


class Client:
    def __init__(self, key, rpm):
        self._key = key
        self.interval = 60.0 / rpm if rpm > 0 else 0
        self.last = 0.0
        self.sent = 0
        self.r429 = 0
        self.events = []  # rate-limit / quota events

    def _pace(self):
        wait = self.last + self.interval - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        self.last = time.monotonic()

    def _req(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(BASE + path, data=data, method=method)
        r.add_header("Authorization", "Bearer " + self._key)
        r.add_header("User-Agent", UA)
        r.add_header("Accept", "text/event-stream" if body and body.get("stream")
                     else "application/json")
        if data is not None:
            r.add_header("Content-Type", "application/json")
        return r

    @staticmethod
    def _is_quota(code, text):
        t = text.lower()
        if code == 402:
            return True
        if code in (403, 429) and re.search(
                r"credit|quota|insufficient|exhausted|billing|limit exceeded|"
                r"monthly|out of", t):
            # plain "rate limit exceeded" on 429 is a rate limit, not quota
            if code == 429 and re.search(r"rate.?limit|too many requests", t) and \
                    not re.search(r"credit|quota|billing", t):
                return False
            return True
        return False

    def call(self, method, path, body=None, model=None):
        """Returns dict(ok, code, err, data|stream fields, r429, timeout)."""
        retries, r429, quota_hits = 0, 0, 0
        while True:
            self._pace()
            self.sent += 1
            t0 = time.monotonic()
            try:
                resp = urllib.request.urlopen(self._req(method, path, body),
                                              timeout=CONNECT_TIMEOUT)
            except urllib.error.HTTPError as e:
                text = redact(e.read().decode("utf-8", "replace")[:600])
                if self._is_quota(e.code, text):
                    quota_hits += 1
                    self.events.append({"model": model, "code": e.code,
                                        "kind": "quota", "body": text[:300]})
                    if e.code == 402 or quota_hits >= 2:
                        raise QuotaExhausted(f"HTTP {e.code} on {model or path}: {text[:200]}")
                    time.sleep(5)
                    continue
                if e.code == 429:
                    self.r429 += 1
                    r429 += 1
                    self.events.append({"model": model, "code": 429,
                                        "kind": "rate-limit", "retry": retries + 1})
                    if retries < 4:
                        time.sleep(2 ** (retries + 1))
                        retries += 1
                        continue
                return {"ok": False, "code": e.code, "err": text, "r429": r429,
                        "timeout": False}
            except (socket.timeout, TimeoutError) as e:
                return {"ok": False, "code": None, "err": f"timeout: {e}",
                        "r429": r429, "timeout": True}
            except urllib.error.URLError as e:
                to = isinstance(e.reason, (socket.timeout, TimeoutError))
                return {"ok": False, "code": None, "err": redact(f"url error: {e.reason}"),
                        "r429": r429, "timeout": to}
            with resp:
                if body and body.get("stream"):
                    out = self._read_stream(resp, t0)
                else:
                    try:
                        out = {"ok": True, "code": resp.status,
                               "data": json.loads(resp.read().decode())}
                    except (socket.timeout, TimeoutError):
                        out = {"ok": False, "code": resp.status, "err": "timeout reading",
                               "timeout": True}
            out["r429"] = r429
            out.setdefault("timeout", False)
            return out

    @staticmethod
    def _read_stream(resp, t0):
        content, reasoning, tcalls = [], [], {}
        ttft, finish, err = None, None, None
        try:
            for raw in resp:
                if time.monotonic() - t0 > TOTAL_TIMEOUT:
                    return {"ok": False, "code": resp.status, "err": "total timeout",
                            "timeout": True}
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    ev = json.loads(payload)
                except ValueError:
                    continue
                if "error" in ev and not ev.get("choices"):
                    err = redact(json.dumps(ev["error"])[:300])
                    continue
                for ch in ev.get("choices") or []:
                    d = ch.get("delta") or {}
                    if ch.get("finish_reason"):
                        finish = ch["finish_reason"]
                    if d.get("content"):
                        content.append(d["content"])
                        ttft = ttft or time.monotonic() - t0
                    rc = d.get("reasoning_content") or d.get("reasoning")
                    if rc:
                        reasoning.append(rc)
                    for tc in d.get("tool_calls") or []:
                        ttft = ttft or time.monotonic() - t0
                        idx = tc.get("index", 0)
                        slot = tcalls.setdefault(idx, {"id": None, "name": "", "args": ""})
                        if tc.get("id"):
                            slot["id"] = tc["id"]
                        fn = tc.get("function") or {}
                        if fn.get("name"):
                            slot["name"] += fn["name"]
                        if fn.get("arguments"):
                            slot["args"] += fn["arguments"] if isinstance(
                                fn["arguments"], str) else json.dumps(fn["arguments"])
        except (socket.timeout, TimeoutError):
            return {"ok": False, "code": resp.status, "err": "stream read timeout",
                    "timeout": True}
        total = time.monotonic() - t0
        if total > TOTAL_TIMEOUT:
            return {"ok": False, "code": resp.status, "err": "total timeout", "timeout": True}
        return {"ok": err is None, "code": resp.status, "err": err,
                "content": "".join(content), "reasoning_chars": len("".join(reasoning)),
                "tool_calls": [tcalls[k] for k in sorted(tcalls)],
                "finish": finish, "ttft": ttft, "total": total}


def classify(mid):
    m = mid.lower()
    for label, pat in NON_CHAT:
        if re.search(pat, m):
            return label
    return None


def probe_status(r):
    if r["ok"]:
        return "available", None
    if r.get("timeout"):
        return "timeout", r["err"]
    err = r.get("err") or ""
    if r["code"] == 410:
        m = re.search(r"(\d{4}-\d{2}-\d{2}|[A-Z][a-z]+ \d{1,2},? \d{4})", err)
        return "retired", ("EOL " + m.group(1)) if m else err[:160]
    if r["code"] == 404 and re.search(r"not found for account|function", err, re.I):
        return "not-enabled", err[:160]
    return "error", f"HTTP {r['code']}: {err[:160]}"


def chat(cl, model, messages, max_tokens, tools=None):
    body = {"model": model, "messages": messages, "max_tokens": max_tokens,
            "temperature": 0, "stream": True}
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"
    return cl.call("POST", "/chat/completions", body, model=model)


def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    k = (len(xs) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def bench_model(cl, model, rounds, max_tokens):
    res = {"model": model, "rounds": [], "ttft": [], "total": [], "errors": 0,
           "timeouts": 0, "r429": 0, "notes": set(), "requests": 0}

    def rec(r, kind):
        res["requests"] += 1
        res["r429"] += r.get("r429", 0)
        if r.get("timeout"):
            res["timeouts"] += 1
            res["notes"].add(f"{kind} timeout")
        elif not r["ok"]:
            res["errors"] += 1
            res["notes"].add(f"{kind} err {r.get('code')}: {(r.get('err') or '')[:80]}")
        else:
            if r.get("ttft") is not None:
                res["ttft"].append(r["ttft"])
            res["total"].append(r["total"])
            if not r["content"].strip() and not r["tool_calls"] and r["reasoning_chars"]:
                res["notes"].add(f"{kind}: empty content, tokens spent on reasoning")

    for i in range(rounds):
        rd = {"correct": False, "tool_call": False, "follow_up": False}
        # (a) correctness
        a, b = random.randint(100, 9999), random.randint(100, 9999)
        r = chat(cl, model, [{"role": "user", "content":
                 f"What is {a} + {b}? Reply with only the number."}], max_tokens)
        rec(r, "sum")
        if r["ok"]:
            nums = re.findall(r"-?\d[\d,]*", r["content"])
            rd["correct"] = str(a + b) in [n.replace(",", "") for n in nums]
        # (b) tool call
        user = {"role": "user", "content":
                "Use the list_dir tool to list the files in /etc/hermes, then tell me "
                "how many files there are."}
        r = chat(cl, model, [user], max_tokens, TOOLS)
        rec(r, "tool")
        tc = None
        if r["ok"] and r["tool_calls"]:
            tc = r["tool_calls"][0]
            try:
                args = json.loads(tc["args"] or "{}")
                rd["tool_call"] = tc["name"] == "list_dir" and isinstance(args, dict) \
                    and isinstance(args.get("path"), str)
            except ValueError:
                res["notes"].add("tool args not valid JSON")
        elif r["ok"]:
            res["notes"].add("no tool_call returned")
        # (c) follow-up with tool result
        if rd["tool_call"]:
            tid = tc["id"] or "call_bench_0"
            msgs = [user,
                    {"role": "assistant", "content": None, "tool_calls": [{
                        "id": tid, "type": "function",
                        "function": {"name": "list_dir", "arguments": tc["args"]}}]},
                    {"role": "tool", "tool_call_id": tid,
                     "content": json.dumps({"files": ["config.yaml", "agents.yaml", "keys.env"]})}]
            r = chat(cl, model, msgs, max_tokens, TOOLS)
            rec(r, "follow-up")
            if r["ok"]:
                txt = r["content"].strip()
                rd["follow_up"] = bool(txt)
                if not txt:
                    res["notes"].add("follow-up: no final text"
                                     + (" (another tool call)" if r["tool_calls"] else ""))
        res["rounds"].append(rd)
        if not (rd["correct"] and rd["tool_call"] and rd["follow_up"]):
            if i + 1 < rounds:
                res["notes"].add(f"stopped after round {i + 1} (failure)")
            break
    return finalize(res, rounds)


def finalize(res, rounds_wanted):
    n = len(res["rounds"]) or 1
    res["correct_rate"] = sum(r["correct"] for r in res["rounds"]) / n
    res["tool_rate"] = sum(r["tool_call"] and r["follow_up"] for r in res["rounds"]) / n
    res["tool_call_only_rate"] = sum(r["tool_call"] for r in res["rounds"]) / n
    for k in ("ttft", "total"):
        res[k + "_p50"] = pct(res[k], 50)
        res[k + "_p95"] = pct(res[k], 95)
    res["qualified"] = (len(res["rounds"]) == rounds_wanted and res["correct_rate"] == 1
                        and res["tool_rate"] == 1 and res["errors"] == 0
                        and res["timeouts"] == 0)
    res["notes"] = sorted(res["notes"])
    return res


def family(mid):
    name = mid.split("/")[-1].lower()
    for fam in ("llama", "nemotron", "mistral", "mixtral", "codestral", "qwen", "deepseek",
                "gemma", "phi", "kimi", "glm", "gpt-oss", "granite", "jamba", "minimax",
                "seed", "falcon", "yi", "baichuan", "solar", "dbrx", "arctic"):
        if fam in name:
            return fam
    return mid.split("/")[0]


def rank(results, demoted=()):
    q = [r for r in results if r["qualified"] and r["model"] not in demoted]
    q.sort(key=lambda r: (r["total_p95"] or 1e9, r["ttft_p95"] or 1e9))
    picks, fams = [], set()
    for r in q:
        if family(r["model"]) not in fams:
            picks.append(r)
            fams.add(family(r["model"]))
        if len(picks) == 3:
            break
    for r in q:  # fill if fewer than 3 families
        if len(picks) == 3:
            break
        if r not in picks:
            picks.append(r)
    return q, picks


def f(x, nd=2):
    return "-" if x is None else f"{x:.{nd}f}"


def row(r):
    return (f"| `{r['model']}` | {r.get('status', 'available')} | "
            f"{len(r['rounds'])} | {r['correct_rate'] * 100:.0f}% | "
            f"{r['tool_rate'] * 100:.0f}% ({r['tool_call_only_rate'] * 100:.0f}% call) | "
            f"{f(r['ttft_p50'])} / {f(r['ttft_p95'])} | {f(r['total_p50'])} / {f(r['total_p95'])} | "
            f"{r['errors']}/{r['timeouts']} | {r['r429']} | "
            f"{redact('; '.join(r['notes']))[:200].replace('|', '/')} |")


HDR = ("| Model | Status | Rounds | Correct | Tool call+follow-up | TTFT p50/p95 s | "
       "Total p50/p95 s | Err/TO | 429s | Notes |\n|---|---|---|---|---|---|---|---|---|---|")


def write_report(out_dir, stamp, state, exit_reason):
    os.makedirs(out_dir, exist_ok=True)
    jpath = os.path.join(out_dir, f"nvidia-{stamp}.json")
    mpath = os.path.join(out_dir, f"nvidia-{stamp}.md")
    with open(jpath, "w", encoding="utf-8") as fh:
        fh.write(redact(json.dumps(state, indent=2, default=str)))
    results = state["results"]
    conf = state.get("confirmation")
    demoted = {}
    if conf:
        cres = {r["model"]: r for r in conf["results"]}
        for p in conf.get("probes", []):
            r = cres.get(p["id"])
            if p["status"] != "available":
                demoted[p["id"]] = f"confirmation probe {p['status']}: {p.get('detail') or ''}"
            elif r and not r["qualified"]:
                demoted[p["id"]] = "failed confirmation rounds"
    ranked, _ = rank(results, demoted)
    if conf:
        _, picks = rank([r for r in conf["results"]
                         if len(r["rounds"]) == conf["args"]["requests"]], demoted)
    else:
        picks = ranked and rank(results, demoted)[1]
    rank_idx = {r["model"]: i for i, r in enumerate(ranked)}
    ordered = sorted(results, key=lambda r: (rank_idx.get(r["model"], 1e6),
                                             -(r["correct_rate"] + r["tool_rate"]),
                                             r["total_p95"] or 1e9))
    L = [f"# NVIDIA API Catalog benchmark for Hermes Agent ({stamp})", "",
         f"- Base URL: `{BASE}`  ",
         f"- Started: {state['started']} UTC, finished: {state.get('finished')} UTC  ",
         f"- Settings: rounds={state['args']['requests']}, rpm={state['args']['rpm']}, "
         f"max_tokens={state['args']['max_tokens']}, timeouts {CONNECT_TIMEOUT:.0f}s first "
         f"token / {TOTAL_TIMEOUT:.0f}s total, streaming SSE  ",
         f"- Requests sent: {state['requests_sent']}; HTTP 429 retries: {state['r429']}; "
         f"quota events: {sum(1 for e in state['events'] if e['kind'] == 'quota')}  ",
         f"- Run result: **{exit_reason}**", "",
         "Tests per round: (a) random a+b, exact number in reply; (b) OpenAI `tools` "
         "`list_dir` call with valid JSON args; (c) follow-up turn with role `tool` "
         "result must produce a final text answer. A model failing a round gets no "
         "further rounds. Qualified = all rounds run, 100% correct, 100% tool "
         "call+follow-up, 0 errors/timeouts; ranked by total-latency p95.", "",
         "## Catalogue", ""]
    counts = {}
    for m in state["catalogue"]:
        counts[m["status"]] = counts.get(m["status"], 0) + 1
    L.append(f"{len(state['catalogue'])} model ids. " +
             ", ".join(f"{k}: {v}" for k, v in sorted(counts.items())))
    L += ["", "## Recommendation", ""]
    if picks:
        for lbl, r in zip(("Best", "Fallback 1", "Fallback 2"), picks):
            L.append(f"- **{lbl}: `{r['model']}`** — total p50/p95 {f(r['total_p50'])}/"
                     f"{f(r['total_p95'])} s, TTFT p50/p95 {f(r['ttft_p50'])}/"
                     f"{f(r['ttft_p95'])} s, {len(r['rounds'])} rounds all passed"
                     + (" (stability-confirmed)" if conf else ""))
    else:
        L.append("No model met the qualification bar.")
    for m, why in demoted.items():
        L.append(f"- Demoted `{m}` (qualified in main run): {redact(why)[:160]}")
    if state.get("confirmation"):
        c = state["confirmation"]
        L += ["", f"## Stability confirmation ({c['args']['requests']} rounds, top candidates)",
              "", "Source: " + ", ".join(f"`{x}`" for x in c.get("files", [c.get("file")]))
              + f"; confirmation requests: {c['requests_sent']}, 429s: {c['r429']}  ",
              "When present, the recommendation uses ONLY these confirmed results.", "", HDR]
        L += [row(r) for r in c["results"]]
        for p in c.get("probes", []):
            if p["status"] != "available":
                L.append(f"| `{p['id']}` | {p['status']} | 0 | - | - | - | - | probe failed | - | "
                         f"{redact(p.get('detail') or '')[:120].replace('|', '/')} |")
    L += ["", "## Chat models tested (ranked)", "", HDR] + [row(r) for r in ordered]
    L += ["", "## Not tested: retired / unavailable / errors", "",
          "| Model | Status | Detail |", "|---|---|---|"]
    for m in state["catalogue"]:
        if m["status"] not in ("available", "non-chat", "skipped"):
            L.append(f"| `{m['id']}` | {m['status']} | "
                     f"{redact(m.get('detail') or '')[:160].replace('|', '/')} |")
    L += ["", "## Non-chat models (excluded by name)", "", "| Model | Class |", "|---|---|"]
    for m in state["catalogue"]:
        if m["status"] == "non-chat":
            L.append(f"| `{m['id']}` | {m['detail']} |")
    if state["events"]:
        L += ["", "## Rate-limit / quota events", ""]
        L += [f"- {redact(json.dumps(e))[:300]}" for e in state["events"]]
    with open(mpath, "w", encoding="utf-8") as fh:
        fh.write(redact("\n".join(L) + "\n"))
    return jpath, mpath


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--models", help="comma-separated model ids (skip catalogue scan of others)")
    ap.add_argument("--requests", type=int, default=1,
                    help="rounds per model (default 1 = screening, ~4 requests/model)")
    ap.add_argument("--out-dir", default="sandbox/benchmarks")
    ap.add_argument("--rpm", type=float, default=30)
    ap.add_argument("--max-tokens", type=int, default=300)
    ap.add_argument("--stamp", help="file name suffix (default UTC date)")
    ap.add_argument("--confirm-of", help="(internal) merge this run as stability "
                    "confirmation into an existing results JSON and rewrite its report")
    args = ap.parse_args()
    os.umask(0o077)

    try:
        key = load_key()
    except (OSError, SystemExit) as e:
        print(redact(f"cannot read key: {e}"), file=sys.stderr)
        return 1
    cl = Client(key, args.rpm)
    del key
    now = dt.datetime.now(dt.timezone.utc)
    stamp = args.stamp or now.strftime("%Y-%m-%d")
    state = {"started": now.strftime("%Y-%m-%d %H:%M:%S"), "args": vars(args),
             "catalogue": [], "results": [], "events": cl.events,
             "requests_sent": 0, "r429": 0}

    r = cl.call("GET", "/models")
    if not r["ok"]:
        print(redact(f"catalogue failed: HTTP {r['code']} {r['err']}"), file=sys.stderr)
        return 1
    ids = sorted({m["id"] for m in r["data"].get("data", [])})
    wanted = [m.strip() for m in args.models.split(",")] if args.models else None
    log(f"catalogue: {len(ids)} models")
    exit_code, reason = 0, "completed"
    try:
        for mid in ids + [m for m in (wanted or []) if m not in ids]:
            entry = {"id": mid}
            state["catalogue"].append(entry)
            cls = classify(mid)
            if wanted is not None and mid not in wanted:
                entry.update(status="non-chat" if cls else "skipped", detail=cls)
                continue
            if cls and wanted is None:
                entry.update(status="non-chat", detail=cls)
                continue
            pr = chat(cl, mid, [{"role": "user", "content": "Reply with only: OK"}], 8)
            st, det = probe_status(pr)
            entry.update(status=st, detail=det)
            log(f"probe {mid}: {st}" + (f" ({det[:100]})" if det else ""))
            if st != "available":
                continue
            res = bench_model(cl, mid, args.requests, args.max_tokens)
            res["requests"] += 1  # probe
            state["results"].append(res)
            log(f"  {mid}: correct {res['correct_rate']:.0%} tool {res['tool_rate']:.0%} "
                f"total p95 {f(res['total_p95'])}s err {res['errors']} to {res['timeouts']}")
    except QuotaExhausted as e:
        exit_code, reason = 2, f"STOPPED: quota/credit exhaustion ({redact(e)[:200]})"
        log(reason)
    except KeyboardInterrupt:
        exit_code, reason = 130, "interrupted"
    state["finished"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    state["requests_sent"], state["r429"] = cl.sent, cl.r429

    if args.confirm_of:
        with open(args.confirm_of, encoding="utf-8") as fh:
            base = json.load(fh)
        cpath, n = args.confirm_of.replace(".json", "-confirm.json"), 1
        while os.path.exists(cpath):
            n += 1
            cpath = args.confirm_of.replace(".json", f"-confirm-{n}.json")
        with open(cpath, "w", encoding="utf-8") as fh:
            fh.write(redact(json.dumps(state, indent=2, default=str)))
        probes = [m for m in state["catalogue"] if m["status"] not in ("skipped", "non-chat")]
        old = base.get("confirmation") or {"files": [], "results": [], "probes": [],
                                           "requests_sent": 0, "r429": 0, "events": []}
        if "files" not in old:  # older single-run layout
            old["files"] = [old.pop("file")]
        new_ids = {p["id"] for p in probes}
        base["confirmation"] = {
            "files": old["files"] + [os.path.basename(cpath)], "args": state["args"],
            "results": [r for r in old["results"] if r["model"] not in new_ids]
            + state["results"],
            "probes": [p for p in old["probes"] if p["id"] not in new_ids] + probes,
            "requests_sent": old["requests_sent"] + cl.sent,
            "r429": old["r429"] + cl.r429, "events": old["events"] + cl.events,
            "reason": reason}
        base["requests_sent_incl_confirmation"] = (base["requests_sent"]
                                                   + base["confirmation"]["requests_sent"])
        out_dir = os.path.dirname(args.confirm_of)
        stamp = os.path.basename(args.confirm_of)[len("nvidia-"):-len(".json")]
        jp, mp = write_report(out_dir, stamp, base, base.get("exit_reason", "completed"))
    else:
        state["exit_reason"] = reason
        jp, mp = write_report(args.out_dir, stamp, state, reason)
    log(f"requests sent: {cl.sent}, 429s: {cl.r429}")
    log(f"wrote {jp}\nwrote {mp}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
