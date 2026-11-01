#!/usr/bin/env bash
# Run the same attacker probes against Hermes WITHOUT OpenShell (a plain
# `docker run` of the stock image) and WITH OpenShell (the `hermes` sandbox),
# then write a side-by-side Markdown report.
#
#   sandbox/scripts/security_compare.sh [report.md]
#
# The baseline container joins the OpenCode bridge's Docker network, the way
# an unsandboxed Hermes would normally reach it, and is removed afterwards.
# Probes run as the `hermes` user (uid 10000) in both cases.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENSHELL="${OPENSHELL:-openshell}"
SANDBOX_NAME="${SANDBOX_NAME:-hermes}"
HERMES_IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent:v0.22.5}"
BRIDGE_CONTAINER="${BRIDGE_CONTAINER:-sourcecheck-bridge}"
REPORT="${1:-$HERE/security/COMPARISON.md}"
BASELINE=hermes-baseline-$$
PY=/opt/hermes/.venv/bin/python

work="$(mktemp -d)"
cleanup() { docker rm -f "$BASELINE" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

# Ship the probes as base64 so no quoting can break on the way in.
code="import base64; exec(base64.b64decode('$(base64 -w0 "$HERE/security/probes.py")'))"

# Baseline = DEFAULT `docker run` of the stock image: its root entrypoint
# boots the s6 supervision tree (root processes), then runs `sleep infinity`
# as hermes. A hand-hardened docker run (no-new-privileges, limits) would
# close a few process/resource rows, but none of the network/L7 ones.
echo "==> Baseline: stock $HERMES_IMAGE in plain Docker"
net="$(docker inspect "$BRIDGE_CONTAINER" -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' | head -1)"
bridge_ip="$(docker inspect "$BRIDGE_CONTAINER" -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}")"
gw_ip="$(docker network inspect "$net" -f '{{(index .IPAM.Config 0).Gateway}}')"
docker run -d --name "$BASELINE" --network "$net" "$HERMES_IMAGE" sleep infinity >/dev/null
for _ in $(seq 1 30); do docker exec "$BASELINE" true 2>/dev/null && break; sleep 1; done
sleep 3
docker exec -u hermes "$BASELINE" "$PY" -c "$code" "$bridge_ip" "$gw_ip" > "$work/baseline.jsonl" || true

echo "==> OpenShell: sandbox $SANDBOX_NAME"
timeout 300 "$OPENSHELL" sandbox exec -n "$SANDBOX_NAME" --no-tty -- \
  "$PY" -c "$code" host.openshell.internal host.openshell.internal > "$work/sandbox.jsonl" 2>&1 || true

# Resource limits, read from Docker (memory bytes, PID limit, CPU nanos).
limits() {
  docker inspect "$1" -f '{{.HostConfig.Memory}} {{if .HostConfig.PidsLimit}}{{.HostConfig.PidsLimit}}{{else}}0{{end}} {{.HostConfig.NanoCpus}}' | {
    read -r mem pids cpu
    blocked=$([ "${mem:-0}" -gt 0 ] && [ "${pids:-0}" -gt 0 ] && echo true || echo false)
    printf '{"id":"res.limits","result":"%s","detail":"memory=%s pids=%s cpus=%s (0 = unlimited)"}\n' \
      "$([ "$blocked" = true ] && echo BLOCKED || echo ALLOWED)" \
      "$((mem / 1048576))MiB" "$pids" "$(awk "BEGIN{print ${cpu:-0}/1e9}")"
  }
}
limits "$BASELINE" >> "$work/baseline.jsonl"
workload="$(docker ps --format '{{.Names}}' | grep -E "^openshell-default--${SANDBOX_NAME}-" | grep -v -- '-supervisor$' | head -1)"
limits "$workload" >> "$work/sandbox.jsonl"

python3 - "$work/baseline.jsonl" "$work/sandbox.jsonl" "$REPORT" "$HERMES_IMAGE" <<'PY'
import datetime, json, sys

base_f, sbx_f, out_f, image = sys.argv[1:5]

