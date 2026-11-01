# 📚 `demo/use-cases/`: the eight demo use cases

Each file is one **use case** of the DevSecOps demo: what an agent (or an attacker driving it) tries, what OpenShell does about it, what to show on screen, and how it's verified. Together they cover what a security reviewer asks about an AI agent with tool access.

> 📘 Demo guide and running order: [`../README.md`](../README.md) · verification scripts: [`../scripts/`](../scripts/README.md)

## 📋 Use cases

| # | Use case | What it proves | Verified by |
|---|---|---|---|
| 01 | [Allowed chat through the approved model endpoints](01-allowed-chat.md) | The agent works normally: it answers through the approved model endpoints only (NVIDIA API, OpenCode bridge) | [`verify-01.sh`](../scripts/verify-01.sh) |
| 02 | [Working with files in the workspace](02-workspace-files.md) | Normal file work in `/sandbox` succeeds | [`verify-02.sh`](../scripts/verify-02.sh) |
| 03 | [Network egress is denied by default](03-network-egress.md) | Internet, package registries, data uploads, DNS tunnelling, raw TCP and other programs (curl) are refused; only the model routes are allowed | [`verify-03.sh`](../scripts/verify-03.sh) |
| 04 | [Secrets and host files are out of reach](04-secrets-and-host-files.md) | Host files, other processes' environments, the Docker socket and cloud credentials can't be read | [`verify-04.sh`](../scripts/verify-04.sh) |
| 05 | [Privilege escalation is blocked](05-privilege-escalation.md) | No way from uid 10000 to root (no setuid, seccomp, no new privileges) | [`verify-05.sh`](../scripts/verify-05.sh) |
| 06 | [No installation, persistence or exposed services](06-install-and-persist.md) | Can't install packages, change the image or listen for outside connections | [`verify-06.sh`](../scripts/verify-06.sh) |
| 07 | [Prompt injection cannot cause damage](07-prompt-injection.md) | Even a fully obeyed malicious prompt can't exfiltrate data or loosen the policy | [`verify-07.sh`](../scripts/verify-07.sh) |
| 08 | [Resource abuse is contained](08-resource-abuse.md) | CPU, memory, process and disk abuse stay inside the cgroup limits | [`verify-08.sh`](../scripts/verify-08.sh) |

Each file follows the same layout: **Goal** · **Why it matters** (the threat) · **Enforcement points** · **Prompt** · **Equivalent command** · **Expected result** · **How to verify** · **Cleanup and repeatability**.
