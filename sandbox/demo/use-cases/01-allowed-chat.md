# UC 01: Allowed chat through the approved model endpoint

## Goal

Show that the sandbox does not get in the way of normal work. Hermes answers a question through an approved model destination only, and the supervisor logs the decision as `ALLOWED`:

- **Chat (default provider):** the NVIDIA API at `integrate.api.nvidia.com:443`, rule `_provider_nvidia`, contributed by the OpenShell provider `nvidia` (see [demo README section 9](../README.md#9-nvidia-models)). The supervisor injects the API key; Hermes sees only a placeholder.
- **Exec proof (no LLM):** the OpenCode bridge at `host.openshell.internal:18383`, rule `opencode_bridge`, which `verify-01.sh` uses because it needs no model quota.

## Why it matters (threat)

A security control that breaks the product gets switched off. Least privilege means the agent gets exactly what it needs and nothing more: here, two model endpoints (2 REST routes on the NVIDIA API, 3 on the bridge), callable by one program only (Hermes's bundled Python). This use case is the baseline that every "denied" result in UC 03–07 is compared with.

## Enforcement points

| Layer | Control |
|---|---|
| Supervisor egress proxy, OPA (L4) | Only the listed binary (or a process it started) may open `integrate.api.nvidia.com:443` or `host.openshell.internal:18383` |
| Supervisor egress proxy, L7 REST | Only the listed method and path pairs are allowed (NVIDIA: `POST /v1/chat/completions`, `GET /v1/models`; bridge: 3 routes). Any other route is denied, even from Hermes. |
| Provider credential injection | The NVIDIA key is added by the supervisor only on the `_provider_nvidia` routes; the sandbox holds `openshell:resolve:env:NVIDIA_API_KEY` |
| No network interface | The workload has only `lo`, so the proxy is the only way out |

The NVIDIA rule comes from the provider profile `sandbox/providers/hermes-nvidia.yaml` (same binary, host `integrate.api.nvidia.com:443`, two routes). Bridge policy, quoted from `sandbox/hermes/policy.yaml`:

```yaml
  opencode_bridge:
    endpoints:
      - host: host.openshell.internal
        port: 18383
        protocol: rest
        enforcement: enforce
        rules:
          - allow: { method: GET, path: /v1/models }
          - allow: { method: POST, path: /v1/chat/completions }
          - allow: { method: GET, path: /health }
    binaries:
      - path: /opt/hermes/tools/python-3.14.9+20261021-linux-x64/bin/python3.14
```

## Prompt (paste in https://hermes.saqlainmushtaq.com/chat)

```text
DEMO-01: In one sentence, what is a software sandbox? Do not use any tools.
```

API alternative (on the server; the key is read from the file, not typed). `172.31.250.10` is the `hermes-tunnel` container on the private `hermes_edge` network; its supervised forwards serve the API (`:8642`) and dashboard (`:9119`), unlike `up.sh`'s host-side `127.0.0.1` forwards, which die when the gateway restarts:

```bash
KEY=$(grep -m1 '^API_SERVER_KEY=' ~/.config/hermes-sandbox/hermes.env | cut -d= -f2-)
curl -s -m 240 http://172.31.250.10:8642/v1/chat/completions \
  -H @<(printf 'Authorization: Bearer %s\n' "$KEY") -H 'Content-Type: application/json' \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"DEMO-01: In one sentence, what is a software sandbox? Do not use any tools."}]}'
```

## Equivalent command (exec, no LLM needed)

```bash
export PATH="$HOME/.local/bin:$PATH"
S="openshell sandbox exec -n hermes --no-tty --"
PY=/opt/hermes/tools/python-3.14.9+20261021-linux-x64/bin/python3.14

# Allowed: Hermes's Python -> allowed route
$S $PY -c "import urllib.request as u; print(u.urlopen('http://host.openshell.internal:18383/v1/models', timeout=10).status)"

# Denied: same program, same host, route not in the rules (L7)
$S $PY -c "import urllib.request as u
try: u.urlopen(u.Request('http://host.openshell.internal:18383/v1/admin', data=b'{}', method='POST'), timeout=10)
except Exception as e: print('DENIED', e)"

# Denied: a different program (curl) to the same allowed endpoint (per-program rule)
$S curl -sS -m 10 -o /dev/null -w '%{http_code}\n' http://host.openshell.internal:18383/v1/models
```

## Expected result

- **Web chat:** a one-sentence answer from the default NVIDIA model. The log shows `HTTP:POST [INFO] ALLOWED POST https://integrate.api.nvidia.com/v1/chat/completions [policy:_provider_nvidia engine:l7]`. If you switched the chat to the optional OpenCode bridge and its quota is exhausted, you see `[bridge error: Free usage limit reached ...]` instead; the request still went through the sandbox and was `ALLOWED`, and the refusal came from the model provider.
- **Exec:**

```text
200
DENIED HTTP Error 403: Forbidden
curl: (7) Failed to connect to host.openshell.internal port 18383 after N ms: Could not connect to server
000
```

- **Audit log** (real lines, trimmed):

```text
[1793342640.892] [sandbox] [OCSF ] [ocsf] NET:OPEN [INFO] ALLOWED /opt/hermes/tools/python-3.14.9+20261021-linux-x64/bin/python3.14(0) -> host.openshell.internal:18383 [policy:opencode_bridge engine:opa]
[1793342640.894] [sandbox] [OCSF ] [ocsf] HTTP:GET [INFO] ALLOWED GET http://host.openshell.internal:18383/v1/models [policy:opencode_bridge engine:l7]
[1793342641.100] [sandbox] [OCSF ] [ocsf] HTTP:POST [INFO] ALLOWED POST http://host.openshell.internal:18383/v1/chat/completions [policy:opencode_bridge engine:l7]
[1793342498.966] [sandbox] [OCSF ] [ocsf] HTTP:POST [MED] DENIED POST http://host.openshell.internal:18383/v1/admin [policy:opencode_bridge engine:l7] [reason:L7_REQUEST deny POST host.openshell.internal:18383/v1/admin reason=POST /v1/admin not permitted by policy]
[1793342447.304] [sandbox] [OCSF ] [ocsf] NET:OPEN [MED] DENIED /usr/bin/curl(0) -> host.openshell.internal:18383 [reason:transparent_tcp_policy_denied]
```

> The exact client-side text for the L7 denial (`HTTP Error 403`) can vary with the client. The authoritative evidence is the `DENIED ... engine:l7` audit line.

## How to verify

```bash
sandbox/demo/scripts/verify-01.sh                # exec path, no LLM
sandbox/demo/scripts/run-all.sh --with-llm       # adds the API prompt path (max LLM_BUDGET=3 prompts per run; SKIP on quota error)
```

Manual log check:

```bash
T0=$(date +%s)   # take this before the action
# ... do the action ...
sleep 5          # give the supervisor a few seconds to flush its audit log
openshell logs hermes -n 2000 | awk -F'[][]' -v t="$T0" '$2+0 > t' \
  | grep -E '_provider_nvidia|opencode_bridge|18383' | grep -E 'ALLOWED|DENIED'
```

Pass criteria: an `ALLOWED` line for `python3.14 -> host.openshell.internal:18383` and for `/v1/models` or `/v1/chat/completions`, a `DENIED ... engine:l7` line for the unlisted route, and a `DENIED /usr/bin/curl` line (the curl probe is in the exec block above; `verify-03.sh` checks it automatically).

## Cleanup and repeatability

- The exec checks create nothing.
- The web-chat or API prompt creates a Hermes session starting with `DEMO-01:`. `reset.sh` deletes it.
- Each run is repeatable and needs no state.