ATTACKS = {
    "net.internet_https": ("Network", "Reach any website (download tools, call home)"),
    "net.exfil_post": ("Network", "Upload stolen data to an outside server"),
    "net.dns_real_resolution": ("Network", "Real DNS lookups (DNS tunnelling of data)"),
    "net.cloud_metadata": ("Network", "Query the cloud metadata service (steal cloud credentials)"),
    "net.host_ssh": ("Network", "Connect to the host's SSH port (lateral movement)"),
    "net.raw_tcp_outside": ("Network", "Open plain TCP to an outside server (reverse shell, custom protocol)"),
    "net.allowed_host_child_process": ("Network", "A program Hermes starts (curl) uses the one allowed service"),
    "net.allowed_host_forbidden_path": ("Network", "Call a non-allowed API path on the allowed service"),
    "net.network_interfaces": ("Network", "Have a network card at all"),
    "fs.write_var_tmp": ("Filesystem", "Stage payloads in /var/tmp"),
    "fs.write_dev_shm": ("Filesystem", "Stage payloads in shared memory /dev/shm"),
    "fs.read_outside_policy": ("Filesystem", "Read world-readable system files (reconnaissance)"),
    "fs.list_root": ("Filesystem", "List the root filesystem"),
    "fs.tamper_hermes_code": ("Filesystem", "Modify the agent's own code"),
    "fs.write_etc": ("Filesystem", "Modify system config in /etc"),
    "fs.docker_socket": ("Filesystem", "Reach the Docker socket (full host takeover)"),
    "proc.no_new_privs": ("Process", "Gain privileges through setuid binaries"),
    "proc.root_in_namespace": ("Process", "Root-owned processes running next to the agent"),
    "proc.ptrace_child": ("Process", "Attach a debugger to read process memory"),
    "proc.user_namespace": ("Process", "Create user namespaces (kernel attack surface)"),
    "proc.raw_socket": ("Process", "Open raw sockets (packet crafting)"),
    "proc.read_agent_env": ("Process", "Read other same-user processes' environment"),
    "res.limits": ("Resources", "Exhaust host memory or processes (no memory/PID limit)"),
}

def load(path):
    rows = {}
    for line in open(path, errors="replace"):
        line = line.strip()
        if line.startswith("{"):
            try:
                r = json.loads(line)
                rows[r["id"]] = r
            except ValueError:
                pass
    return rows

base, sbx = load(base_f), load(sbx_f)
mark = {"BLOCKED": "🔒 blocked", "ALLOWED": "🔓 allowed", "ERROR": "❔ probe error", None: "❔ no result"}
counts = {"sandbox": 0, "both_block": 0, "both_allow": 0, "worse": 0, "missing": 0}
lines = []
for pid, (area, attack) in ATTACKS.items():
    b, s = base.get(pid), sbx.get(pid)
    br, sr = (b or {}).get("result"), (s or {}).get("result")
    if br in (None, "ERROR") or sr in (None, "ERROR"):
        verdict = "❔ incomplete"; counts["missing"] += 1
    elif br == "ALLOWED" and sr == "BLOCKED":
        verdict = "🛡️ **OpenShell blocks it**"; counts["sandbox"] += 1
    elif br == "BLOCKED" and sr == "BLOCKED":
        verdict = "➖ blocked either way"; counts["both_block"] += 1
    elif br == "ALLOWED" and sr == "ALLOWED":
        verdict = "⚠️ allowed either way"; counts["both_allow"] += 1
    else:
        verdict = "❗ weaker in sandbox"; counts["worse"] += 1
    lines.append(f"| {area} | {attack} | {mark[br]}<br><sub>{(b or {}).get('detail', '')}</sub> "
                 f"| {mark[sr]}<br><sub>{(s or {}).get('detail', '')}</sub> | {verdict} |")

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
total = len(ATTACKS)
with open(out_f, "w") as f:
    f.write(f"""# 🆚 Hermes with vs without OpenShell: attack comparison

Generated by `sandbox/scripts/security_compare.sh` on **{now}**.

The same {total} attacker probes (`sandbox/security/probes.py`) ran as the `hermes` user (uid 10000) in two setups:

- **Without OpenShell:** the stock `{image}` image in a plain `docker run`, on the same Docker network as the OpenCode bridge.
- **With OpenShell:** the `hermes` sandbox from this repo (`hermes/policy.yaml`).

## 📊 Summary

| Outcome | Probes |
|---|---|
| 🛡️ Blocked **only** with OpenShell | **{counts['sandbox']}** |
| ➖ Blocked either way (Docker defaults already stop it) | {counts['both_block']} |
| ⚠️ Allowed either way (residual risk, see SECURITY.md) | {counts['both_allow']} |
| ❗ Weaker inside the sandbox | {counts['worse']} |
| ❔ No result or probe error | {counts['missing']} |

> ℹ️ Baseline = a **default** `docker run`. Hand-hardening it (`--security-opt no-new-privileges`, `--memory`, `--pids-limit`, `--cap-drop ALL`) would close a few Process/Resources rows, but **none of the Network rows**: plain Docker has no per-host, per-program or per-API-path egress control. A probe only counts as blocked when the system refused it (permission denied or connection refused); timeouts and other errors show as ❔.

## 🔎 Details

| Area | Attack the probe simulates | Without OpenShell | With OpenShell | Verdict |
|---|---|---|---|---|
""")
    f.write("\n".join(lines) + "\n")
print(f"OpenShell-only blocks: {counts['sandbox']}/{total}, both block: {counts['both_block']}, "
      f"both allow: {counts['both_allow']}, weaker: {counts['worse']}, missing: {counts['missing']}")
print(f"report: {out_f}")
sys.exit(1 if counts["worse"] or counts["missing"] else 0)
PY
