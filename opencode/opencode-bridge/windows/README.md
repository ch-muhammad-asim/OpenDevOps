# 🪟 Windows — OpenCode bridge via WSL2 (Linux compatibility path; not yet tested)

[← Main bridge guide](../README.md)

**Status:** This repo's root [`windows/`](../../../windows/README.md) PowerShell installer is for the **Claude Code** bridge; it must **not** be presented as an OpenCode bridge installer. There is no verified **native Windows** OpenCode service script here.

A practical **candidate** workflow is Windows 11 → WSL2 Ubuntu → existing **Linux OpenCode bridge**:

1. Set up WSL2 with Ubuntu using Microsoft's supported instructions and reboot if required.
2. From the **Ubuntu/WSL terminal**, install `git`, `python3` and dependencies; clone this repo.
3. Run `cd OpenDevOps/opencode/opencode-bridge/linux && bash install.sh` **from WSL Ubuntu**, not PowerShell.
4. Test `bash ../../hermes-desktop/run-bridge.sh models` and `bash ../../hermes-desktop/run-bridge.sh test`.
5. If a Windows-native Hermes client is used, try `http://127.0.0.1:18383/v1` **only after verifying that Windows can reach the WSL2 loopback listener**. WSL networking modes differ; do not assume reachability.

**Hermes:** Custom endpoint provider ID `opencode-bridge`; click Test → Save → Use; choose an actually returned free model. The bridge dynamically discovers all zero-cost catalog entries. **This WSL2 combination and Windows→WSL networking have not been tested in this session.** No native PowerShell/OpenCode support claim is made.

Security: bind loopback, use a key for any network exposure, and restrict model tool execution / WSL file mounts. Avoid exposing the WSL bridge on `0.0.0.0` for convenience.
