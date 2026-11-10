# 🆓 OpenCode Bridge → Hermes Desktop

Run the **OpenCode Bridge** natively on your machine — no Docker. It exposes an **OpenAI-compatible** HTTP endpoint backed by your already-authenticated **OpenCode** CLI, so the **Hermes desktop app** (or any OpenAI SDK/tool) can drive OpenCode's **free** models — DeepSeek V4.1 Flash, MiMo, GLM, Nemotron, MiniMax, LongCat, Big Pickle — as a **Custom endpoint**. 🚀

> ✅ **Verified end-to-end** on Ubuntu 26.04 with **Hermes Agent v0.23.1** + **opencode v2.2.6**: `hermes -z "Reply with exactly: end-to-end ok"` → `end-to-end ok`.

It's the same wire protocol as the [Claude Code bridge](../../mac) on a different port, so both can run side by side and you can flip between them in Hermes' model picker.

---

## 📦 What's in this folder

| File | Purpose |
|------|---------|
| `install-opencode-bridge.sh` | 🧰 One-shot bootstrap: OpenCode CLI + registers the bridge as a user service |
| `run-bridge.sh` | ▶️ Launcher + service manager (foreground, install/uninstall the service, test, logs) |
| `opencode_bridge.py` | 🌉 The stdlib-only Python bridge (OpenAI-compatible → `opencode run`) |

---

## ✅ Prerequisites

