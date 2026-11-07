# ⚙️ systemd user unit: restore the host forwards after a reboot

`openshell forward` processes run on the host, so a reboot drops them. Everything else comes back by itself (Docker restart policies, the OpenShell gateway restarts the sandbox, `hermes-tunnel` reconnects). The public site goes through `hermes-tunnel`, not these forwards; they serve `127.0.0.1:9119` (dashboard) and `127.0.0.1:8642` (API) on the server.

| File | What it does |
|---|---|
| [`hermes-forwards.service`](hermes-forwards.service) | Oneshot user unit; at boot runs [`../scripts/forwards.sh`](../scripts/forwards.sh), which waits for the sandbox to be `Ready`, then (re)starts each forward whose port does not answer, retrying until it does (up to `WAIT_SECONDS`, default 300). Idempotent. |

## ▶️ Install (once, on the server, as the user that runs OpenShell)

```bash
sudo loginctl enable-linger "$USER"     # user units start at boot without a login
install -D -m 0644 ~/OpenDevOps/sandbox/systemd/hermes-forwards.service ~/.config/systemd/user/hermes-forwards.service
systemctl --user daemon-reload
systemctl --user enable --now hermes-forwards.service
```

## ✅ Verify

```bash
systemctl --user status hermes-forwards --no-pager   # active (exited), "answers HTTP" lines
openshell forward list                                # 8642 and 9119 running
curl -s http://127.0.0.1:8642/health                  # {"status": "ok", ...}
```

After a reboot, `journalctl --user -u hermes-forwards -b` shows the run. **Status (2026-11-07):** reboot-tested on the reference server: the unit started at boot, waited for the sandbox, retried while the supervisor reconnected (the gateway reports `Ready` before forwards work), and had both forwards answering about 2.5 minutes after boot (`Result=success`). Also tested by hand: forwards already up (left alone), one or both missing (restored).

⚠️ The unit runs **once**: it stays `active (exited)` even if a forward dies later (for example when the sandbox is re-created). Then run it again with `systemctl --user restart hermes-forwards` or `sandbox/scripts/forwards.sh`.

## 🧹 Remove

```bash
systemctl --user disable --now hermes-forwards.service
rm ~/.config/systemd/user/hermes-forwards.service && systemctl --user daemon-reload
```
