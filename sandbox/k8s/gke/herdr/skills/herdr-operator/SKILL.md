---
name: herdr-operator
description: "Run and watch commands in herdr panes inside this OpenShell sandbox: split a pane, run, wait for output, read only what is needed, summarize."
version: 1.0.0
author: OpenDevOps
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [herdr, terminal, panes, DevOps]
prerequisites:
  commands: [herdr, jq]
---

# herdr-operator

You run in the Hermes dashboard, inside an NVIDIA OpenShell sandbox. A herdr server (terminal workspace manager) runs in
the same sandbox, and its panes have the same limits as your terminal tool: uid 10000, Landlock (write access only in
/sandbox and /tmp), seccomp, and network only through the sandbox policy. There is no separate workbench container.
Use herdr to keep long or noisy jobs in their own panes and to read back only what you need.

## Rules (always)

- Never bypass, disable or answer approval prompts; never use `--yolo` or ask for auto-approve. If a command needs
  approval, the human decides.
- Never touch secrets: do not print, search for, copy or send keys, tokens, passwords or env files.
- Only use the herdr commands below, on panes you created in this sandbox's herdr. Never stop the herdr server, never use
  `--machine`/`--remote`, never change herdr config or integrations, never send keys or prompts to an agent.
- Respect your turn and time budget: plan, run, read, summarize. Stop after 2 failed attempts at the same step and
  report what failed instead of retrying.
- Be concise: read with `--lines 40` (more only if needed), summarize results in a few lines, never paste whole logs.

## Commands

```bash
herdr pane list | jq -r '.result.panes[] | "\(.pane_id) \(.foreground_cwd)"'      # see your panes
P=$(herdr pane split --direction right --no-focus --cwd /work/workspace | jq -r '.result.pane.pane_id')
herdr pane run "$P" 'make test; echo EXIT_$?_$((20+22))'                         # text + Enter
herdr pane wait-output "$P" --regex 'EXIT_[0-9]+_42' --timeout 300000            # always with --timeout
herdr pane read "$P" --source recent-unwrapped --lines 40                        # only what you need
herdr pane rename "$P" tests                                                     # label long-running panes
```

- First call in a new session: `herdr pane list`. If the user asks for a new pane, always split one (command above); otherwise reuse an existing idle pane before creating a new one.
- Make the completion marker something the shell computes (`$((20+22))` prints `42`), so it never matches the
  typed command line itself.
- One job per pane for long-running work (builds, tests, servers); check on it with `pane read --lines 20`.
- Report: what you ran, the exit code, and a 3-5 line summary of the output.
