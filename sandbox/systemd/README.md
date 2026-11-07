# ⚙️ systemd user units: keep the host forwards up

`openshell forward` processes run on the host, so they drop when the server reboots and when OpenShell restarts the sandbox (crash, kill-guard recovery, gateway restart). Everything else comes back by itself (Docker restart policies, the OpenShell gateway restarts the sandbox, `hermes-tunnel` reconnects). The public site goes through `hermes-tunnel`, not these forwards; they serve `127.0.0.1:9119` (dashboard) and `127.0.0.1:8642` (API) on the server.

> **Status (2026-11-07):** live on the reference server (Ubuntu 22.04, systemd 249). Tested: a killed `:9119` forward answered again after 44 s and 21 s, the other forward was left alone, and runs with nothing to fix log nothing. The boot path (timer `OnActiveSec`) is not yet reboot-tested; the earlier boot-only unit was (both forwards back about 2.5 minutes after boot).

| File | What it does |
|---|---|
| [`hermes-forwards.timer`](hermes-forwards.timer) | Starts the service 30 s after boot (or after it is enabled), then 60 s after each run ends. A run that is still waiting for the sandbox is never started twice. |
| [`hermes-forwards.service`](hermes-forwards.service) | Oneshot unit that runs [`../scripts/forwards.sh`](../scripts/forwards.sh): wait for the sandbox to be `Ready`, then (re)start each forward whose port doesn't answer, retrying until it does (up to `WAIT_SECONDS`, default 300). `FORWARDS_QUIET=1` logs only restarts and failures; `FORWARDS_SCOPE=1` starts each forward in its own `hermes-forward-<port>-<time>.scope`, so it outlives the run. |

## ▶️ Install (once, on the server, as the user that runs OpenShell)

```bash
sudo loginctl enable-linger "$USER"     # user units start at boot without a login
for u in service timer; do
  install -D -m 0644 ~/OpenDevOps/sandbox/systemd/hermes-forwards.$u ~/.config/systemd/user/hermes-forwards.$u
done
systemctl --user daemon-reload
systemctl --user enable --now hermes-forwards.timer
```

Upgrading from the boot-only unit (it had `RemainAfterExit=yes` and `WantedBy=default.target`): run `systemctl --user disable hermes-forwards.service` before the install and `systemctl --user stop hermes-forwards.service` after it. Until the old `active (exited)` state is cleared, the timer's start does nothing. Stopping it keeps the running forwards (`KillMode=process`).

## ✅ Verify

```bash
systemctl --user list-timers hermes-forwards.timer   # NEXT within a minute
openshell forward list                                # 8642 and 9119 running
curl -s http://127.0.0.1:8642/health                  # {"status": "ok", ...}
journalctl --user -u hermes-forwards --since -10min   # only Starting/Finished lines unless a forward was restarted
```

Test the recovery (local forwards only; the public site isn't affected):

```bash
kill "$(openshell forward list | awk '$4==9119{print $5}')"
until curl -s -o /dev/null -m 3 http://127.0.0.1:9119/; do sleep 2; done; echo back   # within ~1-2 minutes
```

Each restart is logged as `forward 127.0.0.1:<port> -> hermes started, answers HTTP <code>`. After a reboot, `journalctl --user -u hermes-forwards -b` shows the first run.

## 🧹 Remove

```bash
systemctl --user disable --now hermes-forwards.timer
rm ~/.config/systemd/user/hermes-forwards.{service,timer} && systemctl --user daemon-reload
```

The forwards keep running until the next reboot; stop them with `openshell forward stop <port> hermes`.
