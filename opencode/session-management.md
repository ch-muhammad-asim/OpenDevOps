# 🧵 OpenCode sessions — find, join and move a specific session

**Verified:** OpenCode **v2.2.7** on Linux against the shared background service, 2026-11-11. Every command
below was checked with `opencode --help`, `opencode session --help`, `opencode mini --help` and the
[CLI commands reference](https://opencode.ai/docs/cli/commands).

OpenCode has **no `attach` or `join` subcommand**. Reattaching to a known session is the `--session` / `-s`
flag on the interface you want to use.

## 1. What identifies a session

- An ID looks like `ses_e37901d01ffexP70Q2hwj3rhu9` and is stable for the life of the session.
- Sessions are owned by the **background server**, not by the terminal client. Every local client that
  talks to that server sees the same sessions, so two terminals can be attached to one session at once.
- A session is associated with a **directory** (the project it was started in) and stores its own location.
  `session.new_location` in `cli.json` decides whether new sessions start in the TUI launch directory
  (`launch`, the default) or in the active session's directory (`inherit`).
- Deleting a session also deletes its child sessions.

## 2. Find the ID

| Where | How |
| --- | --- |
| CLI, current project | `opencode session list` (newest first) |
| CLI, bounded or scripted | `opencode session list --max-count 20 --format json` |
| TUI picker | `/sessions`, or **Ctrl+X** then **L** |
| TUI, recent sessions across projects | **Ctrl+O** |
| API | `opencode api GET /api/session` |
| Another herdr tab | `opencode session list` in that tab's directory |

## 3. Join by ID — pick the surface

| Intent | Command |
| --- | --- |
| Full-screen TUI on an existing session | `opencode --session ses_…` (or `-s ses_…`) |
| Same, in a specific project directory | `opencode ~/code/project -s ses_…` |
| Minimal interface on an existing session | `opencode mini --session ses_…` |
| Branch instead of appending (mini) | `opencode mini -s ses_… --fork` |
| One-shot prompt into an existing session | `opencode run --session ses_… "next prompt"` |
| Continue whatever ran last | `opencode --continue` / `opencode mini -c` / `opencode run -c` |
| Replay history limits on resume (mini) | `--replay` / `--no-replay` / `--replay-limit 200` |

`opencode run --session` and `opencode mini --session` are documented. The top-level TUI flag
`opencode --session` is **not** in the published docs — see section 8.

## 4. The `-s` footgun

`--session` means *"Session ID to continue, **or to create if it does not exist**"*. A typo, a truncated ID
or an ID from another server silently opens a brand-new empty session that looks like lost history.

Guard rails:

```bash
# confirm the ID exists before attaching
opencode session list --max-count 20 --format json | grep ses_4f2a1c

# if you created a stray session by accident, delete it
opencode session delete ses_…
```

Always paste the full ID; the server does not resolve prefixes or partial IDs.

## 5. Joining a session that is already live

- Default mode: all local clients share **one background server**, so `opencode -s ses_…` in a second
  terminal or a second herdr tab attaches to the live session. You see new messages as they arrive; both
  clients can prompt. That is the supported way to watch one session from two windows.
- `--standalone` starts a **private** server: the client will not see sessions created through the shared
  service, so `-s` there creates a new session. Use it for isolation, not for reattaching.
- `--server http://host:4096` targets an explicit server (local or remote over SSH/tunnel). The session ID
  must exist **on that server**; IDs are not portable between servers, only through export/import.
- Remote or browser clients pair with `opencode pair` (one-time links, 5-minute expiry). Pairing needs the
  shared service and is unavailable while it is disabled.

Check which server a client is talking to before blaming the ID:

```bash
opencode service status
opencode api get /api/info
```

## 6. Switching sessions without restarting the TUI

- `/sessions` (or **Ctrl+X** then **L**) returns to an existing session; **Ctrl+O** lists recent sessions
  and projects together; **Ctrl+X** then **N** starts a new one.
- There is no documented TUI command that accepts a raw session ID. To jump to a specific ID, start the
  client with `-s`, or pick it from the picker.
- With tabs enabled (**Ctrl+Shift+T** reopens the last closed tab), each tab holds a different session, which
  is usually nicer than reattaching one session in several terminals.
- Inside herdr, `tabs.mode: auto` hides OpenCode's own tab strip; use one herdr tab per client and `-s` to
  pin each one to its session.

## 7. Moving, exporting and importing sessions

Sessions are not locked to the machine that created them, but the move is explicit:

```bash
opencode session export ses_4f2a1c > session.json          # full transcript
opencode session export ses_4f2a1c --sanitize > safe.json  # redact transcript and file data
opencode session import session.json                       # import into the current directory
opencode session import session.json --directory ~/code/project
```

- Export before deleting if the transcript matters; `session delete` is not recoverable.
- Archived sessions (created with `opencode run --archived`) stay out of session lists and the inbox but
  still exist and can be opened by ID.

## 8. Documented vs undocumented

| Surface | Status |
| --- | --- |
| `opencode run --session ses_…` | documented — [CLI commands](https://opencode.ai/docs/cli/commands) |
| `opencode mini --session ses_…` | documented — [CLI commands](https://opencode.ai/docs/cli/commands) |
| `opencode --session` / `-s` (full TUI) | **only in `opencode --help`**; absent from [CLI intro](https://opencode.ai/docs/cli) and [TUI](https://opencode.ai/docs/cli/tui) |
| `mini --fork`, `--replay`, `--replay-limit` | only in `opencode mini --help` |
| `/sessions`, **Ctrl+X L**, **Ctrl+O**, **Ctrl+Shift+T** | documented — [TUI](https://opencode.ai/docs/cli/tui) |
| `session list / delete / export / import` | documented — [CLI commands](https://opencode.ai/docs/cli/commands) |

Verify on your own install before relying on this page for a different version:

```bash
opencode --version
opencode --help | grep -A1 -- '--session'
opencode mini --help | grep -A1 -- '--session'
```

## 9. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| An empty session appears instead of history | `-s` with an unknown or mistyped ID creates it | `opencode session list --max-count 5`, then `opencode session delete ses_…` |
| Session is missing from `session list` | Wrong directory, or it is archived | Run the command from the session's directory, or use **Ctrl+O** |
| Second client sees no sessions | It uses a private server (`--standalone`) or a different `--server` | `opencode service status`; drop `--standalone` |
| Two terminals fight over one session | Both are attached to the same live session (expected) | Use one tab per session, or `mini --fork` to branch |
| `opencode api get /api/info` fails | Background service down or unreachable | `opencode service restart`, then re-check |
