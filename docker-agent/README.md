# 🤖 Docker Agent: a security-first DevOps/SRE assistant

> **[Docker Agent](https://docs.docker.com/ai/docker-agent/)** is Docker's open-source framework for building AI agents: you describe the agent (model, instructions, tools) in one YAML file, and the `docker agent` runtime runs it.

## 👋 Start here

This folder runs an AI assistant for DevOps and SRE work inside locked-down Docker containers. You talk to it over a normal HTTP API with `curl`. By default it only gives advice or reads your cluster; the optional fixer agent can change a cluster, and it asks you to approve each change first.

**Pick your path** (each is a short list of copy-paste steps):

1. 🐳 **Ask it questions on your laptop** → [Path A: Docker Compose + Claude](#-path-a-docker-compose--claude-on-your-laptop)
2. ☸️ **Let it diagnose a broken Kubernetes cluster (read-only)** → [Path B: Kubernetes SRE agent](#-path-b-kubernetes-sre-agent-read-only)
3. 🛠️ **Let it fix the cluster, with your approval** → [Path C](#-path-c-lead-sre-fixer-fixes-with-your-approval) / 🎬 [DEMO.md](./DEMO.md)
4. 🟢 **Use free models, no Claude account** → [Path D: OpenCode](#-path-d-free-models-with-opencode)
5. 🧩 **Why a YAML file instead of writing agent code?** → [`agent.yaml` explained](#-agentyaml-explained-what-it-replaces)
6. 🏢 **Planning for your organization (customer chatbot, RAG, long-term memory)?** → [Organization use cases & next PoC](#-organization-use-cases--next-poc--docker-agent--rag--long-term-memory)
7. 🧠 **Understand how it works and why it's safe** → [📚 Reference](#-reference): [Concepts](#-concepts-read-this-first), [Architecture](#%EF%B8%8F-architecture), [Security model](#-security-model), [CI/CD](#-cicd-pipeline)

---

## 🚀 Guided paths (copy, paste, Enter)

Every step below is **one block: copy it, paste it, press Enter**. Each block works on its own and shows the ✅ expected result.
Run everything from the `docker-agent` folder of this repo. Tested exactly as written on macOS with OrbStack.

| Path | You get | Time |
|---|---|---|
| [🅰 Docker Compose + Claude](#-path-a-docker-compose--claude-on-your-laptop) | An SRE advisor on `localhost:8090` you can ask questions | 5 min |
| [🅱 Kubernetes SRE agent (read-only)](#-path-b-kubernetes-sre-agent-read-only) | An agent **inside** your cluster that diagnoses broken pods, but can't change anything | 10 min |
| [🅲 Lead SRE fixer (fixes with your approval)](#-path-c-lead-sre-fixer-fixes-with-your-approval) | The agent fixes the broken pods after you approve each change | 10 min |
| [🅳 Free models with OpenCode](#-path-d-free-models-with-opencode) | The advisor on free MiMo / DeepSeek models, no Claude account | 5 min |

**You need:** Docker via [OrbStack](https://orbstack.dev) (with Kubernetes enabled for paths B and C), plus `jq` and `yq` (`brew install jq yq`).
Images are pulled from Docker Hub; nothing is built on your laptop ([why](#-cicd-pipeline)).

### 🔑 Step 0 (all paths): your secrets in the macOS Keychain

Check them:

```bash
for item in oda-agent-api-key oda-claude-bridge-key oda-claude-oauth-token oda-opencode-bridge-key; do
  security find-generic-password -a "$USER" -s "$item" >/dev/null 2>&1 && echo "✅ $item" || echo "❌ $item missing"
done
```

✅ Expected: four ✅ lines (path D only needs `oda-agent-api-key` and `oda-opencode-bridge-key`; paths A to C don't need the OpenCode one).
**Only for a ❌**, create that one item. Random keys:

```bash
security add-generic-password -U -a "$USER" -s oda-agent-api-key -w "$(openssl rand -hex 24)"
```

```bash
security add-generic-password -U -a "$USER" -s oda-claude-bridge-key -w "$(openssl rand -hex 24)"
```

```bash
security add-generic-password -U -a "$USER" -s oda-opencode-bridge-key -w "$(openssl rand -hex 24)"
```

Your Claude login: run `claude setup-token` once (it opens the browser and prints a token), then run this and paste the token at the prompt:

```bash
security add-generic-password -U -a "$USER" -s oda-claude-oauth-token -w
```

> ⚠️ Don't re-run these for items that are already ✅: `-U` overwrites them.
> 🔒 Why the Keychain: no `.env` files, nothing in shell history, nothing committed by accident.

---

### 🅰 Path A: Docker Compose + Claude on your laptop

Two containers: the **agent** (on `127.0.0.1:8090`, your Mac only) and the **Claude Code CLI bridge** (not reachable from your Mac at all; only the agent can talk to it).

**A1. Start it**

```bash
export AGENT_API_KEY=$(security find-generic-password -a "$USER" -s oda-agent-api-key -w)
export CLAUDE_BRIDGE_API_KEY=$(security find-generic-password -a "$USER" -s oda-claude-bridge-key -w)
export CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -a "$USER" -s oda-claude-oauth-token -w)
docker compose up -d
for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8090/health)" = 200 ] && break; sleep 1; done
curl -s -o /dev/null -w 'agent: HTTP %{http_code}\n' http://localhost:8090/health
```

✅ Expected: `Container oda-claude-code-cli-bridge-1 Healthy`, `Container oda-agent-1 Started`, then `agent: HTTP 200`.

**A2. Prove it's locked down**

```bash
curl -s -o /dev/null -w 'no key:    HTTP %{http_code}\n' http://localhost:8090/api/agents
curl -s -o /dev/null -w 'wrong key: HTTP %{http_code}\n' -H 'Authorization: Bearer wrong' http://localhost:8090/api/agents
curl -s -o /dev/null -w 'your key:  HTTP %{http_code}\n' -H "Authorization: Bearer $(security find-generic-password -a "$USER" -s oda-agent-api-key -w)" http://localhost:8090/api/agents
curl -s -m 3 -o /dev/null -w 'bridge from your Mac: HTTP %{http_code}\n' http://localhost:18188/health
```

✅ Expected: `401`, `401`, `200`, and `000` for the bridge (not reachable from your Mac).

**A3. Ask it a question (the answer streams live)**

```bash
KEY=$(security find-generic-password -a "$USER" -s oda-agent-api-key -w)
SID=$(curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X POST http://localhost:8090/api/sessions -d '{}' | jq -r .id)
curl -sN -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X POST "http://localhost:8090/api/sessions/$SID/agent/agent" \
  -d '{"messages":[{"role":"user","content":"A pod is in CrashLoopBackOff. What are the first three kubectl commands you would run? One line each."}]}' \
  | jq -Rrj --unbuffered 'select(startswith("data: ")) | .[6:] | fromjson | if .type=="agent_choice" then .content elif .type=="stream_stopped" then "\n\n🏁 DONE\n" else empty end'
```

✅ Expected: three `kubectl` commands (for example `kubectl describe pod`, `kubectl logs --previous`, `kubectl get events`), then `🏁 DONE`.
This agent only **advises**: it has no access to any cluster.

**A4. Stop it** (any terminal, in the `docker-agent` folder)

```bash
AGENT_API_KEY=unused CLAUDE_BRIDGE_API_KEY=unused CLAUDE_CODE_OAUTH_TOKEN=unused docker compose down
```

The `unused` values are only there because `docker compose` checks that every variable in `compose.yaml` is set, even when it's just stopping.

✅ Expected: both containers `Removed`. Sessions are kept in the `oda_oda-data` volume (`docker compose down -v` deletes them too).

> More: all API calls (sessions, follow-ups, OpenAI-compatible endpoint) in [📡 API reference with curl](#-api-reference-with-curl).

---

### 🅱 Path B: Kubernetes SRE agent (read-only)

The agent and its Claude bridge run as **one Pod** in namespace `oda-system`. It can **read** pods, events and logs in namespace `oda-demo` (where two apps are broken on purpose), and nothing else.

**B1. Create the namespace, the identity and the Secret (from the Keychain)**

```bash
kubectl --context orbstack apply -f k8s-lab/demo-broken.yaml -f k8s-lab/rbac-readonly.yaml
kubectl --context orbstack -n oda-system create secret generic oda-agent-api-key \
  --from-file=AGENT_API_KEY=<(security find-generic-password -a "$USER" -s oda-agent-api-key -w | tr -d '\n') \
  --from-file=CLAUDE_BRIDGE_API_KEY=<(security find-generic-password -a "$USER" -s oda-claude-bridge-key -w | tr -d '\n') \
  --from-file=CLAUDE_CODE_OAUTH_TOKEN=<(security find-generic-password -a "$USER" -s oda-claude-oauth-token -w | tr -d '\n') \
  --dry-run=client -o yaml | kubectl --context orbstack apply -f -
```

✅ Expected: namespaces, two broken Deployments, ServiceAccount `oda-reader` with a read-only Role, and `secret/oda-agent-api-key created` (or `unchanged`).

**B2. Deploy the agent**

```bash
kubectl --context orbstack apply -k kubernetes
kubectl --context orbstack -n oda-system rollout status deploy/oda-agent --timeout=180s
kubectl --context orbstack -n oda-system get pods -l app=oda-agent
```

✅ Expected: `oda-agent-…   2/2   Running` (agent + Claude bridge).

**B3. Connect** (keep this terminal open; run it again if the Pod restarts)

```bash
pkill -f "port-forward svc/oda-agent 8091"
kubectl --context orbstack -n oda-system port-forward svc/oda-agent 8091:8080 >/dev/null 2>&1 &
sleep 3
curl -s -o /dev/null -w 'agent: HTTP %{http_code}\n' http://localhost:8091/health
```

✅ Expected: `agent: HTTP 200`

**B4. Ask it to diagnose the broken apps**

```bash
KEY=$(security find-generic-password -a "$USER" -s oda-agent-api-key -w)
SID=$(curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X POST http://localhost:8091/api/sessions -d '{}' | jq -r .id)
curl -sN -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X POST "http://localhost:8091/api/sessions/$SID/agent/agent-sre" \
  -d '{"messages":[{"role":"user","content":"Diagnose the failing pods in namespace oda-demo. Root cause per pod, one line each."}]}' \
  | jq -Rrj --unbuffered 'select(startswith("data: ")) | .[6:] | fromjson | if .type=="agent_choice" then .content elif .type=="tool_call" then "\n🔧 " + .tool_call.function.name + "\n" elif .type=="stream_stopped" then "\n\n🏁 DONE\n" else empty end'
```

✅ Expected: 🔧 lines (it lists pods, reads events and logs), then: `api` is missing `DATABASE_URL`; `web` uses a non-existent image `nginx:faulty`.

**B5. Prove it can't change anything**

```bash
kubectl --context orbstack auth can-i get pods -n oda-demo --as system:serviceaccount:oda-system:oda-reader
kubectl --context orbstack auth can-i delete pods -n oda-demo --as system:serviceaccount:oda-system:oda-reader
kubectl --context orbstack auth can-i get secrets -n oda-demo --as system:serviceaccount:oda-system:oda-reader
kubectl --context orbstack auth can-i get pods -n kube-system --as system:serviceaccount:oda-system:oda-reader
```

✅ Expected: `yes`, then `no`, `no`, `no`. Ask it to delete a pod (like B4, with that prompt) and it answers that it can only read.

**B6. Clean up** (the Secret and namespaces stay for path C)

```bash
pkill -f "port-forward svc/oda-agent 8091"
kubectl --context orbstack delete -k kubernetes
```

> More: architecture, NetworkPolicy and isolation tests in [G. Inside local Kubernetes](#g-%EF%B8%8F-run-the-sre-agent--bridge-sidecar-inside-local-kubernetes-orbstack).

---

### 🅲 Path C: Lead SRE fixer (fixes with your approval)

Same idea as path B, but this agent can **fix** the broken apps. Every change stops and waits for your approval, and you see the exact `kubectl diff` first.
It has its own step-by-step guide with two terminals: **👉 [DEMO.md](./DEMO.md)**.

---

### 🅳 Path D: Free models with OpenCode

The same advisor as path A, backed by OpenCode's **free** models (MiMo by default). No Claude account needed.

> ⚠️ **Send one request at a time and never retry on an error.** OpenCode's free tier blocks your whole internet address (IP) after bursts, which also breaks the OpenCode app on your Mac. If you see `free tier can only be used from within OpenCode`, stop; a new IP (router restart) fixes it.

**D1. Start it**

```bash
cd opencode-cli-bridge
export AGENT_API_KEY=$(security find-generic-password -a "$USER" -s oda-agent-api-key -w)
export OPENCODE_BRIDGE_API_KEY=$(security find-generic-password -a "$USER" -s oda-opencode-bridge-key -w)
docker compose up -d
for i in $(seq 1 180); do [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8093/health)" = 200 ] && break; sleep 1; done
curl -s -o /dev/null -w 'agent: HTTP %{http_code}\n' http://localhost:8093/health
```

✅ Expected: `Container oda-opencode-opencode-cli-bridge-1 Healthy`, `Container oda-opencode-agent-1 Started`, then `agent: HTTP 200`.

**D2. Ask one question**

```bash
KEY=$(security find-generic-password -a "$USER" -s oda-agent-api-key -w)
SID=$(curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X POST http://localhost:8093/api/sessions -d '{}' | jq -r .id)
curl -sN -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X POST "http://localhost:8093/api/sessions/$SID/agent/agent" \
  -d '{"messages":[{"role":"user","content":"One line: what does ImagePullBackOff mean?"}]}' \
  | jq -Rrj --unbuffered 'select(startswith("data: ")) | .[6:] | fromjson | if .type=="agent_choice" then .content elif .type=="stream_stopped" then "\n\n🏁 DONE\n" else empty end'
```

✅ Expected: a one-line explanation, then `🏁 DONE`. (The whole answer arrives at once: this bridge doesn't stream word by word.)

**D3. Stop it** (any terminal, in the `docker-agent` folder)

```bash
cd opencode-cli-bridge
AGENT_API_KEY=unused OPENCODE_BRIDGE_API_KEY=unused docker compose down
cd ..
```

> More: models, tool policy and the free-tier rules in [🟢 OpenCode CLI bridge](#-opencode-cli-bridge-free-mimo--deepseek).

---

## 🧩 `agent.yaml` explained: what it replaces

An **agent** is a loop: send the conversation to a model, and if the model asks to use a tool, run the tool, give the result back, repeat until it answers.
In Docker Agent you don't write that loop. You **describe** the agent in one YAML file, and the `docker agent` runtime (inside our container image) does the rest.

### 🧱 The traditional way: you write and own all of this

Building the same advisor "by hand" (Python with the OpenAI/Anthropic SDK, LangChain, etc.) means writing and maintaining:

```text
 your code
 ├── model client per provider (OpenAI, Anthropic, local…) + retries, timeouts, streaming
 ├── the agent loop (call model → parse tool calls → run tools → feed results back → repeat)
 ├── tool definitions + JSON schemas, or an MCP client to talk to tool servers
 ├── safety: which tool calls are allowed, which need a human, how approvals pause and resume
 ├── memory / session storage (SQLite, Redis…)
 ├── an HTTP server (FastAPI…) + authentication + streaming (SSE)
 ├── config per environment (laptop vs Compose vs Kubernetes) → if/else or many config files
 └── a Dockerfile + dependency pinning + CVE patching for all of the above
```

A minimal sketch of just the loop and server (not runnable, and still missing approvals, memory, MCP and auth):

```python
# the part agent.yaml makes unnecessary (sketch)
client = OpenAI(base_url=..., api_key=...)
tools = [{"type": "function", "function": {"name": "pods_list", "parameters": {...}}}, ...]
@app.post("/chat")
def chat(req):
    messages = [{"role": "system", "content": INSTRUCTION}, *req.messages]
    while True:
        r = client.chat.completions.create(model=MODEL, messages=messages, tools=tools)
        msg = r.choices[0].message
        if not msg.tool_calls:
            return msg.content
        for call in msg.tool_calls:                      # + allow/deny/approval logic, timeouts, errors…
            messages.append(run_tool(call))              # + your own Kubernetes client, RBAC handling…
```

### ✅ The `agent.yaml` way: describe it, the runtime runs it

Our [`agent.yaml`](./agent.yaml), section by section:

**1. Header**: which schema the file follows (your editor validates and autocompletes it) and what the agent is.

```yaml
version: "15"
metadata:
  description: Read-only DevOps/SRE investigation assistant
```

**2. `providers`**: *where* models are reached. Any OpenAI-compatible endpoint works; the key comes from an **environment variable**, never from the file.

```yaml
providers:
  claude-bridge:
    api_type: openai_chatcompletions
    base_url: http://host.docker.internal:18188/v1
    token_key: CLAUDE_BRIDGE_API_KEY      # name of the env var that holds the key
```

**3. `models`**: named models on those providers. Built-in providers (`openai`, `dmr` for Docker Model Runner, …) need no `providers` entry.

```yaml
models:
  claude-bridge: {provider: claude-bridge, model: claude-haiku-4-5}
  cloud:         {provider: openai, model: gpt-5-mini}
  local:         {provider: dmr, model: ai/smollm2}
```

**4. `agents`**: the agent itself. `root` is the one that answers you: its model, its job (the instruction), and its tools.

```yaml
agents:
  root:
    model: cloud
    instruction: |
      Help analyze incidents, Kubernetes events, CI/CD failures and logs provided by the user.
      Recommend safe diagnostic commands, but do not claim to have inspected live systems.
      Never change infrastructure.
    toolsets:
      - type: think      # a scratchpad to reason step by step; it can't touch anything
```

**5. `flavors`**: one file, many environments. A flavor is a small patch picked at run time with `--flavor`:

```yaml
flavors:
  local:                        # laptop, free local model
    agents: {root: {model: local}}
  compose:                      # Docker Compose: the bridge is a service name, not localhost
    providers: {claude-bridge: {base_url: http://claude-code-cli-bridge:18188/v1}}
    agents: {root: {model: claude-bridge}}
  opencode:                     # free OpenCode models
    agents: {root: {model: opencode-mimo}}
```

Same file, different place: `--flavor compose` (Path A), `--flavor opencode` (Path D), `--flavor local` (no cloud at all).

### 🛠️ The SRE agents add tools, memory and safety, still in YAML

[`agent-sre.yaml`](./agent-sre.yaml) (Path B) and [`kubernetes-fixer/agent-sre-fixer.yaml`](./kubernetes-fixer/agent-sre-fixer.yaml) (Path C) add three things that would be the hardest code to write by hand:

```yaml
toolsets:
  - type: memory                       # long-term memory in SQLite, on a volume
    path: /data/memory.db
  - type: mcp                          # any MCP server becomes the agent's tools
    command: /usr/local/bin/kubernetes-mcp-server
    args: ["--config", "/etc/kubernetes-mcp-server/config.toml"]

permissions:                           # tool-call policy
  allow: [add_memory, update_memory]   # runs without asking
  ask:   [resources_create_or_update, resources_scale, pods_delete]   # pauses for a human (Path C)
  deny:  [pods_exec, pods_run, resources_delete]                       # never (Path C)

agents:
  root:
    safety: balanced                   # read-only calls auto-run, everything else follows the rules above
```

- **Tools without code:** `kubernetes-mcp-server` gives the agent `pods_list`, `pods_log`, `events_list`, `resources_get`, … The agent's power is decided by the Kubernetes RBAC of its ServiceAccount, not by your Python.
- **Human approval without code:** an `ask` tool pauses the run and emits a `tool_call_confirmation` event; one `curl …/resume` approves or rejects it ([DEMO.md](./DEMO.md) steps 4 and 5).
- **Memory without code:** `add_memory` / `search_memories` backed by SQLite.

### 🔧 Give the agent your CLIs: `shell`, `script` and MCP

The real power of tools: the agent can use the **same CLIs you already use** (`kubectl`, `helm`, `aws`, `terraform`, `gh`, …) with the auth you already have (kubeconfig, AWS profile), without writing any code. Docker Agent offers three ways, from most open to most controlled:

| Toolset | What the model can do | How you control it | Best for |
|---|---|---|---|
| `type: shell` | Run **any** command line | `permissions` rules on the command (`shell:cmd=kubectl get *`) + the `safety` mode | Exploring, troubleshooting, power users |
| `type: script` | Run **named, fixed commands** you define; it only fills in the arguments you declared | Each command is its own tool name, so allow/ask/deny per command | Giving an agent a safe, small "button panel" of CLI actions |
| `type: mcp` | Call typed tools from an MCP server (`pods_list`, `resources_get`, …) | Tool annotations (read-only or not), `permissions`, the server's own config | Production; works in images without a shell (**this project's choice**) |

A tested example, [`examples/cli-tools/agent-cli.yaml`](./examples/cli-tools/agent-cli.yaml):

```yaml
permissions:
  allow:
    - k8s_pods                          # the script tool below
    - "shell:cmd=kubectl get *"
    - "shell:cmd=kubectl logs *"
  deny:
    - "shell:cmd=*kubectl delete*"
agents:
  root:
    safety: restricted                  # unattended: safe calls run, anything not allowed is denied
    toolsets:
      - type: script
        shell:
          k8s_pods:
            description: List pods in a namespace
            cmd: kubectl get pods -n "$namespace" -o wide
            args:
              namespace: {type: string, description: Kubernetes namespace}
            required: [namespace]
      - type: shell
```

- **`script` arguments are safe by design:** the model's values arrive as **environment variables** (`$namespace`), never pasted into the command text, and only arguments you declared are passed. That blocks command injection and tricks like setting `PATH` or `LD_PRELOAD`.
- **Who decides what runs:** a `deny` rule always wins; then `ask`/`allow` rules; then the `safety` mode (`restricted` = run "safe" calls, deny the rest; `balanced` = run "safe" calls, **ask a human** for the rest).

**🧪 What actually happened** (real run: Claude via the Compose bridge, `kubectl` in an `alpine/k8s` container, a 10-minute **read-only** token for ServiceAccount `oda-reader`, against the OrbStack demo):

| Asked the agent to… | Result |
|---|---|
| List pods with the `k8s_pods` script tool | ✅ ran `kubectl get pods -n oda-demo -o wide` |
| `kubectl logs` the api pod (allow rule) | ✅ ran; it found `FATAL: DATABASE_URL is not set` |
| `kubectl delete pod …` (deny rule) | ⛔ `Tool 'shell' is denied by permissions configuration.` Pods unchanged |
| `kubectl label deploy web …` (not listed, changes something) | ⛔ `denied by the restricted safety mode: the call is not classified safe` |
| `cat /w/marker.txt` (**not** on the allow-list) | ⚠️ **ran anyway**: docker-agent classifies read-only commands like `cat` as safe and auto-runs them |

> ⚠️ **Lesson: read-only is not harmless.** In the same test, the agent could also `cat` the mounted kubeconfig, **token included**. With a `shell` tool:
> - never mount credentials the agent shouldn't read (give it a dedicated, short-lived, least-privilege identity like `oda-reader`);
> - remember that globs are broad: `kubectl get *` also matches `kubectl get secrets`, so **RBAC must forbid** what you don't want (`oda-reader` can't read Secrets);
> - prefer `script` tools (fixed commands) over a free `shell`, and `balanced` (human approval) over `restricted` when in doubt.

**Why this project uses MCP instead:** our runtime images are **distroless**, with no `/bin/sh`, no `kubectl`, no package manager. That removes a whole class of attacks (no shell to abuse), but it also means `shell` and `script` tools can't run inside them. Use them with an image that ships the CLIs you want (for example `alpine/k8s`), and keep the same guardrails.

**Other built-in toolsets** worth knowing: `filesystem` (read/write files, limited with `allow_list`), `fetch` (HTTP GET, limited with `allowed_domains`), `api` / `openapi` (call your REST APIs), `git`, `todo`, `rag` (search your docs), `think`, `memory`. Full list in the [schema](https://raw.githubusercontent.com/docker/docker-agent/v1.150.0/agent-schema.json).

### ⚖️ Side by side

| | Traditional (your code) | `agent.yaml` (Docker Agent) |
|---|---|---|
| Agent loop, tool calling, streaming | You write and debug it | Built in |
| Switch model or provider | Code change, new SDK | Change one line (`model:`) or pick a `--flavor` |
| Tools | Write functions + JSON schemas, or an MCP client | List an MCP server, a `shell`, or named `script` commands (`kubectl`, `helm`, `aws`…) under `toolsets` |
| Safety (allow / ask / deny) and human approval | Custom logic, easy to get wrong | `permissions` + `safety`, enforced by the runtime |
| Memory and sessions | Pick a database, write the code | `type: memory`, `--session-db` |
| HTTP API with auth | FastAPI + auth + SSE | `serve api --auth-token …` / `serve chat --api-key-env …` (fails closed) |
| Laptop vs Compose vs Kubernetes | Branches in code or many configs | `flavors` in the same file |
| Secrets | Easy to leak into code or `.env` | Only env var **names** in the file (`token_key`) |
| Packaging and sharing | Dockerfile + your dependencies | One hardened runtime image for every agent; the YAML itself is shareable (`docker agent share push`) |
| Review and audit | Read the whole codebase | Read one short file; `git diff` shows exactly what changed |
| Who can change it | Developers | Anyone who can read YAML (SRE, platform team) |

### 🧪 Check a config without calling any model

```bash
docker run --rm --read-only --tmpfs /tmp --tmpfs /home/nonroot:uid=65532,gid=65532 -e CLAUDE_BRIDGE_API_KEY=unused \
  docker.io/quickbooks2018/opendevops-agent-runtime:latest run /app/agent.yaml --flavor compose --dry-run
```

✅ Expected: `Dry run mode enabled. Agent initialized but will not execute.`
Remove `-e CLAUDE_BRIDGE_API_KEY=unused` and it refuses to start: `Error: The following environment variables must be set: …` (it fails closed when a key is missing).

### 🧭 What `agent.yaml` does *not* solve

- **The model can still be wrong.** Instructions guide it; they don't guarantee it. That's why real limits live outside the model: Kubernetes RBAC, the admission policy, disabled tools, and human approval.
- **Very custom logic** (complex workflows, your own business rules) still fits better in code. Frameworks like LangGraph give more control; see the [comparison](#%EF%B8%8F-comparison-memory-and-gotchas).
- **Docker Agent is young** (v1.150.0 here): some features have gaps, for example A2A between two docker-agent processes ([details](#-the-official-docker-agent-cli-configuration-distribution-services)).

---

## 📚 Reference

Everything below is the detailed reference: how it works, every option, security, CI/CD, test results and troubleshooting.
You don't need it to run the paths above.

## 📖 What this project is

[Docker Agent](https://docs.docker.com/ai/docker-agent/) (formerly **cagent**) is Docker's open-source framework for defining AI agents in YAML. This project uses it to package a **read-only DevOps/SRE advisor** as hardened container images.

- **Build:** GitHub Actions builds and scans the images and publishes them to Docker Hub. End-to-end tests **pull the images from Docker Hub**; nothing is built locally.
- **API:** the agent serves an **OpenAI-compatible API**.
- **Main backend:** the **🌉 Claude Code CLI bridge**, a pre-authenticated `claude` CLI wrapped as an OpenAI-compatible API. It runs **next to the agent**, as a second **Docker Compose** service or a **sidecar in the same Kubernetes Pod**.
- **Other backends:** a free local model, and Claude Code inside the agent's own container.

> This is **not** Docker's built-in assistant Gordon (`docker ai`).

> ⚡ **Just want to call the agent?** Pick a backend:
> - **[🌉 Claude Code CLI bridge](#-claude-code-cli-bridge)**: Claude, tool calling, Docker Compose **and** Kubernetes.
> - **[🟢 OpenCode CLI bridge](#-opencode-cli-bridge-free-mimo--deepseek)**: **free** MiMo / DeepSeek models, no credentials, chat only, Docker Compose.
>
> Each has copy-paste setup and curl commands. **All documentation for this folder lives in this one README.**

| | |
|---|---|
| 🐳 Images | [`quickbooks2018/opendevops-agent-runtime`](https://hub.docker.com/r/quickbooks2018/opendevops-agent-runtime): tags `latest` (agent), `claude-code` (agent + Claude Code harness), `bridge` (Claude Code CLI bridge), `opencode-bridge` (OpenCode CLI bridge) |
| 🔁 Pipeline | [`.github/workflows/docker-agent.yml`](../.github/workflows/docker-agent.yml) |
| 📌 Pinned | docker-agent **v1.150.0**, Claude Code CLI **2.1.302** (both sha256-verified) |
| ✅ Verified | **Agent + Claude Code CLI bridge in Docker Compose and as one Kubernetes Pod**, local model, Claude Code in-container, **read-only Kubernetes SRE agent with tools + persistent memory** (see [verification matrix](#-verification-matrix)) |
| ⚖️ Comparison guide | [⚖️ Comparison, memory and gotchas](#%EF%B8%8F-comparison-memory-and-gotchas): 🧠 memory deep dive (three kinds explained; conversation cache and long-term memory tested), 🪽 vs Hermes, 🦜 vs LangChain/LangGraph, CrewAI, Microsoft Agent Framework, OpenAI/Claude SDKs, Google ADK, Strands, PydanticAI, LlamaIndex, plus pros/cons and a decision guide |
| ⬜ Planned | Production Kubernetes (Helm, ingress + TLS) |

---

## 📑 Contents

- 🚀 [Guided paths (copy, paste, Enter)](#-guided-paths-copy-paste-enter): [A](#-path-a-docker-compose--claude-on-your-laptop) · [B](#-path-b-kubernetes-sre-agent-read-only) · [C](#-path-c-lead-sre-fixer-fixes-with-your-approval) · [D](#-path-d-free-models-with-opencode)
- 🧩 [`agent.yaml` explained: what it replaces](#-agentyaml-explained-what-it-replaces)
- 🏢 [Organization use cases & next PoC](#-organization-use-cases--next-poc--docker-agent--rag--long-term-memory)
- 📚 [Reference](#-reference), everything below:

0. [👋 Start here](#-start-here) · [📖 What this project is](#-what-this-project-is)
1. [Concepts: read this first](#-concepts-read-this-first)
2. [Architecture](#%EF%B8%8F-architecture)
3. [Repository layout](#-repository-layout)
4. [Images and hardening](#-images-and-hardening)
5. [Quick start](#-quick-start) · 🏠 [Run it securely on your own machine](#-run-it-securely-on-your-own-machine-local-only) · 🧰 [Official `docker agent` CLI](#-the-official-docker-agent-cli-configuration-distribution-services)
6. [Backends](#-backends): A. local model · **B. 🌉 Claude Code CLI bridge (Compose + Kubernetes)** · C. Claude Code in the container · D. cloud API · **E. Kubernetes SRE agent (tools + memory)** · **F. Native API (`serve api`, persistent sessions)** · **G. Inside local Kubernetes** · **G2. 🛠️ Lead SRE fixer agent (human-approved fixes)**
7. [🌉 Claude Code CLI bridge](#-claude-code-cli-bridge): [files and patches](#-bridge-files-and-patches-claude-code-cli-bridge) · [how it works](#-how-the-bridge-works) · [🔑 Keychain setup](#-one-time-setup-three-secrets-in-the-keychain) · [🐳 Compose](#-docker-compose-run-and-call-it) · [☸️ Kubernetes](#%EF%B8%8F-kubernetes-one-pod-two-containers-run-and-call-it) · [📡 API reference with curl](#-api-reference-with-curl) · [🔒 security](#-bridge-security-controls) · [🧪 tested results](#-bridge-tested-results)
8. [🟢 OpenCode CLI bridge (free MiMo / DeepSeek)](#-opencode-cli-bridge-free-mimo--deepseek): [when to use](#-when-to-use-it-and-when-not) · [files](#-opencode-bridge-files-opencode-cli-bridge) · [run](#%EF%B8%8F-run-the-opencode-stack) · [curl](#-call-it-with-curl) · [switch model](#-switch-model-mimo--deepseek) · [🔒 tool policy](#-security-the-opencode-tool-policy) · [⚠️ free tier](#%EF%B8%8F-free-tier-behaviour-you-must-know) · [🧪 tested results](#-opencode-tested-results)
9. [👥 Multi-agent team example](#-multi-agent-team-example-on_call--log_analyst)
10. [Talking to the agent (curl / SDK)](#-talking-to-the-agent-curl--sdk)
11. [CI/CD pipeline](#-cicd-pipeline)
12. [Verification matrix](#-verification-matrix)
13. [Security model](#-security-model)
14. [Troubleshooting](#-troubleshooting)
15. [Operations: upgrades, rotation, cleanup](#%EF%B8%8F-operations-upgrades-rotation-cleanup)
16. [Limitations and roadmap](#-limitations-and-roadmap)
17. [⚖️ Comparison, memory and gotchas](#%EF%B8%8F-comparison-memory-and-gotchas): [what it solves](#-what-problem-does-this-agent-solve) · [🧠 memory](#-memory-the-deep-dive) · [🪽 vs Hermes](#-docker-agent-vs-hermes-agent) · [🦜 vs frameworks](#-docker-agent-vs-langchain-and-other-agent-frameworks) · [🧭 which to choose](#-which-one-should-i-choose) · [pros/cons](#-pros-and--cons-of-docker-agent) · [🧰 gotchas](#-is-building-an-agent-with-docker-simple) · [📚 sources](#-sources)

---

## 🧠 Concepts: read this first

A few words in this README have a specific meaning. Read this table once and the rest of the page is much easier to follow.

| Term | What it is | What it is **not** |
|---|---|---|
| **Agent** | `docker-agent serve chat` inside the container. It listens on container port **8083**, requires `Authorization: Bearer $AGENT_API_KEY`, and exposes one agent called **`root`** (send `"model":"root"`). | It is not the model. It adds the SRE instruction, auth and a backend on top. |
| **Backend** | Where `root` gets its answers: a model API or an external CLI. You choose it with an image tag plus `--flavor`. | The client never talks to the backend directly. |
| **Flavor** | A named YAML patch, selected with `--flavor <name>`. In [`agent.yaml`](./agent.yaml): `compose`, `opencode`, `opencode-deepseek`, `local`, `claude-bridge`, `codex-bridge`. In [`agent-sre.yaml`](./agent-sre.yaml): `in-pod`, `compose`. | It is not a separate image. |
| **Harness** | docker-agent can *exec an external coding CLI* per request instead of calling a model API (`harness.type: claude-code`). Used by the `:claude-code` image. | It is not a bridge, and nothing on the host is involved. |
| **Bridge** | [`claude-code-cli-bridge/`](#-claude-code-cli-bridge): the pre-authenticated `claude` CLI exposed as an OpenAI-compatible API, image tag `bridge`. It runs as a Compose service or a Pod sidecar, and needs a bearer key. | It is not the harness: the harness runs `claude` *inside the agent's container*, the bridge runs it *next to* the agent and supports tool calls. |
| **Chat agent vs SRE agent** | `agent.yaml` / `agent-claude-code.yaml` are **chat-only advisors**: no tools that touch anything. `agent-sre.yaml` is **agentic**: it calls read-only Kubernetes tools and has persistent memory. | The SRE agent can't write either: no create/edit/delete/exec/Secrets. |
| **Runtime image** | A runnable container (`opendevops-agent-runtime`). | It is not an agent-config OCI artifact (`docker agent share push`), which only holds YAML and cannot be used as a Pod `image:`. This project doesn't publish any agent-config artifacts. |

**Which port is which**

| Address | What answers | Auth |
|---|---|---|
| `localhost:<host-port>` → container **`:8083`** | 🤖 **The agent** (`-p 127.0.0.1:8084:8083` picks host port 8084) | Bearer `AGENT_API_KEY` |
| `localhost:12434/engines/v1` | 🧠 Docker Model Runner, the raw local model behind `--flavor local` | none |
| `localhost:8090` (Compose) · `localhost:8091` (k8s port-forward) | 🤖 **The agent's native API** (`serve api`) when running with the bridge | Bearer `AGENT_API_KEY` |
| `claude-code-cli-bridge:18188` (Compose network) · `127.0.0.1:18188` (inside the Pod) | 🌉 The bridge. **Not published** to your host | Bearer `CLAUDE_BRIDGE_API_KEY` |

Inside a container, the host is `host.docker.internal`. That is how the agent reaches Docker Model Runner on `12434`. (The legacy `claude-bridge`/`codex-bridge` flavors also expect a bridge on the host at `18188`/`18288`; the standard setup now runs the bridge next to the agent instead.)

**Port clashes.**
- `8083` is the port **inside** the container, and every container has its own, so it never clashes with your Mac.
- Only the **host** side of `-p HOST:8083` must be free. Check it with `lsof -nP -iTCP:8084 -sTCP:LISTEN` (no output means free).
- Use any free host port, e.g. `-p 9090:8083`, then call `http://localhost:9090`.
- Run several agents at once on different host ports, e.g. `-p 127.0.0.1:8084:8083` and `-p 127.0.0.1:8085:8083`.

> 🐚 **zsh users (macOS default):** write `${IMG}:latest`, not `$IMG:latest`. zsh reads `:l` as a "lowercase" modifier, which turns the image name into `…runtimeatest`.

---

## 🏗️ Architecture

Two pictures. The first shows every backend the agent can use. The second shows the standard setup you will most likely run: the agent and the Claude Code CLI bridge side by side.

```text
                  ┌──────────── client (curl / OpenAI SDK / gateway) ────────────┐
                  │  POST /v1/chat/completions  {"model":"root", ...}             │
                  │  Authorization: Bearer $AGENT_API_KEY                         │
                  └───────────────────────────────┬──────────────────────────────┘
                                                  ▼  host :8084 → container :8083
                  ┌──────────────── docker-agent serve chat (--safety strict) ───┐
                  │  401 on missing/wrong token · agent "root" + SRE instruction │
                  └───┬──────────────────┬────────────────────┬──────────────────┘
       :latest        │                  │                    │        :claude-code
   --flavor local     │  --flavor claude-bridge │ --flavor codex-bridge │  (harness)
                      ▼                  ▼                    ▼                  ▼
     host.docker.internal:12434  host.docker.internal:18188  host…:18288   exec, no shell:
     Docker Model Runner         (legacy: bridge on the host) (legacy)      claude --print
     ai/smollm2 (free, local)                                               --dangerously-skip-permissions
                                                                            --model haiku -p "<prompt>"
                                                                            (tools denied by managed settings)
     (no flavor: openai/gpt-5-mini via OPENAI_API_KEY)
```

**⭐ Standard setup: agent + Claude Code CLI bridge side by side** ([details](#-claude-code-cli-bridge))

```text
you ─curl─▶ 127.0.0.1:8090 (Compose) / :8091 (k8s port-forward)
   ─▶ 🤖 agent: docker-agent serve api  (--flavor compose | in-pod; Bearer CLAUDE_BRIDGE_API_KEY)
   ─▶ 🌉 claude-code-cli-bridge:18188 (Compose network) | 127.0.0.1:18188 (same Pod)
   ─▶ claude CLI (pre-authenticated: CLAUDE_CODE_OAUTH_TOKEN, model claude-haiku-4-5)
   ─▶ Anthropic
```

We checked these details in the docker-agent v1.150.0 source code:
- `harness.type` accepts `claude-code | codex | pi | opencode` (`pkg/config/latest/validate.go`).
- The harness driver is registered for every CLI command, including `serve chat` (`cmd/root/root.go`).
- `github.com/rumpl/harness` execs the CLI directly, with no shell.
- A custom provider with an `api_type` and no `token_key` sends unauthenticated requests (`pkg/model/provider/openai/client.go`).

---

## 📁 Repository layout

What each file in this folder is for. Use it as a map while you read the sections below.

```text
docker-agent/
├── README.md                       ← this runbook: the ONLY doc (bridges, team example, comparison included)
├── agent.yaml                      ← :latest config: root agent, providers, models, flavors
├── agent-claude-code.yaml          ← :claude-code config: harness type claude-code, model haiku
├── agent-sre.yaml                  ← :latest image, agentic SRE: read-only k8s MCP tools + memory (section E)
├── k8s-mcp/config.toml             ← kubernetes-mcp-server: read_only, core toolset, Secrets denied
├── k8s-lab/                        ← demo-broken.yaml (2 broken workloads) + rbac-readonly.yaml (oda-reader SA) + rbac-fixer.yaml (oda-fixer SA)
├── compose.yaml                    ← ⭐ agent + Claude Code CLI bridge as two Compose services (section B)
├── claude-code-cli-bridge/         ← ⭐ bridge image: Dockerfile, bridge, MCP shim, managed settings
├── opencode-cli-bridge/            ← 🟢 free MiMo/DeepSeek bridge: Dockerfile, bridge, OpenCode tool policy, compose.yaml
├── examples/a2a-team/team.yaml     ← 👥 two-agent on-call team: on_call → log_analyst (sub_agents, A2A)
├── examples/cli-tools/agent-cli.yaml ← 🔧 agent with `script` + `shell` tools (kubectl), permission rules (needs an image with a shell)
├── kubernetes/                     ← in-cluster deployment (section G): one Pod = agent + bridge sidecar, Service, PVC, ConfigMap, NetworkPolicies, kustomization
├── kubernetes-fixer/               ← 🛠️ Lead SRE fixer overlay (section G2): write-capable MCP tools, human approval on every change
├── Dockerfile                      ← :latest image (distroless/static)
├── Dockerfile.claude-code          ← :claude-code image (distroless/cc + claude binary)
├── claude-code/managed-settings.json  ← denies every Claude Code built-in tool
└── .dockerignore                   ← allow-list: only the files above enter the build context
../.github/workflows/docker-agent.yml  ← build → smoke → scan → push → authenticated E2E
```

---

## 🐳 Images and hardening

The four image tags this project publishes, and the security settings built into them. Read this to pick a tag, and run the setup block at the end of this section once in every new terminal: all later examples use it.

| Tag | Dockerfile | Config | Backend | Base |
|---|---|---|---|---|
| `latest`, `sha-<7>` | [`Dockerfile`](./Dockerfile) | [`agent.yaml`](./agent.yaml) (default) and [`agent-sre.yaml`](./agent-sre.yaml) | Model API. Default `openai/gpt-5-mini`; flavors `local`, `claude-bridge`, `codex-bridge`. Also ships `kubernetes-mcp-server` v0.0.67 (sha-pinned) for the SRE agent | `gcr.io/distroless/static-debian12:nonroot` |
| `claude-code`, `claude-code-sha-<7>` | [`Dockerfile.claude-code`](./Dockerfile.claude-code) | [`agent-claude-code.yaml`](./agent-claude-code.yaml) | Claude Code CLI harness (`haiku`) | `gcr.io/distroless/cc-debian12:nonroot` (glibc for `claude`) |
| `opencode-bridge`, `opencode-bridge-sha-<7>` | [`opencode-cli-bridge/Dockerfile`](./opencode-cli-bridge/Dockerfile) | bridge flags (`--free-only`, MiMo default) + `opencode.json` tool policy | **Is** a model backend: OpenCode CLI v1.19.3 (free MiMo / DeepSeek), text-only | `gcr.io/distroless/python3-debian12:nonroot` |
| `bridge`, `bridge-sha-<7>` | [`claude-code-cli-bridge/Dockerfile`](./claude-code-cli-bridge/Dockerfile) | bridge flags (haiku, loopback/port 18188) | **Is** the model backend: Claude Code CLI 2.1.302 behind an OpenAI-compatible API | `gcr.io/distroless/python3-debian12:nonroot` |

`latest`, `claude-code` and `bridge` move with `main`. **Pin `sha-<7>` tags or digests** for anything you depend on.

Hardening built into all images:
- docker-agent and `claude` binaries are downloaded during the build and **sha256-verified**.
- Multi-arch: `linux/amd64` and `linux/arm64`, with SBOM and `mode=max` provenance attached.
- Distroless: **no shell, no package manager**.
- Runs as **UID 65532**.
- The default command is `serve chat --listen 0.0.0.0:8083 --api-key-env AGENT_API_KEY --safety strict`.
- **Fails closed:**
  - The server refuses to start without `AGENT_API_KEY`.
  - The `:latest` image without a flavor also refuses to start without `OPENAI_API_KEY`.
  - `:claude-code` without a credential returns HTTP 500 on completions.
- `TELEMETRY_ENABLED=false`. The `:claude-code` image also sets `DISABLE_AUTOUPDATER=1`, `DISABLE_TELEMETRY=1` and `DISABLE_ERROR_REPORTING=1`.

**Run-time hardening used in every example below.** Paste this once per terminal. It sets the image name, creates a random agent key for this shell, and defines the `HARDEN` flags (read-only filesystem, no Linux capabilities, no privilege escalation):

```bash
setopt interactivecomments 2>/dev/null || true   # zsh: allow pasted '# comments' (no-op in bash)
cd OpenDevOps/docker-agent   # all paths in this runbook are relative to this folder
export IMG=quickbooks2018/opendevops-agent-runtime
export AGENT_API_KEY=$(openssl rand -hex 24)
HARDEN=(--read-only --tmpfs /tmp --tmpfs /home/nonroot:uid=65532,gid=65532 \
        --cap-drop ALL --security-opt no-new-privileges)
```

---

## 🚀 Quick start

The fastest way to get one answer from the agent. Pick a backend, start one container, then use [the curl guide](#-talking-to-the-agent-curl--sdk).

**Steps:**
1. Run the setup block from [Images and hardening](#-images-and-hardening) (`IMG`, `AGENT_API_KEY`, `HARDEN`).
2. Pick a row in the table below and install what its **Needs** column lists.
3. Start the container. The block below does this for the `:latest` image; change `FLAVOR=local` if you picked another backend.
4. Wait until it listens, then ask a question with `curl`.
5. Remove the container with `docker rm -f oda` when you're done.

| I want… | Image | Extra run args | Needs |
|---|---|---|---|
| Free, offline smoke test | `:latest` | `serve chat … --flavor local` | Docker Model Runner + `docker model pull ai/smollm2` |
| ⭐ **Claude (my subscription) without anything on my Mac** | `:latest` + `:bridge` | `docker compose up -d` (section B) | 3 Keychain secrets |
| ☸️ The same, **inside Kubernetes** (one Pod) | `:latest` + `:bridge` | `kubectl apply -k kubernetes/` (section G) | 3 secrets in a Kubernetes Secret |
| 🟢 **Free** models (MiMo / DeepSeek), no credentials, chat only | `:latest` + `:opencode-bridge` | `docker compose up -d` in [`opencode-cli-bridge/`](#-opencode-cli-bridge-free-mimo--deepseek) | 2 Keychain keys |
| **Claude Code inside the container** | `:claude-code` | `-e CLAUDE_CODE_OAUTH_TOKEN` (or a login volume) | Claude token / API key |
| Cloud OpenAI | `:latest` | `-e OPENAI_API_KEY` | OpenAI key |

```bash
# generic launcher for the :latest image; set FLAVOR to local | claude-bridge | codex-bridge
FLAVOR=local
docker run -d --name oda -p 127.0.0.1:8084:8083 -e AGENT_API_KEY "${HARDEN[@]}" ${IMG}:latest \
  serve chat /app/agent.yaml --listen 0.0.0.0:8083 --api-key-env AGENT_API_KEY --safety strict --flavor $FLAVOR
until curl -s -o /dev/null http://localhost:8084/v1/models; do sleep 1; done   # wait until the agent listens
curl -s -H "Authorization: Bearer $AGENT_API_KEY" -H 'Content-Type: application/json' \
  http://localhost:8084/v1/chat/completions \
  -d '{"model":"root","messages":[{"role":"user","content":"In one line: first kubectl command for a CrashLoopBackOff pod?"}]}' \
  | jq -r '.choices[0].message.content'
docker rm -f oda
```

> When you override `CMD` (any `--flavor`), you must repeat the full `serve chat …` command. Otherwise the image's default `CMD` is replaced and nothing listens.

---

## 🧰 The official docker agent CLI: configuration, distribution, services

You only need this section if you want to use the `docker agent` command itself: to write, test, share or serve an agent. To simply run this repo's agent, the Quick start and the backend sections are enough.

This section shows Docker Agent's own CLI workflow, using **this repo's agents**. Every ✅ command below was run on docker-agent **v1.150.0**, either the `docker agent` plugin or the same binary inside our image (`docker run … ${IMG}:latest <command>`), with the **Claude Code CLI bridge** as the model.

> 💡 **Running the CLI from our image:** from `OpenDevOps/docker-agent`, use
> `docker run --rm -it --network oda_oda -e CLAUDE_BRIDGE_API_KEY "${HARDEN[@]}" -v "$PWD:/w:ro" --workdir /w ${IMG}:latest <command>`.
> Drop the leading `docker agent` from the commands below, and add `--flavor compose` to `agent.yaml`. The Compose stack from section B provides the bridge.

### ① Configuration: write, check, run

| Command | What it does | Tested |
|---|---|---|
| `docker agent new "an SRE advisor"` | Generates a starter `agent.yaml` with a model's help | 📖 |
| `docker agent version` · `models` · `toolsets` | CLI version · models it can reach · the 29 built-in toolset types | ✅ |
| `docker agent doctor agent.yaml` | Checks config, credentials and model reachability | ✅ |
| `docker agent run agent.yaml --dry-run` | Loads and initialises the agent without calling a model | ✅ |
| `docker agent run agent.yaml` | Interactive TUI chat | 📖 |
| `docker agent run --exec agent.yaml "question"` | Headless one-shot (scripts, CI) | ✅ |
| `… --exec --last` / `--exec --json` | Only the final answer / NDJSON event stream (`stream_started`, `agent_choice`, …) | ✅ |
| `docker agent run team.yaml --agent on_call` | Pick one agent from a multi-agent file | ✅ |
| `docker agent eval agent.yaml ./evals` | Runs eval scenarios in containers (LLM judge, baselines) | 📖 |
| `docker agent sessions diff` · `alias add/list/remove` | Compare recorded sessions · short names for agents | 📖 |

```bash
# one-shot through the Claude bridge, printing only the final answer (tested: 5 s)
docker run --rm --network oda_oda -e CLAUDE_BRIDGE_API_KEY "${HARDEN[@]}" ${IMG}:latest \
  run /app/agent.yaml --flavor compose --exec --last "In one line: which kubectl flag shows the previous container's logs?"
```

**👥 Multi-agent team**: [`examples/a2a-team/`](#-multi-agent-team-example-on_call--log_analyst). `on_call` delegates to `log_analyst` with `transfer_task`. Tested: it found that **v2.3.1 cut the payment-gateway timeout to 500 ms**, which explains the 500s since 14:01.

### ② Distribution: share agents through an OCI registry (optional, not used here)

Docker Agent can publish an agent **config** (the YAML, not a runnable image) to any OCI registry, so others can run it with one command. **This project does not publish any**: all our setups (Compose, Kubernetes, the fixer demo) run the YAML that ships inside the runtime image or is mounted from a ConfigMap. The commands below are for your own registry if you want this.

| Command | What it does | Tested |
|---|---|---|
| `docker agent share push agent.yaml <registry>/<repo>:<tag>` | Pushes the **agent config** (not a runnable image) as an OCI artifact | ✅ earlier (CI used to publish ours; removed to avoid confusion with the runtime images) |
| `docker agent share pull <registry>/<repo>:<tag>` | Downloads it locally | ✅ earlier |
| `docker agent run <registry>/<repo>:<tag>` | Runs straight from the registry | ✅ earlier (`--dry-run`) |
| `… share push --key file://~/.ssh/id_ed25519` / `share pull --key …` | Signs the artifact / verifies the signature | 📖 |

> 📦 **Artifact vs image.** An agent-config artifact is just the **YAML** that a local `docker agent` runs. `opendevops-agent-runtime:<tag>` is the **runnable container** for Docker Compose and Kubernetes, and it's the only thing this project publishes.

### ③ Services: expose an agent

| Command | Exposes | Auth | Tested here |
|---|---|---|---|
| `docker agent serve api agent.yaml` | Native REST + SSE sessions (section F, Compose, Kubernetes) | `--auth-token` | ✅ |
| `docker agent serve chat agent.yaml` | OpenAI-compatible `/v1/chat/completions` | `--api-key-env` | ✅ |
| `docker agent serve mcp agent.yaml --http` | The agent as an **MCP tool** for other AI clients | `--auth-token` (HTTP) | ✅ |
| `docker agent serve a2a team.yaml --agent log_analyst` | The agent as an **A2A** (Agent-to-Agent) service | `--auth-token` | ✅ (server) |
| `docker agent serve acp agent.yaml` | Agent Client Protocol (editor integrations, stdio) | n/a | 📖 |

**🔌 MCP over HTTP with curl** (tested: no token → 401; `tools/list` → one tool `root`; `tools/call` → answer in 3 s):

```bash
T=$(openssl rand -hex 24)
docker run -d --name oda-mcp --network oda_oda -p 127.0.0.1:8096:8080 -e CLAUDE_BRIDGE_API_KEY "${HARDEN[@]}" ${IMG}:latest \
  serve mcp /app/agent.yaml --flavor compose --http --listen 0.0.0.0:8080 --auth-token "$T"
for i in $(seq 1 20); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8096/mcp)" != 000 ] && break
  [ "$(docker inspect -f '{{.State.Running}}' oda-mcp)" = true ] || { docker logs oda-mcp | tail -5; break; }
  sleep 1
done
M=http://localhost:8096/mcp
curl -s -H 'Content-Type: application/json' -H 'Accept: application/json,text/event-stream' -H "Authorization: Bearer $T" -X POST $M \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | sed -n 's/^data: //p' | jq -c '[.result.tools[].name]'
curl -s -H 'Content-Type: application/json' -H 'Accept: application/json,text/event-stream' -H "Authorization: Bearer $T" -X POST $M \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"root","arguments":{"message":"In one line: kubectl flag for previous container logs?"}}}' \
  | sed -n 's/^data: //p' | jq -r '.result.content[0].text'
docker rm -f oda-mcp
```

**🤝 A2A server with curl (A2A v1.0 JSON-RPC).** This was tested: `log_analyst` answered with the root cause from its logs. The agent card is at `/.well-known/agent-card.json` (401 without the token when `--auth-token` is set).

```bash
docker run -d --name log-analyst --network oda_oda -e CLAUDE_BRIDGE_API_KEY "${HARDEN[@]}" -v "$PWD/examples/a2a-team:/team:ro" ${IMG}:latest \
  serve a2a /team/team.yaml --agent log_analyst --listen 127.0.0.1:8080
until docker logs log-analyst 2>&1 | grep -q 'Listening on'; do sleep 1; done   # A2A listens on loopback, so wait on its log
docker run --rm --network container:log-analyst curlimages/curl:8.11.1 -s http://127.0.0.1:8080/invoke -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":{"messageId":"m1","role":"ROLE_USER","parts":[{"text":"Why are checkout requests failing since 2 p.m.?"}]}}}'
docker rm -f log-analyst
```

> ⚠️ **docker-agent → docker-agent over A2A didn't work in our v1.150.0 test.** The `a2a` toolset of one docker-agent couldn't call another docker-agent started with `serve a2a`. In plain terms, the two sides are built on different generations of the A2A library:
> 1. **Different A2A SDKs.** `serve a2a` (`pkg/a2a/server.go`) uses `a2a-go/v2` and publishes an A2A v1.0 card (`supportedInterfaces`). The `a2a` toolset client (`pkg/tools/a2a/a2a.go`) uses the older `a2a-go v0.3.15`: it reads the card's `url` and sends JSON-RPC streaming messages. In our test the client stopped with `no compatible transports found`.
> 2. **No auth on card discovery.** The client fetches the agent card first and only then adds your configured `headers` (`pkg/tools/a2a/a2a.go:197-210`). So a server protected with `--auth-token` rejects the discovery request.
> 3. **Private addresses are blocked by default.** The client is wired to refuse loopback/private IPs unless the toolset sets `allow_private_ips: true` (`pkg/tools/a2a/a2a.go:182-187`).
>
> **What does work:** external A2A v1.0 clients calling `serve a2a` (tested with curl above), and the `a2a` toolset calling remote agents that speak the older protocol. That's why Docker lists A2A as supported. For two agents that work together, use `sub_agents` inside one file (tested). A source review by Codex confirmed points 2 and 3 and the SDK split in point 1. The exact error comes from our live test, not from the source.

---

## 🏠 Run it securely on your own machine (local-only)

This is the recommended way for one engineer to use the agent on their own laptop:
- **Nothing is reachable from the network.**
- **The key lives only in the Keychain and in shell variables.** No key file, no `.env`, nothing in shell history, and nothing in `ps` from your curl calls.
- **Everything is torn down afterwards.**

**Prerequisites:**
- Docker (OrbStack or Docker Desktop) and `jq` (`brew install jq`).
- For the free local model: [Docker Model Runner](https://docs.docker.com/ai/model-runner/), then `docker model pull ai/smollm2` (see backend A).

**Steps** (each one is a numbered subsection below):
1. Create a random key in the Keychain (once).
2. Load the key into your shell (every new terminal).
3. Start the agent on `127.0.0.1` only.
4. Call it without putting the key on the command line.
5. Check that nothing outside your machine can reach it.
6. Rotate the key and tear everything down when you're finished.

### 🎯 Threat model: what each control protects

| 🧱 Control | 🛡️ Protects against | ✅ Verified |
|---|---|---|
| `-p 127.0.0.1:<port>:…` (never `-p <port>:…`) | Anyone on your Wi-Fi/LAN reaching the agent | LAN IP → unreachable; `lsof` shows `127.0.0.1` only |
| Bearer key on **every** request | Other local processes and **other containers** (OrbStack lets containers reach host loopback) | Other container → `401` without the key |
| Key stored in the **macOS Keychain** | Plaintext key files, dotfiles, git leaks | Keychain round-trip; key never printed |
| Key loaded into a **shell variable**, never typed | Shell history | `0` history matches |
| `printf … \| curl -K -` (header on stdin; `printf` is a shell builtin) | The key showing in `ps` or in a temp file during requests | `200` with the stdin header, `401` without |
| Rotation **recreates** containers | Old keys staying valid (a running container keeps its original env and args) | Old key → `401`, new key → `200` |
| `--read-only`, `--cap-drop ALL`, non-root, `no-new-privileges` | A compromised agent process changing the container | All examples use `HARDEN` |
| Short-lived (2h) **read-only** ServiceAccount token (SRE agent) | Cluster writes / long-lived credential theft | RBAC `can-i` matrix (section E) |

> ⚠️ **Exposures that remain (accepted for a single-user laptop, documented on purpose):**
> - **Docker config:** `docker inspect` shows the key, as an env var for `serve chat` or as the `--auth-token` argument for `serve api`.
>   - `--api-key-env` reads only the real process environment and ignores `--env-from-file`; verified, the server refuses to start that way.
>   - `serve api` has no env-var option at all.
>   - Anyone who can run `docker` on your Mac already has root-equivalent access. **Never** use this setup on a shared Docker host.
> - **Key creation:** while the key is being created, it is briefly an argument to `security add-generic-password`. If that matters to you, run `security add-generic-password -U -a "$USER" -s oda-agent-api-key -w` with no value and type a long random string at the prompt.

### 1️⃣ One-time: create a random key in the Keychain

```bash
security add-generic-password -U -a "$USER" -s oda-agent-api-key -w "$(openssl rand -hex 24)"
```

> 🐧 Linux: `secret-tool store --label=oda-agent-api-key service oda-agent-api-key` (libsecret), or `pass insert oda/agent-api-key`.

### 2️⃣ Every new terminal: load the key (and fail loudly if it's missing)

```bash
AGENT_API_KEY=$(security find-generic-password -a "$USER" -s oda-agent-api-key -w) && [ -n "$AGENT_API_KEY" ] \
  && export AGENT_API_KEY && echo "🔑 key loaded" || echo "❌ key not found in the Keychain, run step 1"
export IMG=quickbooks2018/opendevops-agent-runtime
HARDEN=(--read-only --tmpfs /tmp --tmpfs /home/nonroot:uid=65532,gid=65532 --cap-drop ALL --security-opt no-new-privileges)
```

### 3️⃣ Start the agent on loopback only

```bash
docker pull ${IMG}:latest
docker rm -f oda oda-api 2>/dev/null   # remove containers left over from a previous run

# 💬 OpenAI-compatible chat API (key passed as an env var, fails closed if missing)
docker run -d --name oda -p 127.0.0.1:8084:8083 -e AGENT_API_KEY "${HARDEN[@]}" ${IMG}:latest \
  serve chat /app/agent.yaml --listen 0.0.0.0:8083 --api-key-env AGENT_API_KEY --safety strict --flavor local

# 🧩 (optional) native API with persistent sessions. It fails OPEN without a token, so ${…:?} aborts if the key is empty
# docker run -d --name oda-api -p 127.0.0.1:8090:8080 "${HARDEN[@]}" -v oda-api-data:/data ${IMG}:latest \
#   serve api /app/agent.yaml --flavor local --listen 0.0.0.0:8080 \
#   --auth-token "${AGENT_API_KEY:?AGENT_API_KEY is empty}" --session-db /data/sessions.db

# wait up to 30 s; stop with a clear message if the container died
for i in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8084/v1/models)" = 401 ] && echo "✅ up and requiring a key" && break
  [ "$(docker inspect -f '{{.State.Running}}' oda 2>/dev/null)" = true ] || { echo "❌ container stopped:"; docker logs oda | tail -5; break; }
  sleep 1
done
```

> ℹ️ Inside the container it must listen on `0.0.0.0` so Docker can forward to it. The `127.0.0.1:` in `-p` is what keeps it **off the network**.

### 4️⃣ Call it without exposing the key in `ps` or a temp file

```bash
printf 'header = "Authorization: Bearer %s"\n' "$AGENT_API_KEY" | \
  curl -s -K - http://localhost:8084/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"root","messages":[{"role":"user","content":"In one line: first kubectl command for a CrashLoopBackOff pod?"}]}' \
  | jq -r '.choices[0].message.content'
```

> The other sections use `-H "Authorization: Bearer $AGENT_API_KEY"` for readability. That puts the key in `ps` while curl runs, so prefer the `printf | curl -K -` form on any machine with other users.

### 5️⃣ Verify it is local-only

```bash
lsof -nP -iTCP:8084 -sTCP:LISTEN | awk 'NR>1{print $9}'                    # → 127.0.0.1:8084 only
LAN_IP=$(ipconfig getifaddr "$(route -n get default | awk '/interface:/{print $2}')")
curl -s -m 3 -o /dev/null -w "LAN $LAN_IP: %{http_code}\n" http://$LAN_IP:8084/v1/models   # → 000 (unreachable)
curl -s -o /dev/null -w 'no key: %{http_code}\n' http://localhost:8084/v1/models          # → 401
```

> 🔬 The strongest proof is to run the LAN `curl` from **another device** on the same network.

### 6️⃣ Rotate and tear down

```bash
# 🔄 rotate: new key in the Keychain, reload it, then RECREATE the containers
# (a running container keeps its original key; `docker restart` is not enough)
security add-generic-password -U -a "$USER" -s oda-agent-api-key -w "$(openssl rand -hex 24)"
AGENT_API_KEY=$(security find-generic-password -a "$USER" -s oda-agent-api-key -w) && export AGENT_API_KEY
docker rm -f oda && docker run -d --name oda -p 127.0.0.1:8084:8083 -e AGENT_API_KEY "${HARDEN[@]}" ${IMG}:latest \
  serve chat /app/agent.yaml --listen 0.0.0.0:8083 --api-key-env AGENT_API_KEY --safety strict --flavor local

# 🧹 tear down everything (containers, session volume, secrets in this shell)
docker rm -f oda oda-api 2>/dev/null; docker volume rm oda-api-data 2>/dev/null; unset AGENT_API_KEY AUTH
# 🗑️ remove the key from the Keychain entirely
security delete-generic-password -a "$USER" -s oda-agent-api-key >/dev/null && echo "key removed"
```

### ✅ Local security checklist

- [ ] 🏠 Every `-p` starts with `127.0.0.1:`
- [ ] 🔑 The key lives only in the Keychain, never in a file, a `.env`, or git
- [ ] ⌨️ The key is never typed or pasted; it's always `$AGENT_API_KEY`, sent with `printf | curl -K -`
- [ ] 🧩 `serve api` is **always** started with `--auth-token "${AGENT_API_KEY:?}"`
- [ ] 🧱 Every container runs with `HARDEN` (read-only, no capabilities, non-root)
- [ ] ⏱️ Kubernetes tokens are short-lived (`--duration=2h`), read-only, and in a `mktemp -d` dir with mode `600`
- [ ] 🔄 After rotating, containers are **recreated**, not restarted
- [ ] 🧹 Tear down when done (`unset AGENT_API_KEY AUTH`), and rotate if you ever shared your screen or logs

---

## 🔌 Backends

A backend is where the agent gets its answers. You pick one per container. Most people should start with **B**. The sections appear in this order:

- **A. Local model:** free and offline. Good for smoke tests, not for real answers.
- **B. Claude Code CLI bridge with Docker Compose:** the standard setup, using your Claude subscription.
- **C. Claude Code inside the container:** one container, no bridge, chat only.
- **E. Kubernetes SRE agent:** investigates a live cluster with read-only tools and remembers facts.
- **F. Native API:** the same SRE agent with saved sessions you drive with `curl`.
- **G. Inside local Kubernetes:** the agent and the bridge in one Pod.
- **G2. Lead SRE fixer:** proposes fixes and, by default, applies each one only after you approve it.
- **D. Cloud OpenAI:** the image default; not tested yet.

### A. 🧠 Local model: Docker Model Runner (token-free)

- **Prereqs:** [Docker Model Runner](https://docs.docker.com/ai/model-runner/) with host TCP on `12434`, then `docker model pull ai/smollm2`.
- **How it works:** `models.local` uses provider `dmr` with `base_url: http://host.docker.internal:12434/engines/v1`.
- **When to use it:** smoke tests and CI-style validation of the request path at zero cost. `smollm2` answers are often *wrong*, so it proves plumbing, not quality.

### B. 🌉 Claude Code CLI bridge: agent + bridge with Docker Compose ⭐

The standard way to run the agent with a real Claude model, **with nothing running on your Mac except Docker**. [`compose.yaml`](./compose.yaml) starts two hardened services:

| Service | Image | Role | Reachable from |
|---|---|---|---|
| `agent` | `…@sha256:8561da6d…` (`sha-3a791eb`) | `docker-agent serve api /app/agent.yaml --flavor compose` | **Your Mac only**: `127.0.0.1:8090` |
| `claude-code-cli-bridge` | `…@sha256:461a49cf…` (`bridge-sha-3a791eb`) | Pre-authenticated `claude` CLI behind an OpenAI-compatible API | **The agent only** (private network `oda`, no published port, bearer key) |

▶️ **Run it** (each step is a copy-paste block in the bridge section):
1. [🔑 Load the three Keychain secrets](#-one-time-setup-three-secrets-in-the-keychain) (one-time creation + per-terminal loader).
2. [🐳 `docker compose up -d` and wait for `/health`](#-docker-compose-run-and-call-it).
3. [📡 Call it with curl](#-api-reference-with-curl): health, auth checks, sessions, streaming, follow-ups (`A=http://localhost:8090; AG=agent`).

> 🗂️ **History:** an earlier iteration used `pi-agents` bridges running directly on the Mac (`host.docker.internal:18188/18288`, `--flavor claude-bridge|codex-bridge`). Those host bridges were removed. The flavors remain in `agent.yaml` for anyone who runs their own host bridge, with `claude-bridge` now requiring `CLAUDE_BRIDGE_API_KEY`. Verification rows 4–6 record those results.

### C. 🤖 Claude Code inside the container (`:claude-code`, harness)

Use this when you want a single container that answers with Claude, without running the bridge. It is chat only: Claude Code's own tools are switched off.

**Steps:**
1. Pick one credential option from the table below.
2. Start `oda-cc` with that credential and wait until it listens.
3. Optional: run the tool-denial check to prove Claude Code can't read files.
4. Remove the container when you're done.

For each request, docker-agent runs this command directly (no shell):

```text
claude --print --verbose --dangerously-skip-permissions --include-partial-messages --output-format stream-json --model haiku -p "<instruction + conversation>"
```

**Why the bypass flag is safe here.** docker-agent's `--safety` does not govern a harness, and the bypass flag skips Claude Code's permission prompts. The image therefore ships [`claude-code/managed-settings.json`](./claude-code/managed-settings.json) at `/etc/claude-code/managed-settings.json`:
- It is the highest-precedence Claude Code settings file, and users or projects cannot override it.
- It **denies every built-in tool** offered by Claude Code 2.1.302: `Bash`, `Read`, `Write`, `Edit`, `WebFetch`, `WebSearch`, `Agent`, `RemoteTrigger`, `CronCreate`, `Workflow`, `SendMessage`, `ToolSearch` and more.
- It sets `disableAllHooks: true`.
- The verified `stream-json` init tool list is **`[]`**, so the harness is text-in, text-out.

**Credentials.** Pick one. The macOS Keychain login can't be reused in Linux and is never extracted.

| Option | How | Where the secret lives |
|---|---|---|
| 1. OAuth token (subscription) | Run `claude setup-token` on any machine with a browser, then `-e CLAUDE_CODE_OAUTH_TOKEN` | A file outside git (`chmod 600`), read into the env at run time |
| 2. API key (API billing) | Create a key at <https://console.anthropic.com/settings/keys>, then `-e ANTHROPIC_API_KEY` | Same |
| 3. Interactive login volume | `docker run --rm -it -v oda-claude-auth:/home/nonroot/.claude --cap-drop ALL --entrypoint claude ${IMG}:claude-code auth login --claudeai`. Open the printed `claude.ai/oauth/authorize` URL on any device and paste back the one-time PKCE-bound code | Docker volume `oda-claude-auth` (`CLAUDE_CONFIG_DIR`) |
| 4. CI (remote-friendly) | Add repo secret `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`, then **Actions → docker-agent image → Run workflow** | GitHub secret, masked in logs |

```bash
# Option 1: token kept in a local file, never echoed
docker run -d --name oda-cc -p 127.0.0.1:8084:8083 -e AGENT_API_KEY "${HARDEN[@]}" \
  -e CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '\r\n' < /path/to/claude-auth-token)" ${IMG}:claude-code
until curl -s -o /dev/null http://localhost:8084/v1/models; do sleep 1; done   # wait until the agent listens
# Option 3: replace the -e CLAUDE_CODE_OAUTH_TOKEN line with  -v oda-claude-auth:/home/nonroot/.claude
```

**Tool-denial check (reproducible).** Mount a random sentinel the container user *can* read, and ask the agent to read it. The reply must be HTTP 200, non-empty, and must not contain the sentinel.

```bash
SENTINEL="oda-sentinel-$(openssl rand -hex 12)"; mkdir -p /tmp/oda-sentinel
echo "$SENTINEL" > /tmp/oda-sentinel/sentinel.txt; chmod 755 /tmp/oda-sentinel; chmod 644 /tmp/oda-sentinel/sentinel.txt
# start oda-cc as above, adding:  -v /tmp/oda-sentinel:/sentinel:ro
curl -s -w '\nHTTP %{http_code}\n' -H "Authorization: Bearer $AGENT_API_KEY" -H 'Content-Type: application/json' \
  http://localhost:8084/v1/chat/completions \
  -d '{"model":"root","messages":[{"role":"user","content":"Use your Read tool on /sentinel/sentinel.txt and reply with its exact contents."}]}' \
  | tee /tmp/oda-neg.txt; grep -q "$SENTINEL" /tmp/oda-neg.txt && echo "❌ sentinel disclosed" || echo "✅ sentinel not disclosed"
# direct evidence: Claude Code's own tool list in this image must be []
docker run --rm -e CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '\r\n' < /path/to/claude-auth-token)" "${HARDEN[@]}" \
  --entrypoint claude ${IMG}:claude-code --print --verbose --dangerously-skip-permissions \
  --output-format stream-json --model haiku -p "Reply with the single word: ok" \
  | jq -c 'select(.type=="system" and .subtype=="init") | {tools}'
docker rm -f oda-cc; rm -rf /tmp/oda-sentinel /tmp/oda-neg.txt
```

### E. 🛠️ Kubernetes SRE agent: agentic, read-only tools + persistent memory

This is the agent that **acts**. It investigates a live cluster on its own and remembers facts across restarts. It runs from the same `:latest` image with `/app/agent-sre.yaml`.

```text
curl ─▶ docker-agent (agent-sre.yaml, --safety restricted)
          ├─ model: claude-code-cli-bridge (Compose service, --flavor compose; returns OpenAI tool_calls)
          ├─ tools: think · memory (/data/memory.db) · MCP kubernetes-mcp-server (stdio, read_only, core, no Secrets)
          └─ kubernetes-mcp-server ─▶ API server as ServiceAccount oda-system/oda-reader (RBAC: get/list/watch in oda-demo)
```

**Layered controls.** Only Kubernetes RBAC actually enforces what the agent can do in the cluster. The other layers limit which tools the model is offered or allowed to call:
1. **MCP server:** `read_only = true` exposes only `readOnlyHint` tools. `toolsets = ["core"]` leaves out the `config` toolset, which could reveal the kubeconfig token. `Secret` is in `denied_resources`.
2. **docker-agent `--safety restricted`:** read-only tools auto-approve, and any other tool is **denied** without prompting. The only explicit allow is `add_memory` / `update_memory`, which write to the agent's own SQLite file, not the cluster.
3. **Kubernetes RBAC:** the `oda-reader` ServiceAccount can `get/list/watch` pods, logs, events, workloads, services and configmaps in `oda-demo` only. It cannot touch Secrets, exec, write, or other namespaces.
4. **Container hardening:** non-root, read-only rootfs, `cap-drop ALL`. The kubeconfig is mounted read-only and holds a **short-lived** token. This contains the process; it doesn't decide what the API allows.

> 🧾 **What the agent can still read:** pod specs (including plaintext `env` values), logs and ConfigMaps in `oda-demo`. Denying Secrets does **not** stop credentials leaking if workloads put them in env, logs or ConfigMaps. Point the agent only at namespaces whose contents may be shown to its users **and** to the model backend, and drop `configmaps` from the Role if you don't need it.

> ⚠️ Use `--safety restricted` here, **not `strict`**. In headless `serve chat`, `strict` denies *every* tool call, because nobody can answer the approval prompt.

**Run it.** The cluster used here is OrbStack's built-in Kubernetes (`orb start k8s`). You also need the Compose stack from section B running (it provides the bridge) and `CLAUDE_BRIDGE_API_KEY` loaded.

**Steps** (they match the numbered comments in the block):
1. Create the lab: two broken workloads and a read-only identity.
2. Build a kubeconfig with a 2-hour token for that read-only identity.
3. Start the SRE agent with a volume for its memory.
4. Ask it to investigate the `oda-demo` namespace.

```bash
# 1. lab: two broken workloads + read-only identity
kubectl --context orbstack apply -f k8s-lab/demo-broken.yaml -f k8s-lab/rbac-readonly.yaml

# 2. kubeconfig for the read-only ServiceAccount (2h token; the API server name is in the cert SANs)
KDIR=$(mktemp -d)   # private 0700 dir (no predictable /tmp path)
CA=$(kubectl --context orbstack config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
TOKEN=$(kubectl --context orbstack create token oda-reader -n oda-system --duration=2h)
printf 'apiVersion: v1\nkind: Config\nclusters: [{name: k, cluster: {server: "https://kubernetes.default.svc.cluster.local", certificate-authority-data: "%s"}}]\nusers: [{name: oda-reader, user: {token: "%s"}}]\ncontexts: [{name: oda, context: {cluster: k, user: oda-reader, namespace: oda-demo}}]\ncurrent-context: oda\n' "$CA" "$TOKEN" > $KDIR/config
chmod 600 $KDIR/config; unset CA TOKEN   # OrbStack maps bind mounts to the container user; on Linux use an ACL for UID 65532

# 3. start the SRE agent (memory volume keeps facts across restarts)
# docker run never refreshes an existing local tag, so pull explicitly (or pin sha-<7>)
docker pull ${IMG}:latest
docker volume create oda-memory
# needs the Compose stack from section B (for the bridge) and CLAUDE_BRIDGE_API_KEY loaded
docker run -d --name oda-sre -p 127.0.0.1:8086:8083 -e AGENT_API_KEY -e CLAUDE_BRIDGE_API_KEY "${HARDEN[@]}" \
  --network oda_oda -v $KDIR:/kube:ro -v oda-memory:/data ${IMG}:latest \
  serve chat /app/agent-sre.yaml --flavor compose --listen 0.0.0.0:8083 --api-key-env AGENT_API_KEY --safety restricted
until curl -s -o /dev/null http://localhost:8086/v1/models; do sleep 1; done

# 4. ask it to investigate
curl -s -H "Authorization: Bearer $AGENT_API_KEY" -H 'Content-Type: application/json' http://localhost:8086/v1/chat/completions \
  -d '{"model":"root","messages":[{"role":"user","content":"Investigate namespace oda-demo: which workloads are unhealthy and why? Give root cause and the fix for each."}]}' \
  | jq -r '.choices[0].message.content'
```

**See which tools it called.** Add `--debug --log-file /dev/stderr` to the `serve chat` args, then run:

```bash
docker logs oda-sre 2>&1 | grep -E 'auto-approved|denied' | grep -oE 'tool=[a-z_]+ source=[a-z_"]+[^ ]*'
```

**Clean up:** `docker rm -f oda-sre; docker volume rm oda-memory; rm -rf $KDIR; kubectl --context orbstack delete ns oda-demo oda-system`

**Cost:** about 70k tokens for a full investigation through the Claude bridge, and about 15–45k for short questions. Keep prompts targeted.

### F. 🧩 Native API (`serve api`): sessions over curl

Use this when you want to see everything the agent did (tool calls, results, token use) or keep conversations across restarts. It runs the same SRE agent as section E behind a different API.

**Steps:**
1. Read the security notes below; `serve api` must always get `--auth-token`.
2. Start the agent on `127.0.0.1:8092` and wait for `/health`.
3. Create a session, send a question, then a follow-up in the same session.
4. Read the stored conversation, delete the session, and clean up.

Docker Agent ships **two HTTP servers**, and both work with plain `curl`:

| | 💬 `serve chat` (sections A–E) | 🧩 `serve api` (this section) |
|---|---|---|
| 🗣️ Protocol | OpenAI Chat Completions (`/v1/chat/completions`) | Docker Agent native REST + **SSE event stream** (`/api/...`) |
| 🧠 State | Stateless (or an in-memory cache via `X-Conversation-Id`) | **Persistent sessions** in SQLite (`--session-db`), which survive restarts |
| 🔍 Visibility | Final answer only | Every event: tool calls, tool results, token usage, titles |
| 🔐 Auth flag | `--api-key-env VAR` (**env var**) | `--auth-token VALUE` (**CLI flag only**, no env-var option) |
| 🚫 Without a token | **Refuses to start** (fails closed) | ⚠️ **Starts with no auth** and only prints a warning (fails open) |
| 🧑‍💻 Best for | SDKs, chat UIs, gateways | Dashboards, automation, auditing what the agent did |

#### 🔒 Keep it internal and use an environment variable

- 🏠 **Publish on loopback only:** `-p 127.0.0.1:8092:8080`.
  - Verified: this Mac → `200`, the LAN IP → **unreachable**.
  - Other containers on the same Mac **can** reach it via `host.docker.internal`, and get **401 without the token**. That's why the token is mandatory even locally.
- 🔑 **Token from an env var:** the token lives in `AGENT_API_KEY` in *your* shell, and the shell expands it into the flag: `--auth-token "$AGENT_API_KEY"`.
  - ⚠️ Because `serve api` only takes a flag, the value ends up in the container's arguments, so `docker inspect` shows it to anyone who can run Docker commands (already root-equivalent on that host).
  - ☸️ On **Kubernetes**, put it in a Secret and use env-var expansion: `args: ["--auth-token", "$(AGENT_API_KEY)"]`. The Pod spec then shows only `$(AGENT_API_KEY)`, not the value.
- 🚨 **Never start `serve api` without `--auth-token`.** It would serve every session to anyone who can reach it.
- 🧑‍✈️ **The token holder is an admin.** The API can change a session's safety policy (`PATCH /api/sessions/:id/safety-policy`) and auto-approve all tools (`POST /api/sessions/:id/tools/toggle`). With the SRE agent, the cluster stays protected by RBAC and the read-only MCP server, but memory deletes would be allowed.
- ℹ️ The startup banner always says *"The API has no authentication"* for non-loopback binds, **even when a token is set**. That's misleading upstream text. Check the `401` yourself.

#### ▶️ Run it (SRE agent + persistent sessions)

Prerequisite: the lab and the `$KDIR` kubeconfig from section E.

```bash
docker pull ${IMG}:latest
docker volume create oda-api-data
# needs the Compose stack from section B (for the bridge); uses host port 8092 so it doesn't clash with Compose's 8090
docker run -d --name oda-api -p 127.0.0.1:8092:8080 -e CLAUDE_BRIDGE_API_KEY "${HARDEN[@]}" \
  --network oda_oda -v $KDIR:/kube:ro -v oda-api-data:/data ${IMG}:latest \
  serve api /app/agent-sre.yaml --flavor compose --listen 0.0.0.0:8080 \
  --auth-token "${AGENT_API_KEY:?AGENT_API_KEY is empty}" --session-db /data/sessions.db
# wait up to 30 s for the API (a curl right after `docker run` returns 000 while it starts)
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8092/health)
  if [ "$code" = 200 ]; then echo "✅ ready after ${i}s"; break; fi
  if [ "$(docker inspect -f '{{.State.Running}}' oda-api 2>/dev/null)" != true ]; then echo "❌ container not running:"; docker logs oda-api 2>&1 | tail -5; break; fi
  sleep 1
done
```

#### 📡 Talk to it with curl

```bash
A=http://localhost:8092; AUTH="Authorization: Bearer $AGENT_API_KEY"

# health (no auth needed) and auth checks: 200, then 401
curl -s -o /dev/null -w '%{http_code}\n' $A/health
curl -s -o /dev/null -w '%{http_code}\n' $A/api/agents

# list agents (the agent id is the config file name without .yaml)
curl -s -H "$AUTH" $A/api/agents | jq -c '.[] | {name, description}'

# create a session and keep its id
SID=$(curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST $A/api/sessions -d '{}' | jq -r .id)

# run the agent in that session (streams Server-Sent Events: tool calls, results, tokens, ...)
curl -sN -H "$AUTH" -H 'Content-Type: application/json' -X POST $A/api/sessions/$SID/agent/agent-sre \
  -d '{"messages":[{"role":"user","content":"List the pods in namespace oda-demo with their status, one line each."}]}' \
  | grep '^data:' | sed 's/^data: //' | jq -r '.type' | sort | uniq -c

# follow-up in the SAME session (send only the new message; the server keeps the history)
curl -sN -H "$AUTH" -H 'Content-Type: application/json' -X POST $A/api/sessions/$SID/agent/agent-sre \
  -d '{"messages":[{"role":"user","content":"Which of those pods has the image problem? One sentence."}]}' >/dev/null

# read the stored conversation (answers, token totals, auto-generated title)
curl -s -H "$AUTH" $A/api/sessions/$SID | jq -r '.messages[]? | select(.message.role=="assistant" and (.message.content|length)>0) | .message.content'
curl -s -H "$AUTH" $A/api/sessions | jq -c '.[] | {id, title, num_messages}'

# delete the session
curl -s -H "$AUTH" -X DELETE $A/api/sessions/$SID
```

**Clean up:** `docker rm -f oda-api; docker volume rm oda-api-data; unset AUTH SID`

### G. ☸️ Run the SRE agent + bridge sidecar inside local Kubernetes (OrbStack)

Use this to run the SRE agent and the bridge in your local Kubernetes cluster instead of Docker Compose.

**One Pod, two containers.** The agent reaches the bridge over the Pod's shared loopback, so nothing outside the Pod (not even other Pods) can talk to the bridge.

**Steps:**
1. Load the three Keychain secrets ([setup](#-one-time-setup-three-secrets-in-the-keychain)).
2. Follow [☸️ Kubernetes: run and call it](#%EF%B8%8F-kubernetes-one-pod-two-containers-run-and-call-it): create the lab, the Secret, deploy, and port-forward.
3. Check your cluster's API server address and adapt `networkpolicy.yaml` (egress discovery below).
4. Run the control checks below.

```text
you ─curl─▶ 127.0.0.1:8091 ─port-forward─▶ Service oda-agent (ClusterIP) ─▶ Pod oda-agent (oda-system)
                                                                              ├─ 🤖 agent: serve api agent-sre.yaml --flavor in-pod
       other Pods ──✖ blocked (tested) ──────────────┘                         │     ├─ tools: kubernetes-mcp-server (SA oda-reader, read-only)
                                                                              │     └─ PVC /data: sessions + memory
                                                                              └─ 🌉 claude-code-cli-bridge (127.0.0.1:18188, bearer key)
                                                                                    └─▶ Anthropic (HTTPS 443, CLAUDE_CODE_OAUTH_TOKEN)
```

| 📄 File (`kubernetes/`) | Purpose |
|---|---|
| `deployment.yaml` | 1 replica, `Recreate`. **Container `agent`** (digest-pinned agent image, `--flavor in-pod`, `/ready` + `/health` probes) and **container `claude-code-cli-bridge`** (digest-pinned bridge image, loopback only, **exec probes** because kubelet probes dial the Pod IP). Both: non-root 65532, read-only rootfs, `drop: [ALL]`, seccomp `RuntimeDefault`, limits |
| `mcp-config.toml` | kubernetes-mcp-server config (`in-cluster`, `read_only`, `core` tools, Secrets denied), rendered by a `configMapGenerator` with a **hashed name**, so a change rolls the Pod |
| `pvc.yaml` | 100Mi, so sessions and memory survive Pod restarts |
| `service.yaml` | `ClusterIP` only, port 8080 (agent). The bridge has no Service |
| `networkpolicy.yaml` | **Ingress:** deny all in-cluster traffic. **Egress:** only DNS, the Kubernetes API (OrbStack IPs) and **HTTPS 443 to public IPs** for Anthropic |
| `kustomization.yaml` | `kubectl apply -k kubernetes/` |

**Secret `oda-agent-api-key`** needs three keys: `AGENT_API_KEY`, `CLAUDE_BRIDGE_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN`. The values never appear in YAML: `$(AGENT_API_KEY)` is expanded by the kubelet, and the bridge reads the other two as env vars.

▶️ **Commands** (Secret, deploy, port-forward, investigation, read-only proof): [🌉 Claude Code CLI bridge → ☸️ Kubernetes](#%EF%B8%8F-kubernetes-one-pod-two-containers-run-and-call-it).

**🧭 Egress discovery (adapt `networkpolicy.yaml` to your cluster):**

```bash
kubectl --context orbstack get svc kubernetes -o jsonpath='{.spec.clusterIP}{"\n"}'
kubectl --context orbstack get endpointslices -l kubernetes.io/service-name=kubernetes \
  -o jsonpath='{.items[0].endpoints[0].addresses[0]}:{.items[0].ports[0].port}{"\n"}'
```

**🔐 Verify the controls:**

```bash
# another Pod can reach neither the agent (Service) nor the bridge (Pod IP): both print 000
PIP=$(kubectl --context orbstack -n oda-system get pod -l app=oda-agent -o jsonpath='{.items[0].status.podIP}')
kubectl --context orbstack run np-test -n oda-demo --rm -i --restart=Never -q --image=curlimages/curl:8.11.1 -- \
  sh -c "curl -s -m4 -o /dev/null -w 'agent=%{http_code} ' http://oda-agent.oda-system.svc:8080/health; curl -s -m4 -o /dev/null -w 'bridge=%{http_code}\n' http://$PIP:18188/health"
# no secret values in the Deployment (only $(AGENT_API_KEY) / secretKeyRef)
kubectl --context orbstack -n oda-system get deploy oda-agent -o jsonpath='{.spec.template.spec.containers[0].args}'; echo
# what the agent's identity may do
for v in "get pods -n oda-demo" "delete pods -n oda-demo" "get secrets -n oda-demo"; do
  echo "$v → $(kubectl --context orbstack auth can-i ${=v} --as system:serviceaccount:oda-system:oda-reader)"; done
```

> 🔑 **"Not in the Pod spec"** means only that: inside the running Pod, the values are in the containers' env (and the agent's argv). Anyone with `exec`, node access or `get secrets` in `oda-system` can still read them, so restrict those with RBAC.
> 🧱 **NetworkPolicy scope:** it blocks ordinary Pod-to-Pod traffic (verified). Node-originated and host-network traffic depends on the CNI, so **bearer auth stays mandatory** on both hops.
> 📌 **Image pins:** both containers pin `@sha256:…` digests from CI. After a new build, update them from `docker buildx imagetools inspect ${IMG}:sha-<7>` / `:bridge-sha-<7>`.
> 🐚 `${=v}` splits words in zsh; in bash use `$v`.

### G2. 🛠️ Lead SRE fixer agent (human-approved fixes)

> 🎬 **Recording a demo or trying it for the first time? Use [DEMO.md](./DEMO.md).** It wraps everything below into a few short commands (`ask`, `change`, `approve`, `reject`, `reset-demo`) with two terminals, step by step. This section is the full reference.

The section G agent can only **read**. This one acts like a **lead DevOps/SRE on call**:
1. 🔍 **Diagnose:** pods, events, logs and the owning Deployment.
2. 📝 **Plan:** root cause, evidence, exact change, risk and rollback.
3. 🛠️ **Fix:** patch the Deployment.
4. ✅ **Verify:** the new Pod is Running.

**By default, every cluster write pauses until a human approves it** with one curl call. An optional hands-free mode skips the approvals; the hard limits below still apply.

```text
you ─curl─▶ 127.0.0.1:8094 ─port-forward─▶ Service oda-agent-fixer ─▶ Pod oda-agent-fixer (oda-system)
                                                                        ├─ 🤖 agent: serve api agent-sre-fixer.yaml (safety: balanced)
   POST /resume {"confirmation":"approve"|"reject"} ──▶ ⏸️ write waits here   ├─ tools: kubernetes-mcp-server (SA oda-fixer, write-capable)
                                                                        └─ 🌉 claude-code-cli-bridge (127.0.0.1:18188)
```

| 📄 File | Purpose |
|---|---|
| `k8s-lab/fixer-guard-policy.yaml` | ValidatingAdmissionPolicy (cluster-scoped, Kubernetes 1.30+). When `oda-fixer` updates a Deployment, only container **images, literal env values, resources and replicas** may change. ServiceAccount, volumes, Secret refs (`envFrom`/`valueFrom`), command, mounts, security context, host namespaces and new containers are rejected |
| `k8s-lab/rbac-fixer.yaml` | ServiceAccount `oda-fixer` and a Role in `oda-demo`. It can read workloads, **patch/update Deployments**, **scale** them and **delete Pods**. Nothing else |
| `kubernetes-fixer/kustomization.yaml` | Overlay on `kubernetes/`: the same hardened two-container Pod, renamed `oda-agent-fixer`, with its own Service, PVC and NetworkPolicies, running as `oda-fixer` |
| `kubernetes-fixer/agent-sre-fixer.yaml` | The Lead SRE agent: `safety: balanced`, `ask` on every write tool, `deny` on exec/run/delete, plus the instruction (diagnose → plan → fix → verify). Mounted from the ConfigMap, so no image rebuild is needed |
| `kubernetes-fixer/mcp-config.toml` | kubernetes-mcp-server with writes enabled, but `pods_exec`, `pods_run` and `resources_delete` are **never exposed**. Secrets are denied |

**🛡️ Five independent guardrails** (a fix has to pass all five):

| Layer | What it enforces |
|---|---|
| 🧑‍⚖️ Human approval (default) | `safety: balanced` + `permissions.ask` on `resources_create_or_update`, `resources_scale` and `pods_delete`. The run pauses (`tool_call_confirmation` event) until `POST /api/sessions/<id>/resume`. ⚠️ This is a **per-session default**: any client holding `AGENT_API_KEY` can switch its session to `autonomous` (tested). The layers below are what actually bound the agent |
| 🧰 Tool surface | Exec, run-a-pod and delete-any-resource tools are disabled in the MCP server and denied in the agent |
| 🚦 Admission policy | RBAC can't limit *which fields* a patch changes, so `fixer-guard-policy.yaml` rejects any Deployment update by `oda-fixer` that touches more than images, literal env, resources or replicas. That closes the indirect path to Secrets (mounting one, `secretKeyRef`, swapping the ServiceAccount) |
| 🔐 RBAC | `oda-demo` only. No create or delete of Deployments, no Secrets, no exec, no other namespace (`kubectl auth can-i` below) |
| 🧭 Instruction | Smallest fix on the owning Deployment. Never invent credentials (it asks you for missing values). Never retry a rejected change |

> ⚠️ **Approval is not enforced against the API-key holder.** In docker-agent v1.150.0, `PATCH /api/sessions/<id>/safety-policy` with `autonomous` turns approvals off for that session (it also overrides the `ask` rules), and `serve api` has no flag to lock it. Treat `AGENT_API_KEY` as **operator credentials**: whoever holds it can approve every change anyway. Even in hands-free mode, the admission policy, RBAC and the disabled tools still bound what the agent can change.

#### ▶️ Deploy (needs the `oda-agent-api-key` Secret from section G and the demo from `k8s-lab/`)

```bash
cd docker-agent
kubectl --context orbstack apply -f k8s-lab/demo-broken.yaml          # the two broken workloads (if not already there)
kubectl --context orbstack apply -f k8s-lab/fixer-guard-policy.yaml   # admission guard: oda-fixer may change only image/env/resources/replicas
kubectl --context orbstack apply -f k8s-lab/rbac-fixer.yaml           # ServiceAccount oda-fixer + Role/RoleBinding in oda-demo
kubectl --context orbstack apply -k kubernetes-fixer                  # Pod oda-agent-fixer (agent + bridge), Service, PVC, policies
kubectl --context orbstack -n oda-system rollout status deploy/oda-agent-fixer --timeout=180s
kubectl --context orbstack -n oda-system get pods -l app=oda-agent-fixer   # 2/2 Running

# what the fixer identity may do → yes yes yes / no no no no no
SA=system:serviceaccount:oda-system:oda-fixer
for v in "get pods -n oda-demo" "patch deployments -n oda-demo" "delete pods -n oda-demo" \
         "create deployments -n oda-demo" "delete deployments -n oda-demo" "get secrets -n oda-demo" \
         "create pods/exec -n oda-demo" "patch deployments -n kube-system"; do
  printf '%-34s %s\n' "$v" "$(kubectl --context orbstack auth can-i ${=v} --as $SA)"; done

# admission guard (server-side dry runs as oda-fixer, nothing changes): first allowed, the other three denied
K="kubectl --context orbstack -n oda-demo"
${=K} patch deploy web --as $SA --dry-run=server --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"nginx:1.27"}]'
${=K} patch deploy api --as $SA --dry-run=server --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/envFrom","value":[{"secretRef":{"name":"any"}}]}]'
${=K} patch deploy api --as $SA --dry-run=server --type=json -p '[{"op":"add","path":"/spec/template/spec/serviceAccountName","value":"default"}]'
${=K} patch deploy web --as $SA --dry-run=server --type=json -p '[{"op":"add","path":"/spec/template/spec/volumes","value":[{"name":"s","secret":{"secretName":"any"}}]}]'
```

#### 🔑 Connect (one terminal)

```bash
kubectl --context orbstack -n oda-system port-forward svc/oda-agent-fixer 8094:8080 >/dev/null 2>&1 &
export AGENT_API_KEY=$(security find-generic-password -a "$USER" -s oda-agent-api-key -w)
api() { printf 'header = "Authorization: Bearer %s"\n' "$AGENT_API_KEY" | curl -s -K - -H 'Content-Type: application/json' "$@"; }
last() { api "$A/api/sessions/$1" | jq -r '[.messages[]? | select(.message.role=="assistant" and (.message.content|length)>0)][-1].message.content'; }
A=http://localhost:8094; AG=agent-sre-fixer

curl -s -o /dev/null -w 'health %{http_code}\n' $A/health                                     # 200
curl -s -o /dev/null -w 'no key %{http_code}\n' $A/api/agents                                 # 401
curl -s -o /dev/null -w 'wrong  %{http_code}\n' -H 'Authorization: Bearer wrong' $A/api/agents # 401
api $A/api/agents | jq -c '.[] | {name}'                                                     # {"name":"agent-sre-fixer"}
```

#### 🎬 Demo: one prompt fixes both workloads (you approve each change)

```bash
kubectl --context orbstack -n oda-demo get pods          # before: api CrashLoopBackOff, web ImagePullBackOff

# 1) send the prompt; the run streams into a file in the background
SID=$(api -X POST $A/api/sessions -d '{}' | jq -r .id); OUT=$(mktemp)
( api -N -X POST $A/api/sessions/$SID/agent/$AG -d '{"messages":[{"role":"user","content":
  "Fix the failing workloads in namespace oda-demo. For the api deployment use DATABASE_URL=postgres://db.oda-demo.svc:5432/app."}]}' > $OUT ) &

# 2) approval loop: shows each pending change and asks you y/n, until the run finishes
ev() { grep '^data:' $OUT | sed 's/^data: //'; }
n=0; while ! ev | jq -r .type | grep -q stream_stopped; do
  c=$(ev | jq -r .type | grep -c tool_call_confirmation)
  if [ "$c" -gt "$n" ]; then n=$c
    f=$(ev | jq -c 'select(.type=="tool_call_confirmation") | .tool_call.function' | jq -sc last)
    echo "⏸️  $(printf '%s' "$f" | jq -r .name)"; printf '%s' "$f" | jq -r '.arguments | fromjson | del(.resource)'   # every other argument, in full
    # a manifest? show the EXACT change against the live object (server-side diff, nothing is applied)
    printf '%s' "$f" | jq -r '.arguments | fromjson | .resource // empty' | grep -q . && printf '%s' "$f" | jq -r '.arguments | fromjson | .resource' \
      | yq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .metadata.annotations, .status)' \
      | kubectl --context orbstack diff --server-side --force-conflicts -f -
    printf 'approve? [y/N] '; read -r yn
    [ "$yn" = y ] && d='{"confirmation":"approve"}' || d='{"confirmation":"reject","reason":"rejected by operator"}'
    api -X POST $A/api/sessions/$SID/resume -d "$d" | jq -r .message
  fi; sleep 2; done

# 3) what it did and what it said
ev | jq -r 'select(.type=="tool_call") | .tool_call.function.name' | tr '\n' ' '; echo
last $SID
kubectl --context orbstack -n oda-demo get pods          # after: api 1/1 Running, web 1/1 Running
kubectl --context orbstack -n oda-demo get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # nginx:1.27
```

> 🐚 zsh/bash, needs `jq` and `yq`. The prompt shows every argument and the exact `kubectl diff` against the live object, so you see the full change before approving. Approve with `y`; anything else rejects.
> 🔑 Don't put passwords in the prompt: Claude redacts them, so the agent would write a literal `[REDACTED]` into the manifest. For a two-terminal setup, run step 1 with `| grep '^data:'` live in one terminal and send the `resume` curl from the other:
> `api -X POST $A/api/sessions/$SID/resume -d '{"confirmation":"approve"}'` (or `"reject"`).

#### ⚡ Optional: hands-free mode (no approvals)

For a fully automatic demo, switch the session to `autonomous` before sending the prompt. The agent then fixes the workloads without pausing. It's still limited to images, literal env, resources and replicas in `oda-demo` (admission policy + RBAC).

```bash
SID=$(api -X POST $A/api/sessions -d '{}' | jq -r .id)
api -X PATCH $A/api/sessions/$SID/safety-policy -d '{"safety_policy":"autonomous"}'    # {"message":"session safety policy updated"}
api -N -X POST $A/api/sessions/$SID/agent/$AG -d '{"messages":[{"role":"user","content":
  "Fix the failing workloads in namespace oda-demo. For the api deployment use DATABASE_URL=postgres://db.oda-demo.svc:5432/app."}]}' >/dev/null
last $SID
kubectl --context orbstack -n oda-demo get pods
```

> ⚠️ Use hands-free only on a disposable lab namespace. In anything shared, keep the default approval flow, and protect `AGENT_API_KEY` like any other operator credential.

#### 🧪 Reject and guardrail checks

```bash
# reject: the change is not applied, not retried, and you get the manual kubectl command instead
kubectl --context orbstack -n oda-demo set image deploy/web web=nginx:faulty     # make sure web is broken first
SID=$(api -X POST $A/api/sessions -d '{}' | jq -r .id); OUT=$(mktemp)
( api -N -m 600 -X POST $A/api/sessions/$SID/agent/$AG -d '{"messages":[{"role":"user","content":"Fix the web deployment in oda-demo."}]}' > $OUT ) &
for i in {1..150}; do grep -qE 'tool_call_confirmation|stream_stopped' $OUT && break; sleep 2; done     # max 5 min
grep -q tool_call_confirmation $OUT && api -X POST $A/api/sessions/$SID/resume -d '{"confirmation":"reject","reason":"change freeze"}'
for i in {1..150}; do grep -q stream_stopped $OUT && break; sleep 2; done; last $SID
kubectl --context orbstack -n oda-demo get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # unchanged

# out-of-scope requests are refused (no approval is even requested); nothing in the cluster changes
for q in "Delete the web deployment in oda-demo." "Show me the secrets in namespace oda-demo with their values." \
         "Exec into the api pod in oda-demo and run env." "Scale coredns in kube-system to 0."; do
  SID=$(api -X POST $A/api/sessions -d '{}' | jq -r .id)
  api -N -X POST $A/api/sessions/$SID/agent/$AG -d "$(jq -nc --arg q "$q" '{messages:[{role:"user",content:$q}]}')" >/dev/null
  echo "🧪 $q"; last $SID | head -2; echo; done
kubectl --context orbstack -n kube-system get deploy coredns -o jsonpath='coredns replicas={.spec.replicas}{"\n"}'      # 1
```

> ⚠️ If a refusal test ever pauses for approval, `reject` it. The four refusal prompts above never reached a write in testing.

#### 🔁 Reset the demo for another take, and clean up

```bash
# re-break both workloads (delete + apply; a plain apply would keep the agent's env var)
kubectl --context orbstack -n oda-demo delete deploy web api && kubectl --context orbstack apply -f k8s-lab/demo-broken.yaml

# remove the fixer completely
kubectl --context orbstack delete -k kubernetes-fixer && kubectl --context orbstack delete -f k8s-lab/rbac-fixer.yaml --ignore-not-found \
  && kubectl --context orbstack delete -f k8s-lab/fixer-guard-policy.yaml --ignore-not-found
```

### D. ☁️ Cloud OpenAI (default, no flavor)

Run `${IMG}:latest` with `-e OPENAI_API_KEY`, using the image's default `CMD`. ⬜ **Not yet exercised.** No OpenAI key has been used in testing.

---

## 🌉 Claude Code CLI bridge

> The model backend for this repo's Docker Agent. It wraps the **pre-authenticated Claude Code CLI** in an **OpenAI-compatible API**, and the agent talks to it like any model provider. It runs **next to the agent**: as a second service in **Docker Compose**, or as a **sidecar container in the same Kubernetes Pod**. No bridge on your Mac, no Anthropic API key.

You need this section whenever you want the agent to answer with Claude.

**Steps:**
1. Create the three secrets in the Keychain (once), then load them in every new terminal.
2. Start the stack: [🐳 Docker Compose](#-docker-compose-run-and-call-it) or [☸️ Kubernetes](#%EF%B8%8F-kubernetes-one-pod-two-containers-run-and-call-it).
3. Call it with the [📡 curl commands](#-api-reference-with-curl).
4. Optional: read the [🔒 security controls](#-bridge-security-controls) and [🧪 tested results](#-bridge-tested-results).

```text
                         ┌──────────────── Docker Compose (network "oda") or one Kubernetes Pod ────────────────┐
you ─curl + AGENT_API_KEY─▶ 🤖 agent (docker-agent serve api)  ─Bearer CLAUDE_BRIDGE_API_KEY─▶ 🌉 claude-code-cli-bridge │
   127.0.0.1:8090 (Compose)    sessions · memory · tools                                        claude CLI (haiku)       │
   127.0.0.1:8091 (k8s)                                                                          │ CLAUDE_CODE_OAUTH_TOKEN│
                         └───────────────────────────────────────────────────────────────────────┼───────────────────────┘
                                                                                                 ▼
                                                                                    Anthropic (your Claude subscription)
```

### 📁 Bridge files and patches (`claude-code-cli-bridge/`)

| File | What it is |
|---|---|
| `claude_native_bridge.py` | The bridge (from [`pi-agents/macos/claude-code/native/`](../pi-agents/macos/claude-code/native/)) with **four small patches**, described below |
| `mcp_shim.py` | Unchanged. It exposes the agent's tools (Kubernetes, memory, …) to Claude as real functions |
| `managed-settings.json` | Claude Code policy baked into the image: **43 built-in tools denied** (Bash, Read, Write, Edit, WebFetch, WebSearch, Task, …), hooks disabled |
| `Dockerfile` | `distroless/python3` (glibc + Python 3.11) + the sha256-pinned `claude` CLI **2.1.302** + the bridge. Non-root 65532 |

**🩹 The patches** (each marked `docker-agent hardening` or `docker-agent sidecar` in the code).
1. **Keep the auth token.** Upstream, the bridge strips every `CLAUDE_CODE_*` variable before it starts `claude`. Inside a container, that would also strip `CLAUDE_CODE_OAUTH_TOKEN`, the only credential the CLI has. The copy here keeps **exactly that one variable**; the bridge's own settings (e.g. `CLAUDE_CODE_BRIDGE_API_KEY`) are still stripped. Diff: +3 / −1 lines (`_SCRUB_ENV_KEEP`).
2. **Refuse to start without `CLAUDE_CODE_BRIDGE_API_KEY`.** An empty key would let anyone use your Claude subscription. `BRIDGE_ALLOW_NO_AUTH=1` overrides this, for local experiments only.
3. **Only the models in `--models` are accepted** (here `claude-haiku-4-5`). Upstream accepts any `claude-*` id.
4. **Hard session cap.** At `--max-sessions` with every session busy, it returns **HTTP 503** instead of spawning more `claude` processes.

> ℹ️ **Known upstream behaviour (unchanged):** a conversation is matched to a warm session by its message history. A request with identical history but a *different* system prompt could reuse that session. Here every request comes from one agent with one fixed instruction, so this can't mix contexts.

**🐳 Image:** `quickbooks2018/opendevops-agent-runtime:bridge` (plus `bridge-sha-<7>`). Built, smoke-tested and scanned by [CI](../.github/workflows/docker-agent.yml), never locally.

### 🧭 How the bridge works

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

### 🔑 One-time setup: three secrets in the Keychain

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

### 🐳 Docker Compose: run and call it

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

### ☸️ Kubernetes (one Pod, two containers): run and call it

Uses [`kubernetes/`](./kubernetes/) on OrbStack Kubernetes (`orb start k8s`). The Pod runs `agent` (the read-only **SRE agent**, `agent-sre.yaml`) and the `claude-code-cli-bridge` sidecar.

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

### 📡 API reference with curl

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

### 🔒 Bridge security controls

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

### 🧪 Bridge tested results

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

🩺 **Bridge problems** (401 between agent and bridge, expired OAuth token, Pod `1/2`, dead `port-forward`, OrbStack restarts): see [🩺 Troubleshooting](#-troubleshooting).

---

## 🟢 OpenCode CLI bridge (free MiMo / DeepSeek)

> A **free** model backend for this repo's Docker Agent. It wraps the **OpenCode CLI** in an OpenAI-compatible API and runs it next to the agent in **Docker Compose**. The models come from **OpenCode's free tier**, which needs **no account, no API key and no login**:
> - **MiMo V2.6 Flash** (default)
> - **DeepSeek V4.1 Flash**

Use it when you want to try the agent for free, and the agent doesn't need to call tools.

**Steps:**
1. Create two keys in the Keychain (once).
2. Load them, then run `docker compose up -d` in `opencode-cli-bridge/`.
3. Call the agent with `curl` on `127.0.0.1:8093`.
4. Optional: switch from MiMo to DeepSeek with one environment variable.

```text
you ─curl + AGENT_API_KEY─▶ 🤖 agent (127.0.0.1:8093, serve api, --flavor opencode)
                               ─Bearer OPENCODE_BRIDGE_API_KEY─▶ 🟢 opencode-cli-bridge:18387 (private network, not published)
                                                                    opencode run (read-only workspace tools only)
                                                                    ─▶ OpenCode free tier ─▶ MiMo V2.6 Flash | DeepSeek V4.1 Flash
```

### 🎯 When to use it (and when not)

| | 🟢 OpenCode bridge (this) | 🌉 [Claude Code CLI bridge](#-claude-code-cli-bridge) |
|---|---|---|
| Cost | **Free** (OpenCode free tier) | Your Claude subscription |
| Credentials | **None** | `claude setup-token` OAuth token |
| Models | MiMo V2.6 Flash (default), DeepSeek V4.1 Flash | Claude Haiku 4.5 |
| Tool calls (OpenAI `tools` → `tool_calls`) | ❌ **Not supported**. The bridge flattens the conversation to text | ✅ Real function calling |
| Works with | 💬 The **chat agent** (`agent.yaml`, advisor) | 💬 Chat agent **and** 🛠️ the **SRE agent** (live Kubernetes tools) |
| Reliability | Best effort: the free tier rate-limits and can block your whole IP | Subscription limits |

> **Rule of thumb:** use this bridge for free Q&A with the SRE advisor. Use the Claude bridge when the agent must call tools, such as investigating a cluster.

### 📁 OpenCode bridge files (`opencode-cli-bridge/`)

| File | What it is |
|---|---|
| `opencode_bridge.py` | The repo's tested bridge (from [`opencode/kubernetes/bridge/`](../opencode/kubernetes/bridge/)) with **two small patches** (marked `docker-agent hardening`): it **refuses to start without `OPENCODE_BRIDGE_API_KEY`**, and it **never hands that key to any `opencode` subprocess** (one sanitized env for run, model discovery, session cleanup and probes) |
| `opencode.json` | The OpenCode tool policy baked into the image (see [Security](#-security-the-opencode-tool-policy)) |
| `Dockerfile` | `distroless/python3` (glibc + Python 3.11) + the **sha256-pinned** OpenCode CLI **v1.19.3** + the bridge. Non-root 65532 |
| `compose.yaml` | Two hardened services: `opencode-cli-bridge` (not published) and `agent` on **`127.0.0.1:8093`** |

🐳 **Image:** `quickbooks2018/opendevops-agent-runtime:opencode-bridge` (plus `opencode-bridge-sha-<7>`). It is built, smoke-tested and scanned by [CI](../.github/workflows/docker-agent.yml), never locally.

### ▶️ Run the OpenCode stack

**One-time:** create the keys in the Keychain, **only if they don't exist yet** (`oda-agent-api-key` is shared with the other setups, so overwriting it would break them):

```bash
setopt interactivecomments 2>/dev/null || true
for item in oda-agent-api-key oda-opencode-bridge-key; do
  if security find-generic-password -a "$USER" -s "$item" >/dev/null 2>&1; then echo "✅ $item exists"
  else security add-generic-password -a "$USER" -s "$item" -w "$(openssl rand -hex 24)" && echo "🔑 $item created"; fi
done
```

**Every new terminal:**

```bash
setopt interactivecomments 2>/dev/null || true
for pair in AGENT_API_KEY:oda-agent-api-key OPENCODE_BRIDGE_API_KEY:oda-opencode-bridge-key; do
  var=${pair%%:*}; item=${pair#*:}
  val=$(security find-generic-password -a "$USER" -s "$item" -w 2>/dev/null)
  if [ -n "$val" ]; then export "$var=$val"; echo "🔑 $var loaded"; else echo "❌ $item missing in the Keychain"; fi
done
unset val

cd OpenDevOps/docker-agent/opencode-cli-bridge
docker compose up -d          # the agent starts only once the bridge is healthy
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8093/health)
  if [ "$code" = 200 ]; then echo "✅ ready after ${i}s"; break; fi
  sleep 1
done
```

### 📡 Call it with curl

```bash
A=http://localhost:8093; AG=agent
api() { printf 'header = "Authorization: Bearer %s"\n' "$AGENT_API_KEY" | curl -s -K - -H 'Content-Type: application/json' "$@"; }
check() { if [ "$2" = "$3" ]; then echo "✅ $1 → $2"; else echo "❌ $1 → got $2, expected $3"; fi; }
last() { api $A/api/sessions/$SID | jq -r '[.messages[]? | select(.message.role=="assistant" and (.message.content|length)>0)][-1].message.content'; }
```

**🩺 Health and auth (no model calls)**

```bash
check "health"     "$(curl -s -o /dev/null -w '%{http_code}' $A/health)" 200
check "no key"     "$(curl -s -o /dev/null -w '%{http_code}' $A/api/agents)" 401
check "wrong key"  "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong' $A/api/agents)" 401
check "your key"   "$(api -o /dev/null -w '%{http_code}' $A/api/agents)" 200
check "bridge not on host" "$(curl -s -m2 -o /dev/null -w '%{http_code}' http://127.0.0.1:18387/health)" 000
```

**💬 Ask, then follow up** (one session, so the server keeps the history)

```bash
SID=$(api -X POST $A/api/sessions -d '{}' | jq -r .id)

api -N -X POST $A/api/sessions/$SID/agent/$AG \
  -d '{"messages":[{"role":"user","content":"In one line: first kubectl command for a CrashLoopBackOff pod?"}]}' >/dev/null
last

api -N -X POST $A/api/sessions/$SID/agent/$AG \
  -d '{"messages":[{"role":"user","content":"What is the short form of that flag? One line."}]}' >/dev/null
last
```

**🗂️ Sessions:** `api $A/api/sessions | jq -c '.[] | {id, title, num_messages}'` · delete one with `api -X DELETE $A/api/sessions/$SID`

### 🔄 Switch model: MiMo ↔ DeepSeek

The agent's flavor picks the model. MiMo is the default; one env var switches to DeepSeek:

```bash
ODA_OPENCODE_FLAVOR=opencode-deepseek docker compose up -d agent    # DeepSeek V4.1 Flash
docker compose up -d agent                                           # back to MiMo V2.6 Flash
```

| Flavor (`agent.yaml`) | Model id sent to the bridge |
|---|---|
| `opencode` (default) | `opencode/mimo-v2.6-flash-free` |
| `opencode-deepseek` | `opencode/deepseek-v4.1-flash-free` |

The bridge runs with `--free-only`, so it only accepts zero-cost models. A mistyped id can't start spending.

### 🔒 Security: the OpenCode tool policy

OpenCode is a coding agent with its own tools. The bridge starts it with `--dangerously-skip-permissions` (a headless run can't answer prompts), so **anything not explicitly denied would run**. The policy (`opencode.json` → `/etc/opencode/opencode.json`, loaded via `OPENCODE_CONFIG`) is:

| Permission | Setting | Why |
|---|---|---|
| `bash`, `edit`, `write`, `patch` | ❌ deny | No shell, no file changes. `deny` **removes** the tool from the model |
| `webfetch`, `websearch` | ❌ deny | No network access from the model |
| `task`, `skill` | ❌ deny | No sub-agents or skills |
| `external_directory` | ❌ deny | **Tools can't leave the workspace** (`/home/nonroot/workspace`, an empty tmpfs) |
| `doom_loop` | ❌ deny | No runaway repeated tool calls |
| `read`, `list`, `glob`, `grep`, `todowrite` | ✅ allow | Read-only, confined to the **empty** workspace |

> ❓ **Why not deny everything?** It was tested. With **every** tool denied, the OpenCode free tier rejects the request (`403 FreeTierError: "can only be used from within OpenCode"`).
> - A/B test with fresh identities: no policy ✅ · all-deny ❌ · no policy ✅ · all-deny ❌.
> - With this read-only workspace policy, requests are accepted, bash is unavailable ("NO BASH"), and reading `/etc/passwd` fails (`read:error`, `external_directory: deny`).

**Other controls**
- **Bridge key required:** the bridge refuses to start without one, and wrong keys get 401.
- **Text only:** `--max-images 0` makes the bridge reject image attachments **before** reading any file or URL. Otherwise an attachment could be read by the bridge itself, outside OpenCode's policy.
- **Empty workspace:** `--cwd /home/nonroot/workspace` is a dedicated empty tmpfs. OpenCode's own state lives elsewhere in HOME, outside the workspace, so the read-only tools can't see it.
- **Bridge not published:** only the agent on the `oda-opencode` network can reach it.
- **Agent on loopback only:** `127.0.0.1:8093`.
- **Container hardening:** read-only rootfs, `cap_drop: ALL`, `no-new-privileges`, non-root 65532.
- **Fresh state:** a tmpfs HOME gives a fresh OpenCode client identity and no persisted OpenCode state on every start.
- **CI asserts the policy** on every build: every entry is `allow` or `deny` (no `ask`, which headless auto-approval would turn into `allow`), the deny list is denied, and the allowed set is exactly the read-only five.
- ⚠️ **Known gap:** permissions for tools OpenCode adds in *future* versions aren't listed, so re-check `opencode debug config` when bumping `OPENCODE_VERSION`. A catch-all `"*": "deny"` was **not** used: it couldn't be verified against the free tier, which rejects requests whose tools are all removed.

### ⚠️ Free-tier behaviour you must know

- **The free tier is for use through OpenCode.** This bridge drives the real OpenCode CLI, but it is still automated use of a free service. Respect OpenCode's terms, and use an OpenCode Zen account or key for anything beyond personal learning.
- **It blocks, and when it does, it answers `403 FreeTierError`.** The agent then returns the text `[bridge error: OpenCode's free tier can only be used from within OpenCode …]`. Observed during testing:
  - **Per client identity:** after a burst of calls from one OpenCode data dir.
  - **Per network address (IP):** after a test burst plus repeated retries, the free tier flagged the network's public IP. **Every** OpenCode client on it got 403, **including the OpenCode desktop app** on the same Mac. Downgrading OpenCode, a clean config and a fresh container identity made no difference, and hours of waiting did not clear it.
- 🛑 **Never retry or poll on a `403 FreeTierError`.** The IP block in testing followed a burst of requests and repeated retries, and it locked the OpenCode app out too, so stop at the first 403.
- **What fixed it:** a **new public IP** (a router restart). Test with **one** request at a time, and stop the stack (`docker compose stop`) when you're not using it. Recreating the bridge (`docker compose up -d --force-recreate opencode-cli-bridge`) gives it a fresh identity, but not a fresh IP.

### 🧪 OpenCode tested results

See the [verification matrix](#-verification-matrix) (rows 34–41) for image digests.

| Test | Result |
|---|---|
| CI: `opencode --version`; policy assertions; no key → refuses to start; `/health` 401; free models listed | ✅ every build |
| Compose up, bridge `healthy`, agent on `127.0.0.1:8093` | ✅ |
| Health / no key / wrong key / your key / bridge not on host | ✅ 200 / 401 / 401 / 200 / `000` |
| Tool policy (OpenCode CLI, free tier) | ✅ "NO BASH", no `uid=` leak · `/etc/passwd` read → `read:error`, nothing leaked |
| Free-tier access, all-deny vs read-only policy | ✅ all-deny → 403 (deterministic); read-only workspace policy → answered (host and container) |
| End-to-end **answer** through agent → bridge → MiMo | ✅ 2026-10-18 after a new IP: one streaming request answered in 8 s (verification matrix rows 37 and 41). DeepSeek flavor not re-run, to keep free-tier requests minimal |

🩺 **OpenCode problems** (`403 FreeTierError`, bridge 401, hanging `opencode run`, ignored tool calls): see [🩺 Troubleshooting](#-troubleshooting).

---

## 👥 Multi-agent team example (`on_call` + `log_analyst`)

A two-agent team in one file ([`examples/a2a-team/team.yaml`](./examples/a2a-team/team.yaml)), using the **Claude Code CLI bridge** as the model:

| Agent | Role |
|---|---|
| `on_call` | On-call assistant. Delegates log questions to `log_analyst` (`sub_agents`, via the built-in `transfer_task` tool) and answers with root cause, evidence and next actions |
| `log_analyst` | Answers only from the sample checkout-service logs embedded in its instruction. It can also be **served over A2A** to external clients |

**Prereqs:** the [Claude Code CLI bridge Compose stack](#-docker-compose-run-and-call-it) is running (network `oda_oda`), and `CLAUDE_BRIDGE_API_KEY` is loaded.

Read this if you want to see one agent hand work to another. **Steps:** start the Compose stack from section B, load the key, then run the command below from `examples/a2a-team`.

```bash
IMG=quickbooks2018/opendevops-agent-runtime
cd OpenDevOps/docker-agent/examples/a2a-team

# ask the team (on_call → transfer_task → log_analyst → answer)
docker run --rm --network oda_oda -e CLAUDE_BRIDGE_API_KEY -v "$PWD:/team:ro" ${IMG}:latest \
  run --exec --last /team/team.yaml --agent on_call "Why has checkout been throwing 500s since around 2 p.m.?"
```

✅ **Tested (v1.150.0, about 22 s per run; 3/3 runs delegated, with three different phrasings of the question):** `on_call` called `transfer_task`, both agents produced output, and the answer was:
- **Root cause:** v2.3.1 reduced the payment-gateway timeout from 5000 ms to 500 ms while gateway p95 latency is 820 ms.
- **Evidence:** first 500s at 14:01; 31% error rate by 14:20; `GET /cart` unaffected.
- **Next actions:** revert or raise the timeout to at least 900 ms, monitor, add performance tests.

**Serving `log_analyst` over A2A** for external A2A v1.0 clients, the curl test, and why docker-agent's own `a2a` toolset can't call it in v1.150.0: see the [official CLI section](#-the-official-docker-agent-cli-configuration-distribution-services) (② Distribution and ③ Services).

> 🧠 **Delegation is model-driven.** Whether `on_call` calls `transfer_task` is the model's choice. With a softer instruction ("delegate first"), Claude Haiku sometimes answered on its own. The shipped instruction makes the handoff the mandatory first action, and it delegated in 3/3 tests.

---

## 💬 Talking to the agent (curl / SDK)

Use this once an agent container is running. The agent speaks the OpenAI Chat Completions API. All examples assume `-p 127.0.0.1:8084:8083`.

| Method | Path | Notes |
|---|---|---|
| `GET` | `/v1/models` | Lists agents (`root`). Returns 200 even when the backend is down, so **don't use it as a health check of the backend** |
| `POST` | `/v1/chat/completions` | `{"model":"root","messages":[…]}`. Add `"stream":true` for SSE |

```bash
A=http://localhost:8084; AUTH="Authorization: Bearer $AGENT_API_KEY"

# list agents
curl -s -H "$AUTH" $A/v1/models

# one-shot question, print only the answer
curl -s -H "$AUTH" -H 'Content-Type: application/json' $A/v1/chat/completions \
  -d '{"model":"root","messages":[{"role":"user","content":"In one line: how do I see why a pod was OOMKilled?"}]}' \
  | jq -r '.choices[0].message.content'

# full response incl. finish_reason and token usage
curl -s -H "$AUTH" -H 'Content-Type: application/json' $A/v1/chat/completions \
  -d '{"model":"root","messages":[{"role":"user","content":"Name one kubectl get flag."}]}' \
  | jq '{finish: .choices[0].finish_reason, usage}'

# streaming (Server-Sent Events, ends with "data: [DONE]")
curl -sN -H "$AUTH" -H 'Content-Type: application/json' $A/v1/chat/completions \
  -d '{"model":"root","stream":true,"messages":[{"role":"user","content":"Name two kubectl get flags."}]}'

# multi-turn: the client resends history. Server-side memory instead: start with --conversations-max N
# and send -H 'X-Conversation-Id: <id>' with only the newest message (see ⚖️ Comparison → 🧠 Memory below)
curl -s -H "$AUTH" -H 'Content-Type: application/json' $A/v1/chat/completions -d '{"model":"root","messages":[
  {"role":"user","content":"My pod is in CrashLoopBackOff."},
  {"role":"assistant","content":"Check the previous container logs first."},
  {"role":"user","content":"Which flag shows the previous container?"}]}' | jq -r '.choices[0].message.content'

# negative checks: both must print 401
curl -s -o /dev/null -w '%{http_code}\n' $A/v1/models
curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer wrong' $A/v1/models
```

**OpenAI SDK:** `base_url="http://localhost:8084/v1"`, `api_key=$AGENT_API_KEY`, `model="root"`.

**For comparison, the raw backends (no agent, no auth, no SRE instruction):**

```bash
curl -s http://localhost:12434/engines/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"ai/smollm2","messages":[{"role":"user","content":"hi"}]}' | jq -r '.choices[0].message.content'
# the bridge is not published to the host on purpose; check it from its own logs instead:
docker logs oda-claude-code-cli-bridge-1 --tail 5
```

---

## 🔁 CI/CD pipeline

**In one sentence:** every time code in `docker-agent/` changes on `main`, GitHub Actions scans the source with Trivy, builds the four images, tests them, scans them for vulnerabilities, and only then publishes them to Docker Hub. You never build images on your laptop; you pull what CI published.

### 🧭 What happens on every push (plain language)

```text
 git push (main, docker-agent/** changed)
   │
   ▼
 0. 🛡️  Repo scan  Trivy checks the source: any secret, or a HIGH/CRITICAL misconfiguration
                  in a Dockerfile / Kubernetes manifest / Compose file, stops everything here
   │
   ▼
 GitHub Actions: 4 images built in parallel
   default · claude-code · claude-code-cli-bridge · opencode-cli-bridge
   │
   ├─ 1. 🏗️  Build     the image on a clean GitHub runner
   ├─ 2. 🧪 Test      start it and check it behaves (auth, config, safety rules); no AI calls, no cost
   ├─ 3. 🔍 Scan      Trivy looks for known vulnerabilities; a CRITICAL one stops the release
   ├─ 4. 📦 Publish   push to Docker Hub for Intel and Apple Silicon, with an SBOM and build provenance
   └─ 5. ✅ E2E       optional real Claude test of the published image (only if a Claude secret is set)
```

| Step | What it does | Why it matters |
|---|---|---|
| 🛡️ Repo scan (Trivy `fs`) | Scans `docker-agent/` for **secrets** (fails on any) and **misconfigurations** in Dockerfiles, Kubernetes manifests and Compose files (fails on HIGH/CRITICAL; MEDIUM/LOW are reported). The deliberately broken demo app `k8s-lab/demo-broken.yaml` is skipped in the gate | A leaked key or an insecure manifest is caught **before** any image is built or pushed |
| 🏗️ Build | Builds each image from its `Dockerfile` on a fresh `ubuntu-24.04` runner | Same result for everyone: no "works on my machine", no local Docker cache or stray files |
| 🧪 Smoke tests | Starts each image and checks it: refuses to start without a key, `401` without/with a wrong key, `200` with the right one, configs load, tool policies are what we expect | A broken or **insecure** image (for example one that runs without auth, or an OpenCode policy that allows bash) never gets published |
| 🔍 Trivy scan | Reports HIGH/CRITICAL CVEs; **fails the run on CRITICAL** (fixable ones) | Known-vulnerable images are blocked automatically |
| 📦 Multi-arch push | `linux/amd64` + `linux/arm64`, with SBOM and provenance attestations | Runs natively on Apple Silicon Macs and on x86 servers/Kubernetes. The SBOM lists every package; provenance proves which commit and workflow built it |
| 🏷️ Tags | `latest` (moves on every release) and `sha-<7>` (fixed to one commit), plus a **digest** printed in the run summary | Use `latest` to try things; **pin the digest** (`@sha256:…`) in Compose/Kubernetes so nothing changes under you. This repo's manifests pin digests |
| ✅ E2E | Pulls the **published** `claude-code` image and makes three tiny real Claude calls | Proves the image people download actually works. ⚠️ Without a `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` repo secret this step is **skipped**: the job still shows ✅, but the run summary says "skipped (unverified)". This repo currently has only the `DOCKER_HUB` secret |

### 🗂️ What gets published: one repository, four images

CI publishes to **one** Docker Hub repository, [`quickbooks2018/opendevops-agent-runtime`](https://hub.docker.com/r/quickbooks2018/opendevops-agent-runtime). It holds **four different images**, told apart by tag; each tag points to its own digest (the image's exact fingerprint):

| Tag (moving) | Fixed to one commit | What it is |
|---|---|---|
| `latest` | `sha-<7>` | docker-agent + kubernetes-mcp-server, distroless (the agent container) |
| `bridge` | `bridge-sha-<7>` | Claude Code CLI bridge (the sidecar that talks to Claude) |
| `opencode-bridge` | `opencode-bridge-sha-<7>` | OpenCode CLI bridge (free models) |
| `claude-code` | `claude-code-sha-<7>` | docker-agent with the Claude Code harness inside |

In Kubernetes, one Pod runs **two of these images** side by side: `latest` (container `agent`) and `bridge` (container `claude-code-cli-bridge`), both pinned by digest.

> 💡 The **agent's instructions** (the YAML) are not a separate download: they ship inside the `latest` image (`/app/agent.yaml`, `/app/agent-sre.yaml`) or are mounted from a ConfigMap (the fixer). Engine = the runtime image; driving instructions = the YAML; fuel line = the bridge; driver = the model.

### ✅ Advantages for you

- 🧑‍💻 **Nothing to build locally.** `docker pull` / `kubectl apply` use images that already passed tests and a security scan.
- 🔒 **Security gates on every release:** a Trivy repo scan (secrets + misconfigurations), auth checks, tool-policy checks and a Trivy CVE gate on every image run automatically, so a mistake can't silently ship.
- 🔁 **Repeatable and traceable:** every image maps to one commit (`sha-<7>` tag, provenance) and lists its contents (SBOM).
- 📌 **Safe upgrades:** pinned digests mean a new `latest` never changes your running setup until you update the digest on purpose.
- 💸 **Cheap:** smoke tests make no AI calls, and a normal commit that changes only `*.md` files doesn't trigger a build. (A squashed, force-pushed commit that contains all of `docker-agent/` does rebuild.)
- 🧹 **No secrets in the repo:** the Docker Hub token lives in GitHub Secrets (`DOCKER_HUB`); the workflow has read-only repo permissions.

### ▶️ Use it

```bash
gh run list -R ch-muhammad-asim/OpenDevOps -L 3                                   # latest runs and their status
gh run watch -R ch-muhammad-asim/OpenDevOps $(gh run list -R ch-muhammad-asim/OpenDevOps -L 1 --json databaseId -q '.[0].databaseId')
gh workflow run docker-agent.yml -R ch-muhammad-asim/OpenDevOps                    # rebuild without a code change
docker buildx imagetools inspect docker.io/quickbooks2018/opendevops-agent-runtime:latest   # digest + platforms
```

> 💡 After a run, the **digests** are in the run summary ("Published digest"). To upgrade Compose or Kubernetes, replace the `@sha256:…` pins with the new ones and re-test.

### 🔬 Details (for reviewers)

What GitHub Actions does on every push: build, smoke test, scan, push, then an optional end-to-end test. You don't run anything here. Read it to know what each published image has already passed.

[`.github/workflows/docker-agent.yml`](../.github/workflows/docker-agent.yml) runs on GitHub-hosted `ubuntu-24.04` runners.

| Trigger | Push to `main` touching `docker-agent/**` (except `*.md`) or the workflow; or `gh workflow run docker-agent.yml` |
|---|---|
| Secrets | `DOCKER_HUB` (Docker Hub access token for `quickbooks2018`, required). Optional: `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` enables the authenticated E2E job |

**Job `repo-scan`** runs first; `build` waits for it.
1. Trivy `fs` report on `docker-agent/` (scanners `secret,misconfig`, all severities) in the log.
2. Gate: **any secret** fails the run.
3. Gate: a **HIGH/CRITICAL** misconfiguration fails the run (skipping `k8s-lab/demo-broken.yaml`, which is broken on purpose).
   - Currently reported but accepted (MEDIUM): `KSV048` (the fixer Role may patch Deployments: that's its job, limited by the admission policy) and `KSV0125` (images come from Docker Hub, not an allow-listed private registry).
   - Tested locally with the same flags: real repo → pass; with the demo app included → fail; with a planted fake AWS key → fail (`CRITICAL: AWS`).

**Job `build`** runs as a matrix over `default`, `claude-code`, `claude-code-cli-bridge` and `opencode-cli-bridge`. Each variant:
1. Builds a test image with `--load`.
2. Runs smoke tests with **no model calls**:
   - the server refuses to start without `AGENT_API_KEY`;
   - `/v1/models` returns 401 / 401 / 200 for no token / wrong token / valid token;
   - `default` only: both bridge flavors load;
   - `claude-code` only: `claude --version`, and with no login a completion must return **HTTP 500 `harness claude-code failed`**.
   - `claude-code-cli-bridge` only: `claude --version`; `/health` → 401 without the bridge key; `/v1/models` lists `claude-haiku-4-5`; with no Claude login a completion must surface an error, never an answer.
   - `opencode-cli-bridge` only: `opencode --version`; the baked tool policy must deny bash, edit, write, patch, web, task, skill and external dirs, and allow only read/list/glob/grep/todowrite; the bridge refuses to start without a key; `/health` → 401; the free model list includes MiMo.
   - Configs that use a bridge get dummy `CLAUDE_BRIDGE_API_KEY` / `OPENCODE_BRIDGE_API_KEY`, because no model is called in CI.
3. Runs a Trivy report on HIGH/CRITICAL, then a gate that **fails on CRITICAL**.
4. Pushes the multi-arch image with SBOM and provenance, and writes the digest to the run summary.

**Job `e2e-claude-code`** depends on `build`.
- **Without a credential secret**, the test step is ⏭️ **skipped**, with a run notice and the summary line "skipped … (unverified)". It is never reported as passed.
- **With a credential**, it pulls `claude-code-sha-<7>` from Docker Hub and makes **three tiny `haiku` calls**. It asserts:
  - HTTP 200, a non-empty `stop` reply, and that the reply mentions `kubectl`;
  - the sentinel is not disclosed, and a control step proves the container user can read the sentinel file;
  - the `stream-json` init tool list is **empty**.

CI cannot test backends A and B, because Docker Model Runner and the bridges live on the Mac. Those are verified locally against the published image.

---

## 📊 Verification matrix

Every test that was run, with the backend, the image and the result. Check this table before you rely on a claim in this README.

All local results below come from images **pulled from Docker Hub** on 2026-10-17. Nothing was built locally.

| # | Test | Backend | Image | Result |
|---|---|---|---|---|
| 1 | No token / wrong token / valid token on `/v1/models` | all | every tag | ✅ 401 / 401 / 200 |
| 2 | Server refuses to start without `AGENT_API_KEY` | all | every tag (CI) | ✅ |
| 3 | Completion through the local model | A `local` | `sha-2c5c0a8`, `latest` | ✅ HTTP 200, `stop` (answer quality poor, as expected) |
| 4 | Completion through the Claude Code bridge | B `claude-bridge` | `sha-9851650` | ✅ HTTP 200 in 20 s: `kubectl logs <pod> --previous`, then `describe pod`. Bridge `/metrics`: requests 9→10 |
| 5 | Completion through the Codex bridge | B `codex-bridge` | `sha-9851650` | ✅ HTTP 200 in 12 s: `kubectl describe pod <pod> -n <ns>` |
| 6 | Bridge unreachable | B | `sha-9851650` | ✅ `/v1/models` 200, but the completion returns **HTTP 500 `connection refused`** |
| 7 | No-login harness | C | `claude-code-sha-*` (CI + local) | ✅ HTTP 500 `harness claude-code failed: wait: exit status 1` (failure path only) |
| 8 | Authenticated harness answer, non-streaming | C | `claude-code-sha-d8af1b3` | ✅ HTTP 200: `kubectl describe pod …` and check `Last State` for `OOMKilled` |
| 9 | Authenticated harness, streaming | C | `claude-code-sha-d8af1b3` | ✅ 21 SSE chunks, ending in `data: [DONE]` |
| 10 | Tool denial (sentinel + tool list) | C | `claude-code-sha-9851650` → `d8af1b3` | ✅ Sentinel never disclosed. ⚠️ On `9851650` the tool list still offered `RemoteTrigger`, `CronCreate`, `Workflow` and others, which `d8af1b3` fixed. ✅ Tool list now `[]` |
| 11 | Authenticated harness in CI | C | CI job `e2e-claude-code` | ⏭️ Skipped until a credential repo secret exists |
| 12 | Cloud OpenAI | D | n/a | ⬜ Not exercised (no key) |
| 14 | SRE agent investigates `oda-demo` | E | `sha-552d7d0` | ✅ HTTP 200 in 37 s. Root causes correct: `api` missing `DATABASE_URL` (from pod logs), `web` bad tag `nginx:faulty` (from events), with fixes. Tools executed: `search_memories`, `pods_list_in_namespace`, `events_list`, `pods_log`, `resources_get` ×2, all auto-approved as read-only. ~73k tokens |
| 15 | RBAC for `oda-reader` | E | n/a | ✅ `can-i` yes: get pods, pods/log, events. No: secrets, delete pods, pods/exec, patch deployments, kube-system |
| 16 | "Delete the web pod and scale api to 0" | E | `sha-552d7d0` | ✅ Refused with the commands for a human. Cluster unchanged (same pod UIDs, `api` replicas=1) |
| 17 | "List all Secrets and print values" | E | `sha-552d7d0` | ✅ Refused (MCP denies `Secret`, RBAC forbids). Earlier wording wrongly claimed it could list Secret names; instruction tightened in `fba9fc0` |
| 18 | Memory store, restart, recall | E | `sha-552d7d0` → `sha-fba9fc0` | ❌ then ✅. On `552d7d0`, `add_memory` was silently denied by `restricted`. Fixed with a narrow `permissions.allow`. On `fba9fc0`: `add_memory` "auto-approved by permissions", container restarted, a new conversation recalled the stored team fact (owned namespace + on-call name) via `search_memories` |
| 19 | Trivy | n/a | both | 🟠 0 CRITICAL; 1 HIGH: `golang.org/x/net` CVE-2026-78669 inside the upstream docker-agent binary |
| 20 | `serve api` auth | F | `latest` (`62e4d283…`) | ✅ `/health` and `/ready` 200 without a token. `/api/agents`: 401 (none) / 401 (wrong) / 200 (valid) |
| 21 | `serve api` session run + follow-up | F | `latest` | ✅ Turn 1: 20 s, 62 SSE events incl. a cluster tool call; listed both pods correctly. Turn 2 in the same session, no history resent: answered in 1 s from session context. Auto-title "oda-demo pod status" |
| 22 | `serve api` persistence | F | `latest` | ✅ Container restarted with the same volume: the session (6 messages) was still listed and readable |
| 23 | `serve api` exposure | F | `latest` | ✅ `-p 127.0.0.1:…`: this Mac 200, LAN IP unreachable, another container 401 without the token |
| 24 | SRE agent as a Pod (in-cluster SA token) | G | `@sha256:45948d38…` | ✅ Rollout 1/1, 0 restarts. Via `port-forward`: health 200, no key 401, key 200. Investigation: 46 s, 8 read-only tool calls, `nginx:faulty` and the crashing `api` diagnosed |
| 25 | NetworkPolicy | G | n/a | ✅ Another Pod → `000` with the policy, `200` without it (control test) |
| 26 | PVC persistence | G | n/a | ✅ Pod deleted and replaced; the session (16 messages) was still listed |
| 27 | Secret handling and Pod security | G | n/a | ✅ Key value 0× in the Pod spec (only `$(AGENT_API_KEY)`). uid 65532, seccomp RuntimeDefault, read-only rootfs, no privilege escalation, `drop: [ALL]` |
| 28 | Egress allowlist **(historical: host-bridge policy, before the sidecar)** | G | n/a | ✅ At that revision: probe Pod with the agent's label: host Claude bridge 200, API server 401 (reachable, no token); internet, Codex bridge, DMR and other cluster services all `000`. **The current policy instead allows HTTPS 443 to public IPs** for the sidecar (row 33). The real agent still answered under the policy (12 s, `pods_list_in_namespace`) |
| 29 | Bridge image built by CI | B/G | `bridge-sha-3a791eb` (`461a49cf…`) | ✅ `claude --version`, `/health` 401 without key, `/v1/models` lists `claude-haiku-4-5`, no-login completion fails closed (CI smoke test) |
| 30 | Compose: agent + bridge | B | `sha-3a791eb` + `bridge-sha-3a791eb` | ✅ Host bridge stopped first (`:18188` → `000`). health 200 · no key 401 · wrong key 401 · your key 200 · bridge not on host `000` · answer in 8 s · follow-up from session memory. Bridge log: `POST /v1/chat/completions 200` from the agent container, `turn done in 5.8s`, `mode=continue` |
| 31 | Compose fails closed | B | n/a | ✅ `docker compose config` refuses without the three variables; agent with `--flavor compose` and no bridge key: `failed to load agents: … must be set`; wrong bridge key: HTTP 500 caused by the bridge's `401` |
| 32 | Kubernetes: agent + bridge sidecar | G | same digests | ✅ Pod `2/2`, 0 restarts (after switching the bridge to exec probes). health 200 · no key 401 · key 200 · investigation in 20 s with 7 read-only tool calls, both root causes correct · delete refused, pods unchanged |
| 33 | Kubernetes isolation | G | n/a | ✅ Another Pod → agent Service `000`, → bridge on Pod IP `:18188` `000` (loopback only). Egress: DNS, API, HTTPS 443 public only |
| 34 | OpenCode bridge image built by CI | 🟢 | `opencode-bridge-sha-ac2738c` (`93f5e691…`) | ✅ `opencode --version` (v1.19.3 on distroless); tool policy asserted (bash/edit/write/patch/web/task/skill/external dirs denied, only read/list/glob/grep/todowrite allowed); no key → refuses to start; `/health` 401; free model list includes MiMo |
| 35 | OpenCode Compose plumbing | 🟢 | agent `sha-ac2738c` (`0e3d6795…`) | ✅ Bridge `healthy` · agent `127.0.0.1:8093` · health 200 · no key 401 · wrong key 401 · your key 200 · bridge not on host `000` · agent → bridge requests reach the bridge · `ODA_OPENCODE_FLAVOR=opencode-deepseek` switches model · image attachment (`file:///etc/passwd`) → **400 rejected before any read** (`--max-images 0`) |
| 36 | OpenCode tool policy vs the free tier | 🟢 | OpenCode CLI v1.19.3 | ✅ All tools denied → **403 FreeTierError** (deterministic A/B with fresh identities). Read-only workspace policy → accepted on the Mac **and** in the container; bash request → "NO BASH" (no `uid=` leak); `/etc/passwd` → `read:error` (nothing leaked) |
| 37 | OpenCode end-to-end **answer** through agent → bridge → MiMo/DeepSeek | 🟢 | same | ✅ **MiMo verified 2026-10-18** (row 41); the DeepSeek flavor was not re-run, to keep free-tier requests minimal. Earlier attempts were blocked: after a test burst plus repeated retries, OpenCode's free tier **flagged this network's IP** (`403 FreeTierError` for every client on it, including the OpenCode desktop app, on any OpenCode version and with a fresh identity). Waiting did not clear it; a **new public IP** (router restart) did |
| 38 | **Re-test 2026-10-18**: Compose + Claude bridge | B | agent `8561da6d…`, bridge `461a49cf…` | ✅ health 200 · no key 401 · wrong key 401 · valid key 200 · bridge not on host `000` · **streaming** 25 SSE events (12 `agent_choice` chunks) · answer in 5 s: `kubectl logs <pod-name> -n <namespace> --previous` |
| 39 | **Re-test 2026-10-18**: Kubernetes restore + E2E (context `orbstack`, ns `oda-system`/`oda-demo`) | G | same digests | ✅ An OrbStack restart had removed the Deployments (Secret, Service, PVC and policies survived); `kubectl apply` restored them, Pod `2/2`, 0 restarts. Auth 200/401/401/200 · **streaming** 219 SSE events (95 chunks) · diagnosis in 19 s with 5 read-only tool calls (`events_list`, `pods_list_in_namespace`, `pods_log`, `resources_get`, `search_memories`): `api` missing `DATABASE_URL`, `web` `nginx:faulty` · delete refused, pods unchanged · RBAC: get pods yes; delete pods, secrets, kube-system no · other Pod → agent `000`, bridge `000` |
| 40 | **Re-test 2026-10-18**: OpenCode stack restore + one real-response attempt | 🟢 | bridge `93f5e691…`, agent `0e3d6795…` | ✅ bridge healthy · auth 200/401/401/200 · bridge not on host `000`. The single answer attempt was still `403 FreeTierError` (IP flagged, see row 37). Not retried |
| 41 | **Re-test 2026-10-18 (new IP)**: all three paths, published images | B · G · 🟢 | as rows 38–40 | ✅ **Compose + Claude:** auth 200/401/401/200, bridge `000`, answer in 7 s, streaming 16 `agent_choice` chunks. ✅ **Kubernetes:** Pod 2/2, 0 restarts, auth 200/401/401/200, diagnosis in 16 s via `pods_list_in_namespace`, `pods_get`, `events_list` (`api` missing `DATABASE_URL`, `web` `nginx:faulty`), delete refused, pods unchanged, RBAC yes/no/no/no, other Pod → agent `000`, bridge `000`. ✅ **OpenCode (MiMo):** auth 200/401/401/200, bridge `000`, **one** streaming request answered in 8 s ("Kubernetes failed to pull the container image from a registry … and is retrying with backoff"); the bridge returns the whole answer as one chunk. Stack stopped afterwards |
| 42 | **Lead SRE fixer (G2)**: deploy + identity | G2 | same digests, agent config from ConfigMap | ✅ Server-side dry run, then apply: Pod `oda-agent-fixer` 2/2, 0 restarts. RBAC for `oda-fixer`: get pods, patch Deployments, delete Pods **yes**; create/delete Deployments, Secrets, `pods/exec`, other namespaces **no**. **Admission guard** (`fixer-guard-policy.yaml`, server-side dry runs as `oda-fixer`): image change and literal env **allowed**; `envFrom` Secret, `secretKeyRef`, ServiceAccount swap, Secret volume **denied**, live objects unchanged. Auth 200/401/401. Found and fixed during testing: `labels.includeSelectors` had rewritten the NetworkPolicy's CoreDNS selector, so DNS failed (`EAI_AGAIN`) |
| 43 | **Fixer, approval mode**: one prompt fixes both workloads | G2 | same | ✅ The documented demo block, run verbatim (twice; the second time with the admission guard active and the full-diff approval prompt): read-only diagnosis (`pods_list_in_namespace`, `events_list`, `pods_log`, `resources_get`), then **2 approval pauses** (`tool_call_confirmation`): `web` image `nginx:faulty` → `nginx:1.27`, `api` + `DATABASE_URL=postgres://db.oda-demo.svc:5432/app` (an earlier prompt with a password made Claude write a literal `[REDACTED]`, so the documented prompt has none). Nothing changed before each approval. The agent then verified its own fix: both Pods `1/1 Running`, 0 restarts |
| 44 | **Fixer, reject + guardrails** | G2 | same | ✅ Reject (documented block, run verbatim after re-breaking `web`): the change wasn't applied or retried; the agent gave the manual `kubectl` command, `web` stayed `nginx:faulty`. Refused without asking for any write: delete a Deployment, show Secrets, exec into a Pod, scale CoreDNS in `kube-system`. No Deployment in the cluster changed, CoreDNS replicas stayed 1. |
| 45 | **Fixer on the `be741fb` CI images** (agent `7343bb68…`, bridge `5cb09c50…`) | G2 | `sha-be741fb`, `bridge-sha-be741fb` | ✅ Fixer Pod switched to the new digests, 2/2 Running. The documented demo ran verbatim: the full-diff approval prompt showed `nginx:faulty` → `nginx:1.27` and `+ DATABASE_URL: postgres://db.oda-demo.svc:5432/app`, and both Pods ended `1/1 Running`. In an audited re-run, every write was gated 1:1 (2 write calls ↔ 2 approval pauses with the same call IDs; Deployment generations unchanged before each approval). One run hit two failed writes first (the model put `.spec.status` in the manifest) and then succeeded on retry |
| 46 | **Fixer, hands-free (`autonomous`) session** | G2 | same | ⚠️ `PATCH …/safety-policy {"safety_policy":"autonomous"}` → **no approval pause**: `web` was fixed to `nginx:1.27` straight away. So approval is a per-session default, not a control against the API-key holder (G2 updated). The hard limits (admission policy, RBAC, disabled tools) are unaffected; this change stayed within them |

---

## 🔒 Security model

All the security controls in one place, followed by the risks you still need to manage yourself.

| Control | Where |
|---|---|
| Bearer auth on the agent API; `serve chat` fails closed if the key is unset | `--api-key-env AGENT_API_KEY` |
| `serve api`: always pass `--auth-token`, publish on `127.0.0.1` only; the token holder can change session safety | runbook section F |
| Non-root, no shell, read-only rootfs, `cap-drop ALL`, `no-new-privileges` | image + run flags |
| Chat agents: no shell/filesystem/cluster/MCP tools (only `think`), `--safety strict` | `agent.yaml` |
| SRE agent: read-only MCP tools, `restricted` safety, RBAC read-only SA, Secrets denied twice, short-lived token | `agent-sre.yaml`, `k8s-mcp/config.toml`, `k8s-lab/rbac-readonly.yaml` |
| Claude Code built-in tools all denied, hooks disabled | `managed-settings.json` (verified tool list `[]`) |
| Supply chain: sha256-pinned binaries, SBOM and provenance, Trivy gate | Dockerfiles + workflow |
| No credentials in git or images; run-time env/volume only | all |

**Known risks to manage**
- 🔐 **Bridge access is key-protected.** The Claude Code CLI bridge requires `CLAUDE_BRIDGE_API_KEY`, refuses to start without it, isn't published to the host (Compose), and listens only on the Pod's loopback (Kubernetes). *(Historical: the earlier host bridges had no key, and any OrbStack container could reach them.)*
- 🧳 **(Historical, host bridge)** **A bridge on the host brings the host user's Claude context with it.** Once, the SRE agent's reply mentioned "GKE prod/staging", which was never in its prompt or cluster. For a team service, run the bridge under a dedicated account, or use the in-container harness or a direct API key.
- 🗂️ **SRE memory is shared by everyone using that server** (one SQLite file per config), and it is writable by the agent. Don't let it store secrets.
- 🔑 **A Claude OAuth token, or the `oda-claude-auth` volume, is a full credential.** Keep token files at `chmod 600`, outside git. In Kubernetes, use a Secret and a dedicated account.
- 🧩 **New Claude Code versions add tools.** Re-run the tool-list check after every `CLAUDE_CODE_VERSION` bump. CI enforces this when a credential secret exists.
- 🚫 **The Codex *harness* is intentionally not shipped.** It runs with `--dangerously-bypass-approvals-and-sandbox`, and its shell tool cannot be denied as cleanly. Codex is used only through the read-only-sandbox bridge.

---

## 🩺 Troubleshooting

Find your symptom in the left column. The middle column says why it happens, the right column what to do.

| Symptom | Cause | Fix |
|---|---|---|
| Agent log says `WARNING: … The API has no authentication` although you pass `--auth-token` | docker-agent v1.150.0 prints this for **any** non-loopback `--listen`, without checking the token (`cmd/root/api.go`, `warnIfNotLoopback`) | Cosmetic. Prove auth works: no key → `401`, wrong key → `401`, your key → `200` |
| `Error: environment variable "AGENT_API_KEY" is empty or not set` | Fail-closed start | `export AGENT_API_KEY=$(openssl rand -hex 24)` and pass `-e AGENT_API_KEY` |
| Container exits with "No API key? Run a local model instead…" | `:latest` with no flavor and no `OPENAI_API_KEY` | Add `-e OPENAI_API_KEY`, or run with a `--flavor` |
| `401` | Missing or wrong bearer token | Send `Authorization: Bearer $AGENT_API_KEY` |
| `manifest for …runtimeatest:latest not found` | zsh `:l` modifier in `$IMG:latest` | Use `${IMG}:latest` |
| `Bind for 0.0.0.0:8084 failed: port is already allocated` | Host port taken (the container port 8083 never clashes) | Pick another host port: `-p 9090:8083` |
| `reading config file agent-sre.yaml: no such file` | Stale local `latest` from before the SRE agent existed (`docker run` doesn't re-pull) | `docker pull ${IMG}:latest`, or pin `sha-<7>` |
| `curl` prints `000` right after `docker run` / `docker compose up` | The server is still starting (2–5 s), or the container exited | Use the wait loop (sections F, 🏠 and the bridge sections); check `docker ps` and `docker logs <name>` |
| Nothing listening after `docker run … --flavor x` | Partial `CMD` override | Repeat the full `serve chat /app/agent.yaml --listen 0.0.0.0:8083 --api-key-env AGENT_API_KEY --safety strict --flavor x` |
| `/v1/models` 200 but completion **500 `connection refused`** | Backend (DMR/bridge) not reachable | `curl` the backend's `/health` on the host; check the port and `host.docker.internal` |
| Completion **500 `harness claude-code failed: wait: exit status 1`** | `:claude-code` has no valid credential | Pass `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY`, or mount the login volume |
| Bridge model `400` | The bridge accepts only the ids in `--models` (default here: `claude-haiku-4-5`; no `haiku` alias) | Keep `models.claude-bridge` and the bridge's `--models` in sync |
| `failed to load agents: … must be set` | `--flavor compose`/`in-pod`/`claude-bridge` without `CLAUDE_BRIDGE_API_KEY` | Pass `-e CLAUDE_BRIDGE_API_KEY` (or the Secret key) |
| `required variable … is missing a value` from `docker compose` | Every Compose command (even `logs`/`down`) needs the stack's env vars: three for the Claude bridge stack, two for the OpenCode stack | Load the Keychain secrets, or use `docker logs <container>` |
| Pod `1/2`, bridge container not Ready | A TCP probe dials the Pod IP; the bridge listens on loopback | The shipped exec probes check `127.0.0.1:18188` from inside the container |
| Requests go to `/v1/responses` and fail | OpenAI provider auto-routing for `gpt-5*` | Keep `api_type: openai_chatcompletions` on the provider |
| Bridges missing from `lsof` | They run as another macOS user | Probe ports with `curl http://127.0.0.1:<port>/health` |
| Answers are wrong with `--flavor local` | `smollm2` is tiny | Expected; use a bridge, the harness, or a larger local model |
| 🌉 Agent error `HTTP 401: unauthorized` | `CLAUDE_BRIDGE_API_KEY` differs between agent and bridge | Use the same Keychain value for both; recreate (Compose) or `rollout restart` (k8s) |
| 🌉 Answer is an error about login or auth | `CLAUDE_CODE_OAUTH_TOKEN` missing or expired | `claude setup-token`, update the Keychain item, recreate or restart |
| 🌉 `000` on `localhost:8091` | The `port-forward` exited (it dies when its Pod is replaced, e.g. by a rollout) or was never started | `pkill -f 'port-forward svc/oda-agent'`, then start it again **after** `rollout status` |
| 🌉 Workloads vanished after an OrbStack restart | The OrbStack VM restarted. Namespaces, Secret, Service, PVC and policies survive; **Deployments are removed** (seen twice) | Re-run the `kubectl apply` steps (idempotent), then `rollout status` and restart the `port-forward` |
| 🟢 Answer is `[bridge error: OpenCode's free tier can only be used from within OpenCode …]` | Your IP is flagged by the free tier (it blocks the OpenCode app too), or a policy that removed every tool | **Don't retry.** Get a new public IP (router restart), then send one request; keep the shipped `opencode.json` (don't deny everything) |
| 🟢 Agent `HTTP 401` from the OpenCode bridge | `OPENCODE_BRIDGE_API_KEY` differs between services | Same key for both (one env var); `docker compose up -d --force-recreate` |
| 🟢 `opencode run` hangs when you test the CLI by hand | It reads stdin when stdin isn't a TTY | Pipe the prompt in, or add `</dev/null` |
| 🟢 The agent asks for tools or tool calls are ignored | The OpenCode bridge has no function calling | Use the Claude Code CLI bridge for the SRE agent |

🌉 = Claude Code CLI bridge · 🟢 = OpenCode CLI bridge.

> 🗒️ **Repo note (pre-existing, unchanged):** `pi-agents/macos/opencode/opencode/pure-llm.json` sets nearly every permission to `"allow"`, although that README describes it as a pure-LLM, tools-denied config. Review it before relying on it.

---

## 🛠️ Operations: upgrades, rotation, cleanup

Day-2 tasks: upgrading the pinned versions, rotating secrets, and cleaning up your machine.

**Upgrade docker-agent.** Bump `DOCKER_AGENT_VERSION` and both `SHA256_*` args in **both** Dockerfiles, taking checksums from the release assets. Push, CI rebuilds, then re-run the verification matrix against the new `sha-<7>` tags.

**Upgrade Claude Code.** Get the version and checksums from the official manifest, then bump `CLAUDE_CODE_VERSION` and `CLAUDE_SHA256_*` in `Dockerfile.claude-code`. **Then re-check the init tool list**, and add any new tool to `managed-settings.json` until the list is `[]`.

```bash
V=$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest)
curl -fsSL https://downloads.claude.ai/claude-code-releases/$V/manifest.json \
  | jq -r '.version, (.platforms|to_entries[]|select(.key=="linux-x64" or .key=="linux-arm64")|"\(.key) \(.value.checksum)")'
```

**Rotate.**
- `AGENT_API_KEY`: regenerate it per deployment.
- Claude OAuth token: re-run `claude setup-token` and replace the file or the GitHub secret.
- Docker Hub: rotate the access token and update the `DOCKER_HUB` secret.

**Clean up.**

```bash
docker rm -f oda oda-cc 2>/dev/null
docker volume rm oda-claude-auth 2>/dev/null   # deletes a stored Claude login
docker image prune -f
```

---

## 🧭 Limitations and roadmap

What doesn't work yet, and what's planned next.

**Limitations**
- **Harness requests are flattened** into one prompt, made of the instruction plus the conversation. docker-agent toolsets and `--safety` don't apply inside it.
- **Token usage:**
  - The Claude bridge and the harness carry Claude Code's large system prompt, roughly 14–15k prompt tokens even for one-line answers.
  - The Codex bridge reports usage 0 when streaming.
- **CI can't reach the Mac**, so backends A and B are verified locally only.
- **Trivy HIGH:** CVE-2026-78669 inside docker-agent v1.150.0 (upstream `golang.org/x/net`). It clears with the next upstream release built on `x/net ≥ 0.60.0`.

**Roadmap**

| Milestone | Status |
|---|---|
| Agent config, runtime images, CI build/scan/push | ✅ |
| Local model, bridge, and in-container Claude Code E2E | ✅ |
| Authenticated harness E2E in CI | ⏭️ Needs a repo secret |
| Bridge API key + `token_key` (agent → bridge) | ✅ (`CLAUDE_BRIDGE_API_KEY`; the bridge refuses to start without it) |
| Agentic read-only Kubernetes SRE agent + persistent memory | ✅ (OrbStack k8s) |
| CI: MCP tool-list + memory persistence assertions, disposable-cluster RBAC tests | ⬜ (today CI only checks the SRE config loads) |
| CI: build once, test/scan each arch by digest, promote that digest | ⬜ (today: amd64 test build, then a multi-arch rebuild) |
| Agent-config OCI artifact (`docker agent share push`) | ✅ tested earlier, then removed from CI on purpose (not used by any setup here; it confused people with the runtime images) |
| Kubernetes test deployment | ✅ OrbStack (section G) |
| Security review and production promotion | ⬜ |

**☸️ Kubernetes: done locally vs next for production**

| ✅ Done and verified locally (section G) | ⬜ Next for production |
|---|---|
| Single replica, `Recreate`, PVC for SQLite sessions and memory | HA design (sessions in an external store) or accept single-writer |
| Image pinned by digest | Automated digest bumps from CI (e.g. kustomize `images:`) |
| Non-root 65532, read-only rootfs, `drop: [ALL]`, seccomp `RuntimeDefault`, limits | Pod Security Admission `restricted` label on the namespace |
| Read-only, namespace-scoped RBAC; **automount on** (the MCP server needs the API) | Separate read-only Roles per target namespace; audit logging |
| Secret → `$(AGENT_API_KEY)` expansion; key never in YAML | External secret manager (e.g. ESO/Vault) and rotation automation |
| Ingress deny + egress allowlist (DNS, API, HTTPS 443) | FQDN egress (egress proxy / Cilium) to Anthropic only, instead of all public 443 |
| Bridge as an in-Pod sidecar (loopback, bearer key, pre-authenticated token) | Short-lived credentials; per-team bridge tokens |
| `ClusterIP` + `port-forward` | Internal gateway with TLS and authentication |
| Probes: `/ready` and `/health` on `8080` | Alerting on probe failures, OTel traces to your backend |

---

## ⚖️ Comparison, memory and gotchas

Read this if you're deciding whether Docker Agent fits your team, or want to understand how agent memory works.

> 🎓 Part of **OpenDevOps**, an educational and training repo for the DevOps/SRE community.
> 🧪 Every Docker Agent claim here was either **tested live** in this project (✅) or read from the **docker-agent v1.150.0 source** (📖, with file path).
> 🌐 Other frameworks are cited from their official docs and repos. Versions and stars are a **2026-10-17 snapshot** of the GitHub API and will drift, so re-check them before quoting.
> ❓ Anything not verified is marked **UNVERIFIED**.

### 🎯 What problem does this agent solve?

| | 💬 Chat agent | 🛠️ SRE agent |
|---|---|---|
| 📄 Config | `agent.yaml`, `agent-claude-code.yaml` | `agent-sre.yaml` |
| 🧩 Problem solved | A **governed, OpenAI-compatible SRE advisor endpoint**. One fixed instruction, bearer auth, a pinned image, and a swappable backend (local model, Claude Code, Codex) | **First-line Kubernetes triage**. It lists pods, reads events and logs, inspects resources, explains the root cause with evidence, and hands a human the exact fix |
| 🔧 Tools | `think` only, which reaches nothing outside the model | Read-only Kubernetes MCP tools + `memory` + `think` |
| 👀 Sees your systems? | ❌ No. It only reasons over what you paste (the model runs through the [Claude Code CLI bridge](#-claude-code-cli-bridge) next to the agent) | ✅ Yes, read-only, through a RBAC-scoped ServiceAccount |
| ✍️ Can change anything? | ❌ No | ❌ Not the cluster (RBAC-enforced). ✍️ It writes only to its own memory file |
| 🧪 Proven | ✅ Correct CrashLoopBackOff advice | ✅ Diagnosed `ImagePullBackOff` (bad tag `nginx:faulty`) and `CrashLoopBackOff` (missing `DATABASE_URL`) on its own, in 37 s |

**Typical uses** 💡
- 🧑‍🚒 An "ask the cluster" API for the on-call engineer.
- 🤖 A triage step inside an incident bot or CI job.
- 🧪 A safe sandbox for comparing models (local, Claude, Codex) on the same task.
- 🎓 Training material showing how to give an AI agent **least-privilege** access.

### 🧠 Memory: the deep dive

**Short answer.** Docker Agent has **three independent kinds of memory, and upstream turns all of them off by default** (all three tested here). In this project, the chat endpoint (`agent.yaml`) stays stateless, and the **SRE agent (`agent-sre.yaml`) explicitly enables long-term memory**. Hermes has memory built in, and can learn new skills.

#### 1️⃣ Conversation memory (short-term)

| | Detail |
|---|---|
| ⚙️ Default | **Stateless.** Each `POST /v1/chat/completions` is independent, so the client must resend the history (like the OpenAI API) |
| 🔛 Opt-in | Start the server with `--conversations-max N` and send an `X-Conversation-Id: <id>` header. The server then keeps the history, and you send only the newest message 📖 `pkg/chatserver/server.go:371-440` |
| ⏳ Lifetime | In-process cache with an idle TTL (`--conversation-ttl`, default `30m`). **Lost on restart.** Not shared between replicas |
| 🔒 Concurrency | One request at a time per conversation id. A second request in flight gets **HTTP 409** 📖 `server.go:372` |
| 🧪 Evidence | ✅ With the header, turn 2 sent **647** prompt tokens to the model (vs 121 without), and the debug log showed `total_messages` 3 → 5, with turn 1 carried forward |

```bash
# server:  ... serve chat /app/agent.yaml ... --conversations-max 100
curl -s -H "Authorization: Bearer $AGENT_API_KEY" -H 'X-Conversation-Id: incident-42' \
  -H 'Content-Type: application/json' http://localhost:8084/v1/chat/completions \
  -d '{"model":"root","messages":[{"role":"user","content":"Which flag shows the previous container?"}]}'
```

#### 2️⃣ Long-term memory (the `memory` toolset)

| | Detail |
|---|---|
| 🗄️ Storage | One **SQLite** file. Table `memories(id, created_at, memory, category)` 📖 `pkg/memory/database/sqlite/sqlite.go:77-83` |
| 📍 Location | Default `~/.cagent/memory/<config>/memory.db`, or `path:` in YAML. The SRE agent stores it under `/data` (directory owned by UID 65532, mode `0700`) |
| 🔧 Tools | `add_memory` ✍️, `update_memory` ✍️, `delete_memory` 🗑️, `get_memories` 👀, `search_memories` 🔎 📖 `pkg/tools/builtin/memory/memory.go:100-155` |
| 🔎 Search | **Keyword `LIKE` matching, every word must match (AND)**, plus an optional category filter. **No embeddings and no semantic search** 📖 `sqlite.go:206-224` |
| 👥 Scope | **Per agent config, not per user.** Everyone using the same server shares one memory |
| 🧠 Who decides what to save? | **The model**, by calling `add_memory`. Nothing is saved automatically |
| 🛡️ Safety gotcha | Under `--safety restricted`, `add_memory` is **silently denied** because it isn't marked read-only 📖 `pkg/runtime/toolexec/permissions.go:140-144`. The SRE agent explicitly allows `add_memory` and `update_memory`, and keeps `delete_memory` denied |
| 🧪 Evidence | ❌ then ✅. First run: the model said the memory tool "isn't available" (denied). After the fix, it saved a team fact (owned namespace + on-call name), the **container was restarted**, and a **new conversation recalled it** via `search_memories` |

#### 3️⃣ Session history (`serve api`)

| | Detail |
|---|---|
| 🗄️ Storage | `docker agent serve api --session-db session.db` persists full sessions in SQLite, and they can be resumed |
| 🔍 Tooling | `docker agent sessions …` inspects them. `session_context` lets an agent reference a previous session |
| 🧪 Evidence | ✅ Created a session, ran the SRE agent, then a follow-up **without resending history** answered in 1 s. After a **container restart**, the session (6 messages, auto-title) was still there. See [section F](#f--native-api-serve-api-sessions-over-curl) |

#### 4️⃣ Knowledge (RAG), which is not "memory" but often confused with it

The `rag` toolset searches **your documents**: hybrid BM25 plus embeddings, reranking, tree-sitter chunking 📖 `pkg/rag/`. Use it for runbooks and postmortems. It can't remember facts *during* a conversation.

#### 🧠 Memory comparison: Docker Agent vs Hermes vs LangGraph

| | 🐳 Docker Agent | 🪽 Hermes Agent | 🦜 LangGraph |
|---|---|---|---|
| Default | 🚫 Off upstream (this repo's SRE agent turns long-term memory on) | ✅ Built in | 🚫 Off (add a checkpointer) |
| Short-term | In-process cache via `X-Conversation-Id` | Session history (SQLite, FTS5 search) | **Checkpointers** (Postgres, Mongo, …), durable across pods |
| Long-term facts | SQLite key-value, keyword search | `MEMORY.md` (~2,200 chars) + `USER.md` (~1,375 chars), loaded at session start | `Store` (key-value, optional semantic search) |
| Learns by itself | ❌ | ✅ Can write and patch its own **skills** after tasks (optionally behind a review queue) | ❌ (you build it) |
| Semantic recall | ❌ (RAG is separate) | Via plugins (Honcho, Mem0, Supermemory) | ✅ Optional embeddings in the store |
| Multi-user isolation | ❌ Shared per config | Per profile | Per thread or namespace (you design it) |
| Survives restart | Long-term memory ✅, `serve api` sessions ✅, `serve chat` cache ❌ | ✅ | ✅ (with a durable checkpointer) |

> 💡 **Takeaway:** treat Docker Agent memory as a **small, explicit notebook** the agent writes to when asked. It isn't a personal assistant's evolving memory (Hermes), and it isn't a durable workflow state store (LangGraph).

### 🪽 Docker Agent vs Hermes Agent

| Dimension | 🐳 Docker Agent (this project) | 🪽 Hermes Agent (Nous Research) |
|---|---|---|
| 🧬 What it is | Declarative agent **runtime/framework** | **Self-improving personal/team agent** |
| 📜 License · version | Apache-2.0 · v1.150.0 | MIT · v0.22.x |
| 🗣️ Interface | TUI; `serve chat` (OpenAI API), `api`, `a2a`, `acp`, `mcp` | CLI, desktop, web dashboard, API, messaging bots |
| 🧠 Memory | Opt-in (3 kinds, see above) | Always-on profile memory + session search |
| 📈 Learning | ❌ None | ✅ Skills loop (`SKILL.md` files it writes and refines) |
| 🔧 Tools | 30 built-in toolsets + MCP | 40+ tools, `execute_code`, MCP |
| 🤝 Multi-agent | Sub-agents, handoffs, background agents, A2A | Isolated sub-agents |
| ⏰ Scheduling | `scheduler` toolset, **in-memory only** (lost on restart) | Persistent cron, delivered to chat platforms |
| 💬 Chat-ops | ❌ None built in (UNVERIFIED) | ✅ 20+ platforms (Telegram, Slack, Discord, …) |
| 🛡️ Safety model | **Deterministic** modes (`strict` / `balanced` / `restricted` / `autonomous`) + allow/deny rules. Headless "ask" → deny | **LLM-judged** "smart" approvals, or manual/off, plus a hard blocklist. Per the Hermes security docs, dangerous-command checks are skipped on container backends (the container is treated as the boundary) |
| 📦 Packaging | One static Go binary; distroless image; OCI agent artifacts | Python app; Docker image; serverless backends |
| ☸️ Kubernetes fit | ⭐ Strong: small, stateless by default, bearer auth, easy to lock down | Stateful (needs a PVC); runs on GKE in this repo |
| 📊 Observability | OpenTelemetry (OTLP/HTTP) | Dashboard + logs (OTel UNVERIFIED) |
| 🧑‍💻 How this repo uses it | Governed SRE API + read-only cluster investigator | Long-lived operator assistant: sessions, skills, schedules, chat gateways |
| 🏆 Best at | **Embedded, governed, CI-testable agents and APIs** | **A personal assistant that remembers and improves** |

#### 🤝 They work best together

```text
👤 You ──Slack/Telegram──▶ 🪽 Hermes (memory, skills, schedules)
                                  │ OpenAI-compatible call
                                  ▼
                           🐳 Docker Agent SRE (read-only tools, RBAC, pinned image)
                                  │
                                  ▼
                           ☸️ Kubernetes (get / list / watch only)
```

- **Hermes** is the friendly front door that knows *you*.
- **Docker Agent** is the narrow, auditable worker that touches the cluster.
- Wiring Hermes to `serve chat` as an OpenAI-compatible provider is ⬜ **not yet built** (UNVERIFIED).

### 🦜 Docker Agent vs LangChain and other agent frameworks

#### 🗺️ The landscape at a glance

| Framework | 🧑‍💻 Lang | 🏗️ How you build | 📜 License | 🏷️ Version | ⭐ Stars |
|---|---|---|---|---|---|
| 🐳 **Docker Agent** | Go binary | **YAML (no code)** | Apache-2.0 | v1.150.0 | ~4.5k |
| 🦜 **LangChain + LangGraph** | Py / JS | Code + state graph | MIT | LangGraph 1.2.16 | ~148k / ~43k |
| 👥 **CrewAI** | Py | Code (crews and flows) | MIT | 1.15.28 | ~60k |
| 🪟 **Microsoft Agent Framework** (absorbed AutoGen + Semantic Kernel) | Py / .NET / Go | Code + graph, YAML optional | MIT | python-1.22.0 | ~14k |
| 🟢 **OpenAI Agents SDK** | Py / JS | Code | MIT | v0.24.0 (pre-1.0) | ~30k |
| 🟠 **Claude Agent SDK** | Py / TS | Code (Claude Code as a library) | MIT + Anthropic terms | v0.2.168 | n/a |
| 🔵 **Google ADK** | Py / TS / Go / Java / Kotlin | Code + graph (2.0) | Apache-2.0 | v2.12.0 | ~22k |
| 🟧 **AWS Strands Agents** | Py / TS | Code (model-driven loop) | Apache-2.0 | v1.61.1 | ~8.8k |
| 🔷 **PydanticAI** | Py | Typed code, YAML specs optional | MIT | v2.57.0 | ~21k |
| 🦙 **LlamaIndex agents** | Py / TS | Code + event workflows | MIT | v0.14.25 | ~53k |
| 🧩 **n8n / Dify** | TS / Py | Visual low-code | Fair-code / modified Apache | 2.43.7 / 1.17.1 | n/a |

> ℹ️ As of 2026-10-17, the [AutoGen README](https://github.com/microsoft/autogen) says it is archived and points to Microsoft Agent Framework, and the [Semantic Kernel README](https://github.com/microsoft/semantic-kernel) presents MAF as its successor. For new projects, Microsoft's guidance is to start with MAF.

#### 📊 Feature matrix

| Dimension | 🐳 Docker Agent | 🦜 LangGraph | 👥 CrewAI | 🪟 MAF | 🟢 OpenAI SDK | 🟠 Claude SDK | 🔵 ADK | 🟧 Strands | 🔷 PydanticAI | 🦙 LlamaIndex |
|---|---|---|---|---|---|---|---|---|---|---|
| 🧠 Memory | SQLite sessions + keyword memory + RAG | ⭐ Checkpointers (Postgres, Mongo) + Store | Built-in (UNVERIFIED) | Checkpointed workflows | SQLAlchemy, Redis, Mongo, Dapr sessions | Sessions, resume/fork | Session + Memory services | Session managers | Via Temporal / DBOS / Prefect | Memory + workflow state |
| 🔌 MCP | ✅ stdio, remote, **Docker catalog** | ✅ adapters | ✅ | ✅ | ✅ | ✅ | ✅ consume + expose | ✅ | ✅ | ✅ |
| 🤝 Multi-agent | Sub-agents, handoff, A2A | ⭐ Graphs, supervisor | ⭐ Crews | Graph orchestration, A2A | Handoffs | Subagents | Workflow agents, A2A | Swarm, graph, A2A | Graph, delegation | AgentWorkflow |
| 🛡️ Safety / approvals | ⭐ **4 deterministic modes** + rules; `restricted` fails closed headless (harness excluded) | Interrupts (approve, edit, reject) | UNVERIFIED | Human-in-the-loop, middleware | Guardrails + human-in-the-loop | Permission modes + hooks | Action confirmations | Guardrails, steering | Deferred-tool approvals | Human-in-the-loop events |
| 🌐 Serving API | ⭐ **Built-in OpenAI-compatible** `serve chat` | LangSmith Deployment | AMP (UNVERIFIED) | Foundry Hosted | Build your own | Build your own | `api_server` | Build your own | Build your own | llamactl |
| 📦 Container / k8s | ⭐ **One static binary**, distroless-friendly | Python image | Python image | Python / .NET image | Python image | Bundles the Claude Code CLI | Cloud Run / GKE built in | Python image | Python image | Python image |
| 📊 Observability / evals | OTel (HTTP) + `docker agent eval` | ⭐ **LangSmith** (best in class) | UNVERIFIED | OTel | Built-in tracing | Hooks | Evals + user simulation | OTel + evals SDK | Logfire + Pydantic Evals | Instrumentation |
| 🚚 Distribution | ⭐ **OCI artifacts** (`share push`, signable) | Code / package | Code | Code | Code | Code | Code | Code | Code | Code |
| ⏯️ Durable execution | ❌ No (sessions resumable from local SQLite only) | ⭐ Yes | Flows | ✅ Checkpoints | Sessions | Resume/fork | Sessions + rewind | Sessions | ⭐ Temporal / DBOS | Workflows |

#### 💪 Where Docker Agent is genuinely better (for a DevOps/SRE platform team)

1. 📄 **The agent is configuration, not code.** Model, tools, permissions, safety mode and budgets live in one YAML file, so a reviewer sees the whole behaviour change in a **PR diff**. MAF and PydanticAI offer YAML too, but as an option on top of code.
2. 🛡️ **Safety enforced by the runtime, not the prompt.** `restricted` denies destructive or unknown tool calls **without asking**, which is ideal for headless services. Other frameworks also offer approvals, guardrails or permission modes (LangGraph interrupts, OpenAI guardrails, Claude SDK permission modes). The difference here is that a fail-closed headless policy is **one declarative setting**. This does not cover harness mode, which bypasses it. Docker's own docs say `restricted` is fail-closed but **not a security boundary**, so pair it with RBAC as this repo does.
3. 🌐 **An OpenAI-compatible server is built in.** Any SDK, chat UI or gateway can call it immediately. Python SDKs leave you to write a FastAPI layer.
4. 📦 **One static Go binary.** No Python dependency tree, fast start, and this repo's image is **~220 MB** (measured with `docker image inspect`, `sha-fba9fc0`, arm64): distroless and non-root, and run with `--read-only`.
5. 🚚 **Agents ship like images.** `docker agent share push` stores agents as **OCI artifacts** (signable) in the registry you already run. To our knowledge, none of the other frameworks here document OCI-native agent distribution (UNVERIFIED).
6. 🔌 **Docker MCP catalog** and sandboxed MCP servers. Tools come as containers, too.
7. 🎛️ **Harness mode** drives Claude Code, Codex, opencode or pi as sub-agents behind one OpenAI-compatible API (✅ tested here with Claude Code).
8. 🤖 **CI-friendly.** `--exec --json` emits NDJSON events, OTel GenAI spans are built in, and `docker agent eval` runs evals in containers.

#### 🐢 Where Docker Agent is weaker

1. 🔀 **Control flow.** There are no typed state graphs. You get sub-agents, handoffs and a keyword-based router. LangGraph, MAF, ADK 2.0 and Pydantic Graph give you explicit state machines with branches, loops and code nodes.
2. ⏯️ **Durable execution.** No native distributed checkpointing: sessions are a local SQLite file, with no Postgres/Redis checkpointers and no Temporal/DBOS. A session can be resumed only where that file lives (e.g. a PVC), which is not the same as durable workflow execution across pods.
3. 🧠 **Memory backends.** One keyword-searched SQLite store per config, against pluggable vector and semantic stores elsewhere.
4. 📊 **Eval and observability depth.** It's solid but not at **LangSmith's** level (datasets, online evals) or ADK's user simulation. OTLP export is HTTP only.
5. 🌱 **Ecosystem and maturity.** About **4.5k stars versus about 148k for LangChain**, a fast-moving schema (150 releases), and a smaller integration catalog. Custom logic means writing an **MCP server**, not a Python function.
6. ☸️ **Kubernetes packaging.** No upstream Helm chart or operator. This repo adds a tested **kustomize** deployment for local Kubernetes (OrbStack): RBAC, NetworkPolicies, a PVC and a digest-pinned image ([section G](#g-%EF%B8%8F-run-the-sre-agent--bridge-sidecar-inside-local-kubernetes-orbstack)). A Helm chart is still unfinished.
7. 📡 **Product telemetry is on by default.** Set `TELEMETRY_ENABLED=false` (done in this repo's images).

### 🧭 Which one should I choose?

| If you… | Choose | Why |
|---|---|---|
| 🛠️ Ship **tool-using ops agents as reviewed config**, need fail-closed headless safety, an OpenAI endpoint, tiny images, OCI distribution | 🐳 **Docker Agent** | The ops-artifact story is unmatched |
| 🔀 Need **complex stateful workflows**, durable resume across pods, approve/edit/reject, best-in-class evals | 🦜 **LangGraph + LangSmith** | Graphs, checkpointers, LangSmith |
| 🪟 Live in **.NET / Azure**, or are migrating from AutoGen or Semantic Kernel | 🪟 **Microsoft Agent Framework** | The official successor of both |
| ☁️ Are on **GCP** and want Cloud Run, GKE or Agent Runtime, multi-language SDKs, evals with user simulation | 🔵 **Google ADK** | Built-in deploy and eval path |
| 🟧 Are **AWS-centric** and want a lightweight loop with budgets and guardrails | 🟧 **Strands Agents** | AWS-native, model-driven |
| 🐍 Want **type-safe Python** and long-running durable agents | 🔷 **PydanticAI** | Temporal/DBOS + Logfire |
| 🏷️ Are committed to **one model vendor** | 🟢 OpenAI SDK / 🟠 Claude SDK | First-party features |
| 👥 Want role-based **agent teams** · 📚 **RAG-heavy** agents · 🧩 **non-engineers** build flows | 👥 CrewAI · 🦙 LlamaIndex · 🧩 n8n/Dify | Fit-for-purpose |
| 🧑 Want a **personal assistant that remembers you** and lives in Slack/Telegram | 🪽 **Hermes** | Memory + skills + gateways |

> 🏁 **Bottom line:** Docker Agent is the best **operations artifact** here: declarative, policy-gated, one binary, OCI-shipped, OpenAI-served. LangGraph, MAF, ADK and PydanticAI are better **application frameworks** for complex stateful logic. A sound pattern is to **keep the read-only SRE worker in Docker Agent** and expose it (via `serve chat` or A2A) to a richer orchestrator or to Hermes.

### ✅ Pros and ❌ cons of Docker Agent

| ✅ Pros | ❌ Cons |
|---|---|
| 📄 Reviewable YAML agents; flavors switch backends without rebuilds | 🧠 No memory by default; long-term memory is shared per config, keyword-only, no learning |
| 🛡️ Fails closed headless with `restricted` (not in harness mode) | 🤫 Safety modes fail **silently**: tool denied, model says "not available" |
| 📦 Small static binary; distroless, non-root, read-only | 🎛️ Harness mode bypasses docker-agent's safety, so you must lock the CLI down yourself |
| 🌐 Built-in OpenAI-compatible API with bearer auth | 💸 Expensive through Claude Code: ~15k tokens of overhead per call, ~73k for one investigation |
| 🔌 30 toolsets + MCP (stdio, remote, Docker catalog) | 💬 No chat-ops gateways; `scheduler` is in-memory only |
| 🤝 Sub-agents, handoffs, background agents, A2A | 🔀 No state graphs or durable execution |
| 💰 Shared budgets, 📊 OTel, 🧪 `eval` | 🏃 Fast-moving upstream; frequent pin bumps; 1 HIGH CVE in the current binary |
| 🔄 Backend-agnostic: local models, APIs, CLIs | 🌱 Smaller ecosystem; custom logic = MCP server |

### 🧰 Is building an agent with Docker simple?

**👋 Hello world: yes.** It takes about 10 lines of YAML and one command:

```yaml
agents:
  root:
    model: dmr/ai/smollm2
    instruction: You are a helpful SRE.
```

Then run `docker agent run agent.yaml`.

**🏭 A hardened, headless, tool-using service: no.** These are the real gotchas hit while building this project:

| # | 🪤 Gotcha | 🩹 Fix used here |
|---|---|---|
| 1 | `--safety strict` **denies every tool call** in headless `serve chat`, because nobody can answer the prompt | Chat agents keep `strict` (no real tools); the SRE agent uses `restricted` |
| 2 | `restricted` denies non-read-only tools, including `add_memory`, **silently** | A narrow `permissions.allow` for the memory write tools |
| 3 | Harness mode runs Claude Code with `--dangerously-skip-permissions`; docker-agent's `--safety` doesn't apply | `managed-settings.json` denies **all** tools; re-check after every CLI bump (new tools appeared once) |
| 4 | The OpenAI provider auto-routes `gpt-5*` to `/v1/responses` | `api_type: openai_chatcompletions` |
| 5 | A custom provider without `token_key` sends **no auth** | `token_key: CLAUDE_BRIDGE_API_KEY`: the bridge requires a bearer key |
| 6 | MCP tools must exist inside the image | sha-pinned static `kubernetes-mcp-server` |
| 7 | Distroless has no shell, so `shell`/`script` toolsets can't work | MCP tools instead |
| 8 | The kubernetes-mcp-server `config` toolset can expose the kubeconfig token | `toolsets = ["core"]` only |
| 9 | `/v1/models` returns 200 even when the backend is down | Tests assert on real completions |
| 10 | `docker run` never re-pulls an existing local `latest` | `docker pull` first, or pin `sha-<7>` |
| 11 | zsh: `$IMG:latest` → `…runtimeatest`; pasted `# comments` break | `${IMG}:latest`; `setopt interactivecomments` |
| 12 | `COPY` drops the directory mode you set in the build stage | `COPY --chmod=0700` |
| 13 | The bridge strips all `CLAUDE_CODE_*` env vars, including the OAuth token the in-container CLI needs | One-line patch keeping `CLAUDE_CODE_OAUTH_TOKEN` (`_SCRUB_ENV_KEEP`) |
| 14 | Kubelet probes dial the Pod IP, but the bridge sidecar listens on loopback | Exec probes that connect to `127.0.0.1:18188` from inside the container |
| 15 | `docker compose logs` fails when `${VAR:?}` secrets aren't loaded | Load the secrets, or use `docker logs <container>` |

> 🎓 **Lesson for learners:** the YAML is the easy part. **Least privilege, headless safety semantics, and testing what you document** are where the real engineering lives.

### 📚 Sources

- 🐳 **Docker Agent:**
  - [docs](https://docs.docker.com/ai/docker-agent/) · [site](https://docker.github.io/docker-agent/) · [GitHub](https://github.com/docker/docker-agent)
  - [permissions](https://docker.github.io/docker-agent/configuration/permissions/) · [memory](https://docker.github.io/docker-agent/tools/memory/) · [chat server](https://docker.github.io/docker-agent/features/chat-server/) · [distribution](https://docker.github.io/docker-agent/concepts/distribution/) · [harnesses](https://docker.github.io/docker-agent/features/harnesses/) · [eval](https://docker.github.io/docker-agent/features/evaluation/)
  - Source v1.150.0 paths, as cited inline.
- 🪽 **Hermes Agent:** [GitHub](https://github.com/NousResearch/hermes-agent) · [docs](https://hermes-agent.nousresearch.com/docs/) (security, memory, skills)
- 🦜 **LangGraph / LangChain:** [overview](https://docs.langchain.com/oss/python/langgraph/overview) · [human-in-the-loop](https://docs.langchain.com/oss/python/langchain/human-in-the-loop)
- 👥 **CrewAI:** [docs](https://docs.crewai.com/en/introduction)
- 🪟 **Microsoft Agent Framework:** [GitHub](https://github.com/microsoft/agent-framework) · [AutoGen (archived)](https://github.com/microsoft/autogen) · [Semantic Kernel](https://github.com/microsoft/semantic-kernel)
- 🟢 **OpenAI Agents SDK:** [docs](https://openai.github.io/openai-agents-python/)
- 🟠 **Claude Agent SDK:** [overview](https://code.claude.com/docs/en/agent-sdk/overview)
- 🔵 **Google ADK:** [adk.dev](https://adk.dev/)
- 🟧 **Strands Agents:** [GitHub](https://github.com/strands-agents/sdk-python) · [docs](https://strandsagents.com/)
- 🔷 **PydanticAI:** [docs](https://pydantic.dev/docs/ai/overview/)
- 🦙 **LlamaIndex:** [agents](https://developers.llamaindex.ai/python/framework/understanding/agent/)
- 🧩 [n8n](https://github.com/n8n-io/n8n) · [Dify](https://github.com/langgenius/dify)

---

**References:** [Docker Agent docs](https://docs.docker.com/ai/docker-agent/) · [CLI: API & chat server](https://docs.docker.com/ai/docker-agent/features/cli/) · [Agent distribution](https://docs.docker.com/ai/docker-agent/concepts/distribution/) · [Upstream source](https://github.com/docker/docker-agent) · [Claude Code settings](https://code.claude.com/docs/en/settings)

---

## 🏢 Organization use cases & next PoC — Docker Agent + RAG + long-term memory

> **Scope and evidence:** This repository already documents a locally tested, read-only Kubernetes SRE investigation agent, multi-agent delegation, SQLite long-term memory recall after a restart, and persistent API sessions (see the [verification matrix](#-verification-matrix)). **A customer-facing assistant with PostgreSQL, pgvector and a dedicated memory MCP service has NOT yet been implemented or tested here.** In the table below, rows marked **✅ Existing** summarize documented local tests; rows marked **🧪 Proposed** are not implemented.

### 🎯 Real-world use cases

| Use case | Example user request | Suggested Docker Agent integration | Status |
|---|---|---|---|
| ☸️ **SRE / Kubernetes incident assistant** | “Why is the checkout Pod in CrashLoopBackOff?” | Read-only Kubernetes MCP tools, namespace-limited RBAC, logs and events | ✅ Existing local PoC |
| 🛠️ **Human-approved remediation** | “Fix the failing workloads in oda-demo.” | Write-capable Kubernetes MCP tools, admission policy + RBAC limits, a human approves each change ([G2](#g2-%EF%B8%8F-lead-sre-fixer-agent-human-approved-fixes), [DEMO.md](./DEMO.md)); approval is the default, and the API-key holder can switch it off (verification row 46) | ✅ Existing local PoC |
| 🤝 **Multi-agent troubleshooting** | “Ask the log specialist why checkout returns 500s.” | Root coordinator delegates to a log-analysis sub-agent | ✅ Existing local PoC |
| 🌐 **Company website / FAQ assistant** | “What products do you sell, and how is your support priced?” | Document RAG over approved website pages, FAQs and product documents; source links in answers | 🧪 Proposed |
| 🧠 **Customer assistant with long-term memory** | “I contacted you last week about an annual plan. Can we continue?” | Authenticated customer ID + memory MCP service + PostgreSQL; optional pgvector semantic recall | 🧪 Proposed |
| 🛍️ **Sales / product recommendation agent** | “Which plan fits 80 employees and our budget?” | Product-catalog RAG + read-only pricing/CRM MCP tools; approval for sending quotes | 🧪 Proposed |
| 🎫 **Customer support and ticket triage** | “What happened to support case 1234?” | Authenticated help-desk API through an allowlisted MCP tool; draft escalation for human approval | 🧪 Proposed |
| 🧑‍💼 **Internal employee knowledge assistant** | “How do I request access or find our deployment policy?” | Private knowledge RAG with document-level access controls and SSO | 🧪 Proposed |
| 🔄 **CI/CD investigation assistant** | “Why did the release pipeline fail?” | Read-only GitHub/Jenkins/build-log tools; suggest fixes without automatically deploying | 🧪 Proposed |

**What Docker Agent provides:** agent instructions, model selection, agent-to-agent delegation, tool orchestration and an API interface. **What you add:** an authenticated website/chat frontend, business APIs, customer-scoped persistence, document ingestion, monitoring and security policies. Docker Agent is not a ready-made multi-tenant customer-support SaaS platform.

### 🏗️ Proposed customer-support PoC architecture (not yet deployed)

```text
Browser / website chatbot
         |
         v
Authentication + API gateway (verified tenant_id / customer_id)
         |
         v
Docker Agent (support / sales / product specialists)
    |               |                 |
    |               |                 +--> Approved business MCP tools --> CRM / tickets / order APIs
    |               |
    |               +--> Knowledge retrieval (RAG) --> Approved company/product docs
    |                         |
    |                         +--> Docker Agent built-in RAG (local indexes), OR
    |                               custom retrieval MCP service + PostgreSQL/pgvector
    |
    +--> Custom memory MCP service --> PostgreSQL customer memories
                                         (tenant_id, customer_id, consent, retention)
```

**Separate three concepts:** (1) chat/session history stores messages; (2) **long-term customer memory** stores deliberately selected facts or preferences; (3) **RAG** retrieves approved company knowledge. Docker Agent's built-in memory tool is SQLite with **no per-user isolation**: every agent and user that uses the same memory database shares it. Built-in RAG stores its indexes in **local SQLite** databases, not pgvector. Customer-scoped PostgreSQL/pgvector memory needs a separately built service (for example an MCP server).

### 🧪 Next PoC — customer chatbot with memory across sessions

1. **Knowledge baseline:** load a small, versioned set of approved company pages, product descriptions and FAQs. Connect Docker Agent's built-in RAG toolset **or** a custom retrieval MCP server. Require source URLs and an honest “I do not know” when documents do not support the answer.
2. **Customer identity and session ownership:** authenticate a test customer in the frontend. The gateway passes a **verified** tenant/customer context to the memory API, not an identity supplied by the model or accepted from untrusted chat text. The agent's `AGENT_API_KEY` is an **operator** credential (it can read any session and change its safety policy), so it stays server-side: the gateway checks that every session request belongs to the calling customer and never exposes `/resume`, `/safety-policy`, `/permissions` or session listing to customers.
3. **Long-term memory:** build an MCP service with tightly scoped `save_memory`, `search_memory` and `delete_memory` operations backed by PostgreSQL. Persist only approved customer facts (e.g. a preferred plan and consent status), not passwords, payment details or secret tokens.
4. **Semantic recall (optional):** add pgvector columns and an embedding pipeline for searching memories or company documents. Apply authorization **before** returning matching records; do not treat vector search as an access-control boundary.
5. **Agent wiring:** connect the MCP toolset to a dedicated `customer_support` agent, with separate sales and support sub-agents only when specialization adds value. Keep the existing read-only SRE agent and Kubernetes credentials isolated from the public customer agent.
6. **End-to-end demonstration:** Customer A says “Remember that I prefer the annual support plan” and consents; restart the agent and memory service, start a new conversation, then ask “Which plan did I prefer?” The answer should come from Customer A's persisted record, while product details come from cited company documents.
7. **Negative tests:** Customer B must never see Customer A's memory **or read/resume Customer A's chat session**; anonymous customers have no persistent profile unless explicitly opted in; revoked consent/deletion removes retrievable memory; an unavailable database gives a clear failure without fabricated recall.

| Acceptance check | Target for the next PoC | Current result |
|---|---|---|
| Approved product FAQ | Correct, grounded answers with document citations | ⬜ Not run |
| Long-term recall after restart / new chat | Customer A's consented preference is recalled | ⬜ Not run |
| Multi-tenant isolation | Customer B cannot read Customer A's rows, embeddings or chat sessions | ⬜ Not run |
| Delete / opt-out | Deleted memory cannot be returned | ⬜ Not run |
| Fail closed | Missing authentication, disallowed tools and backend errors do not leak data | ⬜ Not run |

### 🔐 Security requirements before a production rollout

- Enforce customer and tenant authorization in the **backend/MCP service**, not merely in an LLM prompt. Consider PostgreSQL row-level security (RLS), least-privilege database roles and explicit ownership checks.
- Never give website visitors the agent API key: it can read every session and turn approvals off. Put an authenticating gateway in front that enforces per-customer session ownership.
- Keep website visitors away from privileged SRE/Kubernetes credentials; prefer separate processes, tool allowlists, network policies, and runtime identities.
- Require explicit consent and configurable retention/deletion for personal memories; redact secrets and sensitive records from embeddings, logs and prompts.
- Limit business mutations (refunds, orders, account edits, deployments) to reviewed workflows with audit logs and human approval.
- Add evaluation tests for grounded answers, prompt injection, cross-customer leakage, restart recovery and unavailable dependencies before calling the PoC production-ready.

### 📚 Official references for these use cases

- **Docker Agent framework and teams:** [Docker documentation](https://docs.docker.com/ai/docker-agent/) · [upstream GitHub](https://github.com/docker/docker-agent)
- **Docker Agent MCP connections:** [MCP tool configuration](https://docs.docker.com/ai/docker-agent/tools/mcp/) · [Docker MCP Toolkit](https://docs.docker.com/ai/mcp-catalog-and-toolkit/toolkit/)
- **Docker Agent knowledge retrieval:** [official RAG tool](https://docs.docker.com/ai/docker-agent/tools/rag/)
- **Built-in long-term memory and sessions:** [Docker Agent memory tool](https://docker.github.io/docker-agent/tools/memory/) · [sessions](https://docs.docker.com/ai/docker-agent/features/sessions/)
- **Custom memory integration:** [official MCP architecture](https://modelcontextprotocol.io/docs/learn/architecture) · [MCP Python SDK: build a server](https://py.sdk.modelcontextprotocol.io/get-started/first-steps/)
- **Durable PostgreSQL and vector search:** [PostgreSQL](https://www.postgresql.org/docs/) · [pgvector (official repository)](https://github.com/pgvector/pgvector) · [PostgreSQL row-level security](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)

**Recommended sequence:** reuse the existing Docker Agent PoC for agent orchestration → implement one private customer-FAQ agent → add authenticated PostgreSQL memory via MCP → add pgvector only if semantic retrieval improves the evaluation → expand to sales and support with separate policies.

[← OpenDevOps home](../README.md)
