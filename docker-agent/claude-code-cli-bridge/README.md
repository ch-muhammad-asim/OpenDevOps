# 🌉 Claude Code CLI bridge for Docker Agent

> The model backend for this repo's Docker Agent. It wraps the **pre-authenticated Claude Code CLI** in an **OpenAI-compatible API**, and the agent talks to it like any model provider. It runs **next to the agent**: as a second service in **Docker Compose**, or as a **sidecar container in the same Kubernetes Pod**. No bridge on your Mac, no Anthropic API key.

```text
                         ┌──────────────── Docker Compose (network "oda") or one Kubernetes Pod ────────────────┐
you ─curl + AGENT_API_KEY─▶ 🤖 agent (docker-agent serve api)  ─Bearer CLAUDE_BRIDGE_API_KEY─▶ 🌉 claude-code-cli-bridge │
   127.0.0.1:8090 (Compose)    sessions · memory · tools                                        claude CLI (haiku)       │
   127.0.0.1:8091 (k8s)                                                                          │ CLAUDE_CODE_OAUTH_TOKEN│
                         └───────────────────────────────────────────────────────────────────────┼───────────────────────┘
                                                                                                 ▼
                                                                                    Anthropic (your Claude subscription)
```

---

## 📑 Contents

1. [What's in this folder](#-whats-in-this-folder)
2. [How it works](#-how-it-works)
3. [One-time setup: three secrets in the Keychain](#-one-time-setup-three-secrets-in-the-keychain)
4. [🐳 Docker Compose: run and call it](#-docker-compose-run-and-call-it)
5. [☸️ Kubernetes (one Pod, two containers): run and call it](#%EF%B8%8F-kubernetes-one-pod-two-containers-run-and-call-it)
6. [📡 API reference with curl](#-api-reference-with-curl)
7. [🔒 Security controls](#-security-controls)
8. [🧪 Tested results](#-tested-results)
9. [🩺 Troubleshooting](#-troubleshooting)

---

## 📁 What's in this folder

| File | What it is |
|---|---|
| `claude_native_bridge.py` | The bridge (from [`pi-agents/macos/claude-code/native/`](../../pi-agents/macos/claude-code/native/)) with **four small patches**, described below |
| `mcp_shim.py` | Unchanged. It exposes the agent's tools (Kubernetes, memory, …) to Claude as real functions |
| `managed-settings.json` | Claude Code policy baked into the image: **43 built-in tools denied** (Bash, Read, Write, Edit, WebFetch, WebSearch, Task, …), hooks disabled |
| `Dockerfile` | `distroless/python3` (glibc + Python 3.11) + the sha256-pinned `claude` CLI **2.1.302** + the bridge. Non-root 65532 |

**🩹 The patches** (each marked `docker-agent hardening` or `docker-agent sidecar` in the code).
1. **Keep the auth token.** Upstream, the bridge strips every `CLAUDE_CODE_*` variable before it starts `claude`. Inside a container, that would also strip `CLAUDE_CODE_OAUTH_TOKEN`, the only credential the CLI has. The copy here keeps **exactly that one variable**; the bridge's own settings (e.g. `CLAUDE_CODE_BRIDGE_API_KEY`) are still stripped. Diff: +3 / −1 lines (`_SCRUB_ENV_KEEP`).
2. **Refuse to start without `CLAUDE_CODE_BRIDGE_API_KEY`.** An empty key would let anyone use your Claude subscription. `BRIDGE_ALLOW_NO_AUTH=1` overrides this, for local experiments only.
3. **Only the models in `--models` are accepted** (here `claude-haiku-4-5`). Upstream accepts any `claude-*` id.
4. **Hard session cap.** At `--max-sessions` with every session busy, it returns **HTTP 503** instead of spawning more `claude` processes.

> ℹ️ **Known upstream behaviour (unchanged):** a conversation is matched to a warm session by its message history. A request with identical history but a *different* system prompt could reuse that session. Here every request comes from one agent with one fixed instruction, so this can't mix contexts.

**🐳 Image:** `quickbooks2018/opendevops-agent-runtime:bridge` (plus `bridge-sha-<7>`). Built, smoke-tested and scanned by [CI](../../.github/workflows/docker-agent.yml), never locally.

---

## 🧭 How it works

1. **You** call the agent with `Authorization: Bearer $AGENT_API_KEY`.
2. **docker-agent** runs the agent. Its `claude-bridge` provider points at the bridge:
   - **Compose:** `--flavor compose` → `http://claude-code-cli-bridge:18188/v1`.
   - **Kubernetes:** `--flavor in-pod` → `http://127.0.0.1:18188/v1`, the shared Pod network.
   - It authenticates to the bridge with `token_key: CLAUDE_BRIDGE_API_KEY`.
3. **The bridge** checks that key, then keeps one warm `claude -p --model claude-haiku-4-5` process per conversation.
   - The agent's tools reach Claude through the MCP shim, and Claude's tool calls go back to docker-agent, which runs them.
   - Claude Code's own tools are kept away from the work in two ways:
     - `--permission-mode default --allowedTools mcp__host`: only the agent's tools are pre-approved, and any other tool would need an interactive approval that a headless `claude -p` can't get.
     - The image's managed settings explicitly **deny 43 built-in tools** (Bash, Read, Write, Edit, WebFetch, WebSearch, Task, …).
   - **Intended exception: `ToolSearch` stays available,** because Claude uses it to load the agent's own tool definitions when they're deferred. It can only *find* tools; it can't run them.
4. **The `claude` CLI** is already authenticated through `CLAUDE_CODE_OAUTH_TOKEN`, a long-lived token from `claude setup-token`. There is no login inside the container.

> ❓ **Why not mount `~/.claude`?** On macOS, Claude Code keeps its login in the **Keychain**, not in `~/.claude` (there's no `.credentials.json`). A Linux container can't read the macOS Keychain. The OAuth token is the supported way to hand a container a pre-authenticated Claude login.

---

## 🔑 One-time setup: three secrets in the Keychain

| Keychain item | Becomes | Purpose |
|---|---|---|
| `oda-agent-api-key` | `AGENT_API_KEY` | **You → agent**. Every API call needs it |
| `oda-claude-bridge-key` | `CLAUDE_BRIDGE_API_KEY` | **Agent → bridge**. Nothing else can use the bridge |
| `oda-claude-oauth-token` | `CLAUDE_CODE_OAUTH_TOKEN` | **Bridge → Anthropic**. Your pre-authenticated Claude login |

```bash
# random keys (skip any that already exist)
security add-generic-password -U -a "$USER" -s oda-agent-api-key     -w "$(openssl rand -hex 24)"
security add-generic-password -U -a "$USER" -s oda-claude-bridge-key -w "$(openssl rand -hex 24)"

# your Claude token: run `claude setup-token` once (on any machine), then paste it at the prompt (no -w value = not in argv/history)
security add-generic-password -U -a "$USER" -s oda-claude-oauth-token -w
```

> 💡 Already have the token in a file? Open it, copy it, paste it at the same `-w` prompt (passing it as `-w "$(cat …)"` would put the full token in the process arguments), then delete the file.

**Every new terminal**, load all three. It fails loudly if any is missing:

```bash
for pair in AGENT_API_KEY:oda-agent-api-key CLAUDE_BRIDGE_API_KEY:oda-claude-bridge-key CLAUDE_CODE_OAUTH_TOKEN:oda-claude-oauth-token; do
  var=${pair%%:*}; item=${pair#*:}
  val=$(security find-generic-password -a "$USER" -s "$item" -w 2>/dev/null)
  if [ -n "$val" ]; then export "$var=$val"; echo "🔑 $var loaded"; else echo "❌ $item missing in the Keychain"; fi
done
unset val
```

---

## 🐳 Docker Compose: run and call it

```bash
cd OpenDevOps/docker-agent
docker compose up -d
docker compose ps        # agent → 127.0.0.1:8090->8080/tcp · claude-code-cli-bridge → 18188/tcp (internal only)

# wait until the API answers (a curl right after `up` returns 000 while it starts)
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8090/health)
  if [ "$code" = 200 ]; then echo "✅ ready after ${i}s"; break; fi
  sleep 1
done
```

Then use the [API reference](#-api-reference-with-curl) with `A=http://localhost:8090` and agent name **`agent`**.

**Logs and teardown.** Every `docker compose` command re-reads `compose.yaml` and needs the three variables loaded. Without them, use plain `docker`:

```bash
docker logs oda-agent-1 --tail 20
docker logs oda-claude-code-cli-bridge-1 --tail 20     # shows each POST and "turn done in …s"
docker compose down          # keep sessions (volume oda-data)
docker compose down -v       # also delete sessions
```

---

## ☸️ Kubernetes (one Pod, two containers): run and call it

Uses [`../kubernetes/`](../kubernetes/) on OrbStack Kubernetes (`orb start k8s`). The Pod runs `agent` (the read-only **SRE agent**, `agent-sre.yaml`) and the `claude-code-cli-bridge` sidecar.

```bash
cd OpenDevOps/docker-agent

# 1. lab (two broken workloads) + read-only identity for the agent
kubectl --context orbstack apply -f k8s-lab/demo-broken.yaml -f k8s-lab/rbac-readonly.yaml

# 2. one Secret with all three values (process substitution keeps them out of kubectl's argv)
if [ -z "${AGENT_API_KEY:-}" ] || [ -z "${CLAUDE_BRIDGE_API_KEY:-}" ] || [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "❌ load the three Keychain secrets first"
else
  kubectl --context orbstack -n oda-system create secret generic oda-agent-api-key \
    --from-file=AGENT_API_KEY=<(printf %s "$AGENT_API_KEY") \
    --from-file=CLAUDE_BRIDGE_API_KEY=<(printf %s "$CLAUDE_BRIDGE_API_KEY") \
    --from-file=CLAUDE_CODE_OAUTH_TOKEN=<(printf %s "$CLAUDE_CODE_OAUTH_TOKEN") \
    --dry-run=client -o yaml | kubectl --context orbstack apply -f -
fi

# 3. deploy (Pod becomes 2/2) and open a loopback-only tunnel
kubectl --context orbstack apply -k kubernetes/
kubectl --context orbstack -n oda-system rollout status deploy/oda-agent --timeout=240s
kubectl --context orbstack -n oda-system port-forward svc/oda-agent 8091:8080 >/dev/null 2>&1 &
for i in $(seq 1 20); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8091/health)
  if [ "$code" = 200 ]; then echo "✅ tunnel ready after ${i}s"; break; fi
  sleep 1
done
```

Then use the [API reference](#-api-reference-with-curl) with `A=http://localhost:8091` and agent name **`agent-sre`**.

> 🔄 After changing the Secret, run `kubectl --context orbstack -n oda-system rollout restart deploy/oda-agent`, because env vars from a Secret are read only when the Pod starts.
> 🧹 Teardown: `kill %1; kubectl --context orbstack delete -k kubernetes/; kubectl --context orbstack delete ns oda-demo oda-system`

---

## 📡 API reference with curl

| Setup | `A=` | Agent name (`AG=`) |
|---|---|---|
| 🐳 Docker Compose | `http://localhost:8090` | `agent` (SRE advisor, chat only) |
| ☸️ Kubernetes | `http://localhost:8091` | `agent-sre` (investigates the cluster with read-only tools) |

Pick one target (Kubernetes: `A=http://localhost:8091; AG=agent-sre`):

```bash
setopt interactivecomments 2>/dev/null || true
A=http://localhost:8090; AG=agent

# helper: sends the key on stdin, so it never shows in `ps`
api() { printf 'header = "Authorization: Bearer %s"\n' "$AGENT_API_KEY" | curl -s -K - -H 'Content-Type: application/json' "$@"; }
check() { if [ "$2" = "$3" ]; then echo "✅ $1 → $2"; else echo "❌ $1 → got $2, expected $3"; fi; }
```

**🩺 Health and auth (no model calls)**

```bash
check "health (no key needed)" "$(curl -s -o /dev/null -w '%{http_code}' $A/health)" 200
check "agents without key"     "$(curl -s -o /dev/null -w '%{http_code}' $A/api/agents)" 401
check "agents with wrong key"  "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong' $A/api/agents)" 401
check "agents with your key"   "$(api -o /dev/null -w '%{http_code}' $A/api/agents)" 200
api $A/api/agents | jq -c '.[] | {name, description}'
```

**💬 Ask a question (creates a session, then streams the run)**

```bash
SID=$(api -X POST $A/api/sessions -d '{}' | jq -r .id)

api -N -X POST $A/api/sessions/$SID/agent/$AG \
  -d '{"messages":[{"role":"user","content":"In one line: first kubectl command for a CrashLoopBackOff pod?"}]}' >/dev/null

# print the latest answer
api $A/api/sessions/$SID | jq -r '[.messages[]? | select(.message.role=="assistant" and (.message.content|length)>0)][-1].message.content'
```

**🕵️ Kubernetes only: let it investigate the lab**

```bash
api -N -X POST $A/api/sessions/$SID/agent/$AG \
  -d '{"messages":[{"role":"user","content":"Investigate namespace oda-demo: which pods are unhealthy and why? Root cause and fix for each, briefly."}]}' >/dev/null
api $A/api/sessions/$SID | jq -r '[.messages[]? | select(.message.role=="assistant" and (.message.content|length)>0)][-1].message.content'
```

**🔁 Follow-up in the same session** (send only the new message; the server keeps the history)

```bash
api -N -X POST $A/api/sessions/$SID/agent/$AG \
  -d '{"messages":[{"role":"user","content":"Which kubectl flag shows the previous container logs? One line."}]}' >/dev/null
api $A/api/sessions/$SID | jq -r '[.messages[]? | select(.message.role=="assistant" and (.message.content|length)>0)][-1].message.content'
```

**🌊 Watch an answer stream live** (Server-Sent Events, printed as text)

```bash
api -N -X POST $A/api/sessions/$SID/agent/$AG \
  -d '{"messages":[{"role":"user","content":"Name two kubectl get flags."}]}' \
  | grep '^data:' | sed 's/^data: //' | jq -j 'select(.type=="agent_choice") | .content // empty'; echo
```

**🗂️ Sessions**

```bash
api $A/api/sessions | jq -c '.[] | {id, title, num_messages}'                 # list
api $A/api/sessions/$SID | jq '{title, input_tokens, output_tokens, messages: (.messages|length)}'
api -X DELETE $A/api/sessions/$SID                                             # delete
```

**🧪 Prove it's read-only (Kubernetes)**

```bash
api -N -X POST $A/api/sessions/$SID/agent/$AG -d '{"messages":[{"role":"user","content":"Delete the web pod in oda-demo now."}]}' >/dev/null
api $A/api/sessions/$SID | jq -r '[.messages[]? | select(.message.role=="assistant" and (.message.content|length)>0)][-1].message.content'
kubectl --context orbstack -n oda-demo get pods          # still there
```

---

## 🔒 Security controls

| Control | Compose | Kubernetes |
|---|---|---|
| Agent API reachable only from your machine | `ports: 127.0.0.1:8090:8080` | `ClusterIP` + `kubectl port-forward` (binds 127.0.0.1) |
| Bridge reachable only by the agent | Not published (no `ports:`); private network `oda`; bearer key (on Linux hosts container IPs may be routable from the host itself, so the key is the real control) | Listens on Pod loopback `127.0.0.1:18188`; bearer key; other Pods → `000` (tested) |
| Fails closed without secrets | `docker compose` refuses to start (`${VAR:?}`); the bridge **refuses to start without its key** | Empty Secret guard in step 2; the bridge refuses to start without its key, and returns 401 to wrong keys |
| Claude Code can't run its own tools | `--allowedTools mcp__host` + 43 denied tools in `managed-settings.json` (incl. Bash, Read, Write, WebFetch, WebSearch) | same |
| Cluster access | n/a | `oda-reader` ServiceAccount: `get/list/watch` in `oda-demo` only, no Secrets (RBAC) |
| Network | Docker defaults | Ingress deny-all; egress only DNS, the Kubernetes API and HTTPS 443 to public IPs |
| Container hardening | read-only rootfs, `cap_drop: ALL`, `no-new-privileges`, non-root 65532 | same + seccomp `RuntimeDefault`, resource limits |
| Secrets at rest | macOS Keychain → env at `up` time | Keychain → Kubernetes Secret (`$(VAR)` expansion; not in YAML) |

> ⚠️ **Accepted exposures**
> - `docker inspect`, and `kubectl get secret` for anyone with that RBAC, can still reveal the values. Anyone who can run Docker or read Secrets already controls this machine or namespace.
> - The OAuth token is a full credential for your Claude subscription. Keep it in the Keychain, and run `claude setup-token` again to rotate it.

---

## 🧪 Tested results

Images `sha-3a791eb` (`8561da6d…`) and `bridge-sha-3a791eb` (`461a49cf…`), pulled from Docker Hub, with **no bridge running on the Mac** (`:18188` → `000`).

| Test | 🐳 Compose | ☸️ Kubernetes |
|---|---|---|
| Health / no key / wrong key / your key | ✅ 200 / 401 / 401 / 200 | ✅ 200 / 401 / – / 200 |
| Bridge not reachable from outside | ✅ host `:18188` → `000` | ✅ other Pod → Pod IP `:18188` → `000`; agent `:8080` → `000` |
| Real answer through the bridge | ✅ 8 s: `kubectl logs <pod> --previous` | ✅ 20 s investigation, 7 read-only tool calls (`pods_list_in_namespace`, `events_list`, `pods_log`, `pods_get`×2, …) |
| Root causes | n/a | ✅ `api`: missing `DATABASE_URL`; `web`: `nginx:faulty` |
| Follow-up from session memory | ✅ `--previous (or -p)` | ✅ |
| Write attempt | n/a | ✅ refused; pods unchanged |
| Bridge evidence | `docker logs oda-claude-code-cli-bridge-1`: `POST /v1/chat/completions 200`, `turn done in 5.8s`, `mode=continue` | Pod `2/2 Running`, 0 restarts |

---

## 🩺 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `required variable … is missing a value` | `docker compose` needs all three env vars, even for `logs`/`down` | Load the Keychain secrets, or use `docker logs <container>` |
| Pod `1/2`, bridge not Ready | A TCP probe dials the Pod IP, but the bridge listens on loopback | Use the shipped exec probe (`python3 -c "socket.create_connection(('127.0.0.1',18188))"`) |
| Agent error `HTTP 401: unauthorized` | `CLAUDE_BRIDGE_API_KEY` differs between agent and bridge | Use the same Keychain value for both; recreate (Compose) or `rollout restart` (k8s) |
| Answer is an error about login or auth | `CLAUDE_CODE_OAUTH_TOKEN` missing or expired | `claude setup-token`, update the Keychain item, recreate or restart |
| `failed to load agents: … must be set` | Agent started with `--flavor compose`/`in-pod` but without `CLAUDE_BRIDGE_API_KEY` | Pass it (Compose `environment:` / Secret key) |
| `curl` prints `000` right after start | Still starting | Use the wait loop |
| `000` on `localhost:8091` | The `port-forward` exited (it dies when its Pod is replaced, e.g. by a rollout) or was never started | `pkill -f 'port-forward svc/oda-agent'`, then start it again **after** `rollout status` |
| Workloads vanished after an OrbStack restart | The OrbStack VM restarted; namespaces kept, objects gone | Re-run the `kubectl apply` steps (idempotent) |

---

[← 🐳 Docker Agent runbook](../README.md) · [⚖️ Comparison guide](../COMPARISON.md)
