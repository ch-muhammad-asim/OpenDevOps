# Linux / Ubuntu — OpenCode bridge for Hermes (systemd user service)

[← Main bridge guide](../README.md) · [Existing Linux-capable installer](../../hermes-desktop/install-opencode-bridge.sh)

This entry point reuses the repository's existing Linux-compatible Bash installer and `systemd --user` launcher; it does **not** copy or diverge from the tested Python bridge. Default client is **Hermes**. All model IDs dynamically returned by OpenCode Zen with **zero advertised input/output cost** are eligible for discovery; actual model inference may still fail from quotas.

```bash
git clone https://github.com/ch-muhammad-asim/OpenDevOps.git
cd OpenDevOps/opencode/opencode-bridge/linux
bash install.sh
bash ../../hermes-desktop/run-bridge.sh service-status
bash ../../hermes-desktop/run-bridge.sh models
bash ../../hermes-desktop/run-bridge.sh test
```

Hermes → Custom Endpoints: `http://127.0.0.1:18383/v1` (not the OpenCode Web port). Provider ID `opencode-bridge`; enable model discovery and **Test → Save → Use**. Choose an available free model for the initial conversation.

The original systemd user service may require user lingering for use after logout. Do not equate `--cwd` with a security sandbox; original runner defaults to auto-approving tools. For a least-privilege manual process with `--no-auto-approve`, follow [GCP VM](../gcp-vm/README.md) (same Python source works on Linux). Use an API key and SSH/private network path for remote clients.
