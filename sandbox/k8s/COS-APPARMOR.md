# 🐧 OpenShell on GKE Container-Optimized OS: decision record (2026-11-01)

**Decision: not supported. The GKE lab stays on Ubuntu nodes (see [README.md → Node image](README.md#-node-image-ubuntu-not-cos-tested-2026-11-01)).** This record keeps the evidence and the options for clusters whose default node pool is COS. Source paths refer to the OpenShell repository at tag `v0.1.6`.

## Verdict
Unmodified NVIDIA OpenShell v0.1.6 (latest release, 2026-10-27, commit ac7f615) **cannot run on Container-Optimized OS**, and
AppArmor cannot replace Landlock through configuration.

## Evidence
| # | Finding | Source |
|---|---|---|
| 1 | The sandbox runtime's startup probe requires Landlock ABI >= 3 **unconditionally**, before any policy is read: `require_landlock_abi()?` then `probe_landlock_allow_deny()?` | `crates/openshell-sandbox/src/main.rs` (v0.1.6, ~L157-160) |
| 2 | Docs: "In either mode, a sandbox requires a kernel with Landlock ABI v3 or later. On an older kernel, startup fails" | `docs/how-it-works/policies/schema.mdx`; NVIDIA support matrix (docs.nvidia.com/openshell/latest/about/support-matrix) |
| 3 | `compatibility: best_effort` relaxes only the optional policy ruleset (no ruleset + High-severity OCSF `landlock-unavailable` alert when Landlock is missing; skipped paths). A separate mandatory baseline (e.g. hiding `/.openshell` from the agent) stays fail-closed | `sandbox/linux/landlock.rs` (~L260), `sandbox/linux/mod.rs` (~L50) |
| 4 | COS has no Landlock (real node: COS 125 build 19216.655.40, kernel 6.12.105+, GKE 1.35.8-gke.1796000): LSMs `capability,lockdown,yama,loadpin,safesetid,apparmor,bpf,ima`; `# CONFIG_SECURITY_LANDLOCK is not set`; `landlock_create_ruleset` -> ENOSYS. AppArmor is active | Node check on a test cluster `hermes-gke-cos` (since deleted) |
| 5 | The OpenShell Kubernetes driver cannot attach an AppArmor profile: container driver config = `resources`, `volume_mounts` only (`deny_unknown_fields`); pod config = `node_selector`, `runtime_class_name`, `tolerations`, `priority_class_name`; no `apparmor` in driver or docs; the driver re-verifies workload invariants on reconcile | `crates/openshell-driver-kubernetes/src/driver.rs` |
| 6 | Agent Sandbox v1.0.3 embeds `corev1.PodSpec` (the CRD could carry `appArmorProfile`), but OpenShell generates that template and exposes no setting for it | agent-sandbox `api/v1beta1/sandbox_types.go`; driver.rs |
| 7 | Kubernetes `securityContext.appArmorProfile` (Localhost) is GA; kubelet refuses pods whose profile is not loaded (fail-closed); Kubernetes has no built-in loader | kubernetes.io/docs/tutorials/security/apparmor/ |

## Why AppArmor would not be equivalent even if the runtime could start
- Landlock lets the trusted runtime (PID 1) use `/.openshell` while the agent cannot; one container-wide AppArmor profile cannot
  give the two processes different rights without profile transitions built into the runtime.
- AppArmor pathname rules differ from Landlock's hierarchy rules under renames, links and mount aliases; equivalence needs tests.
- Every RO/RW path in `hermes/policy.yaml` is expressible in AppArmor (incl. `/sandbox`, PTY devices, exec/mmap), and a loader is
  feasible (privileged DaemonSet, pinned parser image, startup taint, boot reconciliation), but that does not unblock 1-3.

## Options
| Option | Keeps OpenShell guarantees? | Note |
|---|---|---|
| A. OpenShell on a Landlock-capable node image (dedicated Ubuntu pool for sandboxes) | Yes | Verified working on GKE; rejected by the owner for now |
| B. Ask NVIDIA/OpenShell upstream for a non-Landlock (e.g. AppArmor) filesystem backend; adopt when released | Yes, once supported | No date; file an upstream issue with this evidence |
| C. Patch/fork OpenShell to skip the Landlock probe and rely on AppArmor | No (security redesign of a trust-critical component) | Not recommended |
| D. Hermes on COS without OpenShell (uid 10000, seccomp, custom AppArmor, no caps, NetworkPolicy, egress proxy) | No: loses per-binary OPA + L7 rules, TLS termination, credential injection (NVIDIA key in the pod), OCSF audit | Different, weaker product |
| E. Keep the verified Ubuntu `hermes-gke` for the lab; document COS as unsupported for OpenShell | Yes | **Chosen** |

## Outcome

Option E was chosen: `hermes-gke` stays on Ubuntu nodes, COS is documented as unsupported for OpenShell v0.1.6, and the COS test cluster was deleted. Revisit when an OpenShell release supports a non-Landlock filesystem backend.
