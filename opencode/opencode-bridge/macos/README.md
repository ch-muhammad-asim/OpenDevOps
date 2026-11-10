# macOS — OpenCode bridge for Hermes (launchd)

[← Main bridge guide](../README.md) · [Existing script implementation](../../hermes-desktop/README.md)

The implementation already in the repository is reused without copying it. The wrapper `install.sh` chooses **all discoverable models with zero advertised input/output cost**, rather than pinning an explicit model allowlist. Hermes is the intended default API client.

```bash
git clone https://github.com/ch-muhammad-asim/OpenDevOps.git
cd OpenDevOps/opencode/opencode-bridge/macos
bash install.sh
bash ../../hermes-desktop/run-bridge.sh selfcheck
bash ../../hermes-desktop/run-bridge.sh models
bash ../../hermes-desktop/run-bridge.sh test
```

**Hermes settings:** Settings → Providers → Custom Endpoints → New endpoint; provider ID `opencode-bridge`; URL `http://127.0.0.1:18383/v1`; enable discovery; **Test → Save → Use**. Select one *actual* returned free model as Hermes's initial model. The bridge automatically advertises all free models it discovers; it does not force one model for every chat.

The original installer registers a **launchd LaunchAgent**. Management commands, logs and uninstall: [`run-bridge.sh`](../../hermes-desktop/run-bridge.sh). Its bridge defaults to automatic tool approvals; use a restricted workspace and consider the safe manual Python execution in the [central guide](../README.md) for untrusted prompts. On localhost the original installer can run without a bridge API key; configure `OPENCODE_BRIDGE_API_KEY` before using any remote access.
