# ⚖️ Docker Agent: the complete comparison guide

> 🎓 Part of **OpenDevOps**, an educational and training repo for the DevOps/SRE community.
> 🧪 Every Docker Agent claim here was either **tested live** in this project (✅) or read from the **docker-agent v1.150.0 source** (📖, with file path).
> 🌐 Other frameworks are cited from their official docs and repos. Versions and stars are a **2026-10-17 snapshot** of the GitHub API and will drift, so re-check them before quoting.
> ❓ Anything not verified is marked **UNVERIFIED**.
> 🔙 Companion to the hands-on [runbook](./README.md).

---

## 📑 Contents

1. [🎯 What problem does this agent solve?](#-what-problem-does-this-agent-solve)
2. [🧠 Memory: the deep dive](#-memory-the-deep-dive)
3. [🪽 Docker Agent vs Hermes Agent](#-docker-agent-vs-hermes-agent)
4. [🦜 Docker Agent vs LangChain and other frameworks](#-docker-agent-vs-langchain-and-other-agent-frameworks)
5. [🧭 Which one should I choose?](#-which-one-should-i-choose)
6. [✅ Pros and ❌ cons of Docker Agent](#-pros-and--cons-of-docker-agent)
7. [🧰 Is building an agent with Docker simple?](#-is-building-an-agent-with-docker-simple)
8. [📚 Sources](#-sources)

---

## 🎯 What problem does this agent solve?

| | 💬 Chat agent | 🛠️ SRE agent |
|---|---|---|
| 📄 Config | `agent.yaml`, `agent-claude-code.yaml` | `agent-sre.yaml` |
| 🧩 Problem solved | A **governed, OpenAI-compatible SRE advisor endpoint**. One fixed instruction, bearer auth, a pinned image, and a swappable backend (local model, Claude Code, Codex) | **First-line Kubernetes triage**. It lists pods, reads events and logs, inspects resources, explains the root cause with evidence, and hands a human the exact fix |
| 🔧 Tools | `think` only, which reaches nothing outside the model | Read-only Kubernetes MCP tools + `memory` + `think` |
| 👀 Sees your systems? | ❌ No. It only reasons over what you paste (the model runs through the [Claude Code CLI bridge](./claude-code-cli-bridge/README.md) next to the agent) | ✅ Yes, read-only, through a RBAC-scoped ServiceAccount |
| ✍️ Can change anything? | ❌ No | ❌ Not the cluster (RBAC-enforced). ✍️ It writes only to its own memory file |
| 🧪 Proven | ✅ Correct CrashLoopBackOff advice | ✅ Diagnosed `ImagePullBackOff` (bad tag `nginx:faulty`) and `CrashLoopBackOff` (missing `DATABASE_URL`) on its own, in 37 s |

**Typical uses** 💡
- 🧑‍🚒 An "ask the cluster" API for the on-call engineer.
- 🤖 A triage step inside an incident bot or CI job.
- 🧪 A safe sandbox for comparing models (local, Claude, Codex) on the same task.
- 🎓 Training material showing how to give an AI agent **least-privilege** access.

---

## 🧠 Memory: the deep dive

**Short answer.** Docker Agent has **three independent kinds of memory, and upstream turns all of them off by default** (all three tested here). In this project, the chat endpoint (`agent.yaml`) stays stateless, and the **SRE agent (`agent-sre.yaml`) explicitly enables long-term memory**. Hermes has memory built in, and can learn new skills.

### 1️⃣ Conversation memory (short-term)

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

### 2️⃣ Long-term memory (the `memory` toolset)

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

### 3️⃣ Session history (`serve api`)

| | Detail |
|---|---|
| 🗄️ Storage | `docker agent serve api --session-db session.db` persists full sessions in SQLite, and they can be resumed |
| 🔍 Tooling | `docker agent sessions …` inspects them. `session_context` lets an agent reference a previous session |
| 🧪 Evidence | ✅ Created a session, ran the SRE agent, then a follow-up **without resending history** answered in 1 s. After a **container restart**, the session (6 messages, auto-title) was still there. See runbook section F |

### 4️⃣ Knowledge (RAG), which is not "memory" but often confused with it

The `rag` toolset searches **your documents**: hybrid BM25 plus embeddings, reranking, tree-sitter chunking 📖 `pkg/rag/`. Use it for runbooks and postmortems. It can't remember facts *during* a conversation.

### 🧠 Memory comparison: Docker Agent vs Hermes vs LangGraph

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

---

## 🪽 Docker Agent vs Hermes Agent

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

### 🤝 They work best together

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

---

## 🦜 Docker Agent vs LangChain and other agent frameworks

### 🗺️ The landscape at a glance

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

### 📊 Feature matrix

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

### 💪 Where Docker Agent is genuinely better (for a DevOps/SRE platform team)

1. 📄 **The agent is configuration, not code.** Model, tools, permissions, safety mode and budgets live in one YAML file, so a reviewer sees the whole behaviour change in a **PR diff**. MAF and PydanticAI offer YAML too, but as an option on top of code.
2. 🛡️ **Safety enforced by the runtime, not the prompt.** `restricted` denies destructive or unknown tool calls **without asking**, which is ideal for headless services. Other frameworks also offer approvals, guardrails or permission modes (LangGraph interrupts, OpenAI guardrails, Claude SDK permission modes). The difference here is that a fail-closed headless policy is **one declarative setting**. This does not cover harness mode, which bypasses it. Docker's own docs say `restricted` is fail-closed but **not a security boundary**, so pair it with RBAC as this repo does.
3. 🌐 **An OpenAI-compatible server is built in.** Any SDK, chat UI or gateway can call it immediately. Python SDKs leave you to write a FastAPI layer.
4. 📦 **One static Go binary.** No Python dependency tree, fast start, and this repo's image is **~220 MB** (measured with `docker image inspect`, `sha-fba9fc0`, arm64): distroless and non-root, and run with `--read-only`.
5. 🚚 **Agents ship like images.** `docker agent share push` stores agents as **OCI artifacts** (signable) in the registry you already run. To our knowledge, none of the other frameworks here document OCI-native agent distribution (UNVERIFIED).
6. 🔌 **Docker MCP catalog** and sandboxed MCP servers. Tools come as containers, too.
7. 🎛️ **Harness mode** drives Claude Code, Codex, opencode or pi as sub-agents behind one OpenAI-compatible API (✅ tested here with Claude Code).
8. 🤖 **CI-friendly.** `--exec --json` emits NDJSON events, OTel GenAI spans are built in, and `docker agent eval` runs evals in containers.

### 🐢 Where Docker Agent is weaker

1. 🔀 **Control flow.** There are no typed state graphs. You get sub-agents, handoffs and a keyword-based router. LangGraph, MAF, ADK 2.0 and Pydantic Graph give you explicit state machines with branches, loops and code nodes.
2. ⏯️ **Durable execution.** No native distributed checkpointing: sessions are a local SQLite file, with no Postgres/Redis checkpointers and no Temporal/DBOS. A session can be resumed only where that file lives (e.g. a PVC), which is not the same as durable workflow execution across pods.
3. 🧠 **Memory backends.** One keyword-searched SQLite store per config, against pluggable vector and semantic stores elsewhere.
4. 📊 **Eval and observability depth.** It's solid but not at **LangSmith's** level (datasets, online evals) or ADK's user simulation. OTLP export is HTTP only.
5. 🌱 **Ecosystem and maturity.** About **4.5k stars versus about 148k for LangChain**, a fast-moving schema (150 releases), and a smaller integration catalog. Custom logic means writing an **MCP server**, not a Python function.
6. ☸️ **Kubernetes packaging.** No upstream Helm chart or operator. This repo adds a tested **kustomize** deployment for local Kubernetes (OrbStack): RBAC, NetworkPolicies, a PVC and a digest-pinned image (runbook [section G](./README.md)). A Helm chart is still unfinished.
7. 📡 **Product telemetry is on by default.** Set `TELEMETRY_ENABLED=false` (done in this repo's images).

---

## 🧭 Which one should I choose?

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

---

## ✅ Pros and ❌ cons of Docker Agent

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

---

## 🧰 Is building an agent with Docker simple?

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

---

## 📚 Sources

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

[← 🐳 Docker Agent runbook](./README.md) · [🏠 OpenDevOps home](../README.md)
