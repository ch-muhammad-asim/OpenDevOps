# 🛡️ `security/`: boundary, attacker probes and results

The security guardrails and the evidence for them: the **boundary** the sandbox policy may never exceed, the **attacker probes** that test it, and the latest **with vs without OpenShell** comparison.

> 📘 Threat model, controls and risk register: [`../SECURITY.md`](../SECURITY.md) · live demo of the same controls: [`../demo/`](../demo/README.md)

---

## 📁 Files

| File | What it is | Produced / used by |
|---|---|---|
| [`boundary.yaml`](boundary.yaml) | The **most** access Hermes may ever get, written as an OpenShell policy. It's the guardrail: change it only through a reviewed pull request. | [`../scripts/policy_check.sh`](../scripts/policy_check.sh) proves [`../hermes/policy.yaml`](../hermes/policy.yaml) and the live effective policy stay inside it (CI runs it on every change) |
| [`probes.py`](probes.py) | **22 attacker probes** (`security_compare.sh` adds a 23rd row, the resource limits, from `docker inspect`): what a compromised or prompt-injected agent might try (filesystem, secrets, network egress, privilege escalation, persistence, resources). Each reports `BLOCKED` or `ALLOWED`; read-only or self-cleaning; never prints file contents or secrets. | [`../scripts/security_compare.sh`](../scripts/security_compare.sh) |
| [`COMPARISON.md`](COMPARISON.md) | Latest side-by-side result (generated, don't edit by hand). | `security_compare.sh` |

---

## 📊 Latest result (2026-10-30)

| Outcome | Probes |
|---|---|
| 🛡️ Blocked **only** with OpenShell | **17** |
| ➖ Blocked either way (Docker defaults) | 5 |
| ⚠️ Allowed either way (residual risk, see SECURITY.md) | 1 |
| ❗ Weaker inside the sandbox | 0 |

Details per probe: [`COMPARISON.md`](COMPARISON.md).

---

## ▶️ Re-run

```bash
sandbox/scripts/policy_check.sh            # anywhere: proof against the boundary
sandbox/scripts/security_compare.sh        # on the server: probes with and without OpenShell, rewrites COMPARISON.md
```

`security_compare.sh` starts a temporary unsandboxed `hermes-baseline-*` container (removed afterwards) and never touches the live sandbox's data.