- 🐍 `python3` (macOS ships it with the Xcode CLT; any distro python3 works)
- 🧑‍💻 The [OpenCode](https://opencode.ai) CLI, logged in far enough to list models:
  ```bash
  opencode models | grep -E -- '-free$|:free$'   # the free tier, one id per line
  ```
  > ⚠️ On **opencode v2** the `models` command takes **no provider argument** and has **no `--verbose`** — `opencode models opencode` prints the help text instead of a catalogue. The bridge handles both CLIs (see 🧬 below).
- 🖥️ Hermes desktop (the app whose Settings → Model page has **Custom endpoint**)
  - Linux/Ubuntu: install it with [`../../ubuntu-desktop`](../../ubuntu-desktop) — launcher, icons, Electron sandbox setuid fix, and the app-id desktop entry that keeps the dock icon correct 🐧

> 🛡️ **No `sudo`.** Everything installs per-user and the service runs as **you**, so it inherits your OpenCode credentials (`~/.local/share/opencode/auth.json`).

### 🧭 Tested against

| Component | Version | Notes |
|---|---|---|
| 🧠 Hermes Agent | `v0.23.1` | Desktop app built by `install.sh --include-desktop` |
| ⚙️ OpenCode CLI | `v2.2.6` | Zen free tier: 11 live `opencode/*-free` models |
| ⚙️ OpenCode CLI | `v1.19.5` | Also verified — remote Ubuntu 24.04 VM, 12 free models (see below) |
| 🐧 Host | Ubuntu 26.04 (x86_64) | X11 and Wayland (GNOME) both verified |
| ☁️ Host | Ubuntu 24.04.5 (GCE `e2-medium`) | Headless VM, systemd unit, loopback + SSH tunnel |

> ☁️ **Remote/headless deployments work too.** The same file runs as a systemd service on a
> Google Compute Engine VM (`bridge` user, `127.0.0.1:18383`, reached through
> `gcloud compute ssh -- -N -L`). Verified there: model listing, completions, bearer-auth
> rejection (`401`), and **real filesystem access** — the model listed the working
> directory, read the fixture files, ran `ps`, and wrote a new file that was confirmed
> on the VM.

---

## 🧬 opencode v2 compatibility

opencode **v2.2.6** dropped three things the bridge relied on. All three are now handled automatically — nothing to configure. 🪄

| What changed upstream | Symptom without the fix | What the bridge does now |
|---|---|---|
| 🚫 `opencode run --dir` removed | `502` — `Unrecognized flag: --dir in command opencode run` | Probes `opencode run --help` once at startup and only passes `--dir` when the CLI lists it (the child already runs in `--cwd`) |
| 🔠 `--log-level` is case-sensitive **and its enum flipped** (1.x wanted `ERROR`, v2 wants `error`) | `502` — `Invalid value for flag --log-level: "ERROR"` (or `"error"` on 1.x) | 🧪 Probes `opencode run --help` and mirrors whichever case the CLI advertises (`ERROR` on 1.x, `error` on v2) |
| 📉 `models --verbose` (and `models <provider>`) removed | Catalogue falls back to a stale seed list, then `400 model … is not available` | Falls back to plain `opencode models` and infers the free tier from the id (`…-free`, `…:free`) |

> 🧠 **Why the id heuristic is safe:** with `--verbose` gone there is no cost metadata to filter on, so the free guard keys off opencode's own naming. Anything that does not end in `-free`/`:free` is still refused, so a typo cannot quietly start billing a paid provider. 💸

> 🔁 `./run-bridge.sh selfcheck` runs these code paths offline (fake CLIs, no network) — it is the fastest way to confirm a future opencode release did not break the bridge again.

---

## ⚡ Quick Start

```bash
cd opencode/hermes-desktop
./install-opencode-bridge.sh
```

The bridge is now listening at **`http://127.0.0.1:18383/v1`** and restarts automatically at every login. 🎉

Prefer not to install a service? Just run it in the foreground:

```bash
./run-bridge.sh                       # Ctrl+C to stop
OPENCODE_BRIDGE_CWD=~/code ./run-bridge.sh   # point OpenCode's tools at a project
```

---

## 🖥️ Hermes Desktop on Ubuntu (the host app)

The bridge is only half the story — the app needs a proper launcher, icon, and Electron
sandbox. That lives in [`../../ubuntu-desktop`](../../ubuntu-desktop): 🐧

```bash
cd ubuntu-desktop && ./install.sh     # idempotent — safe to re-run after a Hermes update
```

It writes `~/.local/share/applications/com.nousresearch.hermes.desktop` (basename = the
Electron app id, which is what makes the **dock show the Hermes icon instead of a gear** 🎯),
installs icons at 32→512 px, and sets `chrome-sandbox` to `root:root 4755` so the app runs
**with** the sandbox rather than `--no-sandbox` 🔐.

Launch it from the Applications grid, or:

```bash
gtk-launch com.nousresearch.hermes
```

---

## 📁 Local files versus a VM bridge

OpenCode's tools run on the machine hosting the bridge. A local bridge can read local project folders and
screenshots; a bridge on a VM sees the VM's filesystem. An SSH tunnel forwards API requests, not local files.
Setting Hermes's `terminal.backend` to `local` does not relocate the OpenCode agent's tools.

For desktop file access, start the bridge on the same computer as Hermes:

```bash
OPENCODE_BRIDGE_CWD="$HOME" ./run-bridge.sh install-service
./run-bridge.sh models
```

Select that local endpoint in Hermes, using the port configured for the local service (default
`http://127.0.0.1:18383/v1`). Keep a VM bridge as a separate custom endpoint for work on the VM.
After changing endpoints, start a new chat or reselect the provider in the existing chat: a conversation can
retain its previous endpoint override and remote working-directory context.

Verify with an actual file read, not only `/health` or `/v1/models`: create a temporary local text file with
unique contents and ask Hermes to read its absolute path without including those contents in the prompt.
Confirm the returned contents and remove the test file afterwards. Listing a local screenshot folder should
likewise return the filenames actually present on the desktop computer.

## 🔌 Test it directly

```bash
./run-bridge.sh test      # /health + a live completion
./run-bridge.sh stream    # a streaming (SSE) completion
./run-bridge.sh models    # what the endpoint advertises, with free/paid labels
```

Raw curl:

```bash
curl -s http://127.0.0.1:18383/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"opencode/deepseek-v4.1-flash-free","messages":[{"role":"user","content":"Say hello from OpenCode"}]}'
```

Python (OpenAI SDK):

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:18383/v1", api_key="not-needed")
print(client.chat.completions.create(
    model="opencode/deepseek-v4.1-flash-free",
    messages=[{"role": "user", "content": "Say hello from OpenCode"}],
).choices[0].message.content)
```

---

## 🖥️ Connect Hermes (Custom endpoint)

Use **Settings → Providers → Custom Endpoints → `+ New endpoint`** — *not* the Settings → Model page, and **don't edit an existing endpoint** that points at another bridge (see the gotchas below).

| Field | Value |
|-------|-------|
| Name | `opencode` (anything) |
| Provider ID | `opencode` — or `opencode-bridge`; see ⚠️ below |
| Endpoint URL | `http://127.0.0.1:18383/v1` |
| Default Model | `opencode/deepseek-v4.1-flash-free` |
| API Key | *(leave blank — unless you set `OPENCODE_BRIDGE_API_KEY`)* |
| Context | `Auto` |
| ☑️ Use for new chats | on |
| ☑️ Discover models | on |

Then — **in this order** — click **⚡ Test**, *then* **💾 Save**. Reopen a new chat and the composer's model picker shows every free model.

### ⚠️ Three gotchas that cost us a debugging round

1. **`Test` before `Save`, always.** `Save` persists the catalogue that `Test` discovered. Save without testing and Hermes writes only the one model you typed — every picker then shows a **single-entry dropdown**, which looks exactly like a stale cache but isn't. Nothing to clear: just Test → Save again.
2. **Watch the port.** The Claude Code bridge in this repo runs on `:18181`/`:18182`; this one is `:18383`. Editing the Claude endpoint's URL and expecting OpenCode models in its dropdown won't work — its saved catalogue still belongs to the old endpoint until you Test again. Create a **separate** endpoint instead, so you can flip between them with **Use**.
3. **Deleting an endpoint un-configures Hermes.** Hermes clears `model.provider` / `base_url` / `key_env` when the active endpoint is deleted, leaving `model.default` dangling and no provider at all. If chats break right after a delete, that's why — Save + **Use** an endpoint to re-point it.

> ℹ️ **Provider ID `opencode` is safe**, even though Hermes ships a built-in OpenCode Zen provider. `opencode` is only an *alias* of the canonical `opencode-zen`, and Hermes' resolver deliberately lets a user-declared `providers.<name>` entry win over an alias — so requests go to `127.0.0.1:18383`, not the cloud. Verify any ID you pick:
> ```bash
> ~/.hermes/hermes-agent/venv/bin/python -c "from hermes_cli import runtime_provider as r; print(r._get_named_custom_provider('opencode'))"
> # -> dict with base_url http://127.0.0.1:18383/v1  ✅   (None = it fell through to a built-in)
> ```
> Only a *canonical* built-in name (e.g. `openrouter`, `nous`) gets shadowed. `opencode-bridge` is unambiguous if you'd rather not think about it.

### 🖱️ Or wire it from the CLI (no UI clicking)

The verified path on a fresh Hermes install — copy/paste, ~10 seconds:

```bash
cp ~/.hermes/config.yaml ~/.hermes/config.yaml.bak-$(date +%Y%m%d-%H%M%S)   # 🛟 safety net
hermes config set model.provider opencode
hermes config set model.base_url http://127.0.0.1:18383/v1
hermes config set model.default opencode/deepseek-v4.1-flash-free
hermes config set providers.opencode.name "OpenCode (free)"
hermes config set providers.opencode.base_url http://127.0.0.1:18383/v1
hermes config set providers.opencode.model opencode/deepseek-v4.1-flash-free
hermes config set providers.opencode.discover_models true
```

> 💡 Setting `model.provider` first makes Hermes **clear** the inherited `model.base_url` (`https://openrouter.ai/api/v1`) — that is expected; set `base_url` right after, as above.

Then prove the whole chain works:

```bash
hermes -z "Reply with exactly: end-to-end ok"      # -> end-to-end ok 🎉
```

Reopen the desktop app (or start a new chat) so the composer's model picker reloads the catalogue. 🖥️

### Or configure it by file

Saving through the UI produces this in `~/.hermes/config.yaml` (back it up first) — write it by hand if you prefer:

```yaml
model:
  default: opencode/deepseek-v4.1-flash-free
  provider: opencode                        # must match the providers key below
  base_url: http://127.0.0.1:18383/v1
providers:
  opencode:
    name: OpenCode (free)
    base_url: http://127.0.0.1:18383/v1
    model: opencode/deepseek-v4.1-flash-free
    discover_models: true
    models:                                 # this map is what fills the picker
      opencode/deepseek-v4.1-flash-free: {context_length: 200000}
      opencode/mimo-v2.6-flash-free: {context_length: 200000}
      opencode/glm-5.3-flash-free: {context_length: 200000}
      opencode/nemotron-3.5-lightning-free: {context_length: 200000}
      opencode/nemotron-3.5-super-vl-free: {context_length: 200000}
      opencode/minimax-m3.1-flash-free: {context_length: 200000}
      opencode/longcat-2.5-free: {context_length: 200000}
      opencode/big-pickle: {context_length: 200000}
```

The bridge needs no credentials. If you *do* set `OPENCODE_BRIDGE_API_KEY`, add `key_env: OPENAI_API_KEY` to both blocks and put the value in `~/.hermes/.env`:

```bash
echo 'OPENAI_API_KEY=your-bridge-key' >> ~/.hermes/.env
hermes gateway restart && hermes gateway status
```

Verify the whole path Hermes → bridge → `opencode`:

```bash
curl -s http://127.0.0.1:18383/v1/models | python3 -c "import sys,json;print([m['id'] for m in json.load(sys.stdin)['data']])"
hermes -z "Reply with exactly: end-to-end ok"     # -> end-to-end ok
tail -f ~/.opencode-bridge.log                    # watch Hermes hit the bridge live
```

> 💡 **Auxiliary models.** Hermes' Vision / Web-extract / Compression / Skills-hub helper tasks default to "use main model". The free models here are text-only (no image input), so if you use Hermes' vision features, point **Vision** at a model that supports attachments (Settings → Model → Auxiliary models → Vision → *Change*).

---

## 🧠 How it works

```
Hermes ──HTTP(OpenAI chat-completions)──▶ opencode_bridge.py ──▶ `opencode run --format json` ──▶ opencode zen (free)
```

* Each request spawns one `opencode run`, with the **prompt on stdin** (never argv, so big prompts can't hit `ARG_MAX`).
* `system` messages are hoisted into a `<system-instructions>` block at the top of the prompt — `opencode run` has no `--append-system-prompt`.
* OpenCode's JSON events become SSE deltas. Text parts are de-duplicated by part id, so a re-emitted (growing) part only sends its new suffix.
* `usage` is real: per-step `tokens` and `cost` from every `step_finish` event are summed across the whole agentic run (`input + cache.read + cache.write` → `prompt_tokens`, `output + reasoning` → `completion_tokens`).
* **Free-only by default.** The catalogue is discovered from `opencode models --verbose` and filtered to `cost.input == cost.output == 0`, so a typo in the model box can't quietly start billing a paid provider. It returns a `400` listing what *is* available.
* Tools run with the CLI's auto-approve flag (`--dangerously-skip-permissions`, probed at startup so older CLIs' `--auto` still works; permissions never block a headless run) inside `--cwd`. Each run's persisted session is deleted afterwards, so `opencode session list` doesn't grow without bound.

---

## 🛠️ Managing the Service

```bash
./run-bridge.sh test              # 🩺 health check + a live completion
./run-bridge.sh selfcheck         # 🔬 offline logic checks (no opencode needed)
./run-bridge.sh service-status    # 📊 service state
./run-bridge.sh logs              # 📜 tail the service log (~/.opencode-bridge.log)
./run-bridge.sh uninstall-service # 🧹 remove the service
./run-bridge.sh                   # ▶️ run in the foreground (Ctrl+C to stop)
```

macOS uses a per-user **launchd LaunchAgent** (`com.hermes.opencode-bridge` in `~/Library/LaunchAgents`); Linux uses **systemd `--user`** with lingering. Both have `RunAtLoad`/`Restart=always`, so the bridge starts at login and restarts on crash.

After editing `opencode_bridge.py`, the service reloads the new code by restarting — on Linux:

```bash
kill $(pgrep -f opencode_bridge.py)          # systemd restarts it (Restart=always) 🔁
curl -s http://127.0.0.1:18383/health | head -c 120
```

> 🧷 `systemctl --user ...` only works from a shell that has the session bus:
> `export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus`.
> Over SSH/xrdp the bus socket can differ (`/tmp/dbus-*`) — the restart-by-`kill` above sidesteps it.

---

## ⚙️ Configuration

Set these in the environment or in a `.env` next to `run-bridge.sh` (they're baked into the service at install — re-run `install-service` after changing them):

| Variable | Default | Description |
|----------|---------|-------------|
| `BRIDGE_HOST` | `127.0.0.1` | Bind address (keep it loopback) |
| `BRIDGE_PORT` | `18383` | Listen port (the Claude bridge uses `18181`) |
| `OPENCODE_BRIDGE_MODEL` | `opencode/deepseek-v4.1-flash-free` | Default model |
| `OPENCODE_BRIDGE_MODELS` | *(auto-discovered)* | Comma-separated override for the advertised catalogue |
| `OPENCODE_BRIDGE_CWD` | `$HOME` | Working directory OpenCode's tools operate in |
| `OPENCODE_BRIDGE_FREE_ONLY` | `1` | `0` also allows paid models your OpenCode credentials can reach |
| `OPENCODE_BRIDGE_API_KEY` | *(empty)* | If set, clients must send `Authorization: Bearer <key>` |
| `OPENCODE_BRIDGE_MAX_CONCURRENCY` | `2` | Concurrent `opencode` subprocesses (free tiers rate-limit) |
| `OPENCODE_BRIDGE_TIMEOUT` | `300` | Per-request timeout in seconds |
| `OPENCODE_BRIDGE_AGENT` | *(opencode default)* | OpenCode agent to run (`build`, `plan`, a custom one) |
| `OPENCODE_BRIDGE_VARIANT` | *(default)* | Reasoning variant (`minimal`, `high`, `max`) |
| `OPENCODE_BRIDGE_SHOW_TOOLS` | `0` | `1` inlines `› read(file)` progress notes in the reply |
| `OPENCODE_BRIDGE_SHOW_REASONING` | `0` | `1` passes `--thinking` and inlines reasoning blocks |
| `OPENCODE_BRIDGE_MAX_IMAGES` | `4` | Max `image_url` attachments per request (`0` disables image support) |
| `OPENCODE_BRIDGE_MAX_IMAGE_BYTES` | `33554432` | Per-image size limit in bytes (32 MiB — fits Retina screenshots) |
| `OPENCODE_BIN` | *(auto)* | Explicit path to the `opencode` binary |

```bash
# Example: require an API key, use a project dir, and show the tool trace
OPENCODE_BRIDGE_API_KEY="choose-a-strong-secret" \
OPENCODE_BRIDGE_CWD="$HOME/code/myapp" \
OPENCODE_BRIDGE_SHOW_TOOLS=1 ./install-opencode-bridge.sh
```

Every flag has a CLI equivalent — `python3 opencode_bridge.py --help`.

### Endpoints

| Endpoint | Purpose |
|----------|---------|
| `POST /v1/chat/completions` | Blocking + `"stream": true` (SSE) |
| `GET /v1/models`, `/v1/models/{id}` | Advertised catalogue (with `free` / `context_length`) |
| `GET /health` | Liveness + OpenCode version + in-flight count |
| `GET /config` | Effective configuration |
| `GET /metrics` | Requests, errors, 429s, cost, output tokens, uptime |

---

## 🧯 Troubleshooting

| Symptom | Fix |
|---------|-----|
| `opencode not found` | Install from [opencode.ai](https://opencode.ai), open a new shell, or set `OPENCODE_BIN` |
| `400 model '…' is not available on this bridge` | Use an id from `./run-bridge.sh models` (bare ids like `deepseek-v4.1-flash-free` also work), or allow paid models with `OPENCODE_BRIDGE_FREE_ONLY=0` |
| `502 Unrecognized flag: --dir` / `Invalid value for flag --log-level` | Older bridge against opencode v2 — update this folder; the CLI probes handle it (see 🧬 compatibility) |
| `502 Model unavailable: opencode/…` | The model id was retired by opencode zen. Pick a live one from `./run-bridge.sh models`; the bridge refreshes its catalogue hourly |
| `/v1/models` shows old, dead ids | Stale catalogue cache. Restart the bridge (`kill $(pgrep -f opencode_bridge.py)` — systemd restarts it) or set `OPENCODE_BRIDGE_MODEL` to a live id |
| Model list is the built-in fallback (`/config` → `models_source: fallback`) | `opencode models opencode` failed — check network/credentials, then restart the bridge |
| `429 bridge busy` | More concurrent chats than `OPENCODE_BRIDGE_MAX_CONCURRENCY` — raise it (free tiers rate-limit, so go gently) |
| `429` with a rate-limit message from upstream | The free tier is throttling; retry shortly or switch model |
| `504 opencode command timed out` | Long agentic run — raise `OPENCODE_BRIDGE_TIMEOUT` |
| `401` from the endpoint | You set `OPENCODE_BRIDGE_API_KEY` — send it as `Authorization: Bearer <key>` |
| Hermes' model dropdown shows **one** model (e.g. only `claude-opus-4-8`) | Not a cache. Either you're editing an endpoint whose saved catalogue came from a different bridge, or you saved without clicking **Test**. Fix: correct the URL → **Test** → **Save** |
| Hermes lists the endpoint but chats fail with `auth_unavailable` / a cloud provider error | The Provider ID collided with a *canonical* built-in — rename it (`opencode-bridge`) and re-Save; verify with the `_get_named_custom_provider` snippet above |
| Chats broke right after deleting an endpoint | Hermes cleared `model.provider`/`base_url` — Save + **Use** an endpoint again (`~/.hermes/config.yaml` keeps `.bak` copies) |
| `/v1/models` works in the browser but Hermes sees nothing | Hermes probes `<base_url>/models` — the Endpoint URL must end in `/v1` (no trailing slash) |
| Hermes shows `Unknown provider 'openai'` | Use a **Custom endpoint** entry, not `openai`/`auto` — those can't infer a localhost URL |
| `Address already in use` | Something owns the port: `BRIDGE_PORT=18283 ./install-opencode-bridge.sh`, then update the Base URL in Hermes |
| A local path is reported missing, or `pwd` shows a VM workspace | Select a bridge running on the desktop computer. A tunnel to a VM still runs OpenCode's tools on the VM. Start a new chat or reselect the provider to clear an old endpoint override; see [local files versus a VM bridge](#-local-files-versus-a-vm-bridge) |
| Vision/image requests fail | The free models are text-only — set Hermes' **Vision** auxiliary model to an image-capable one |
| Sessions piling up in `opencode session list` | You ran with `--keep-sessions`; drop it (cleanup is on by default) |

---

> 🤖 Want Claude Code instead of OpenCode behind the same kind of endpoint? See [`../../mac`](../../mac) (🪟 Windows: [`../../windows`](../../windows), 🐧 Linux: [`../../ubuntu-desktop`](../../ubuntu-desktop), 🐳 containers: [`../../docker`](../../docker)).
