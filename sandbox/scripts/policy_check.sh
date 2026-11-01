#!/usr/bin/env bash
# Policy as code: prove hermes/policy.yaml stays inside security/boundary.yaml,
# and prove that common risky edits are caught.
#
#   sandbox/scripts/policy_check.sh
#
# Uses the standalone OpenShell policy prover (an SMT solver; no gateway
# needed). Downloads it, checksum-verified, if it isn't on PATH.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$HERE/hermes/policy.yaml"
BOUNDARY="$HERE/security/boundary.yaml"
VERSION="${OPENSHELL_VERSION:-0.1.6}"

PROVER="$(command -v openshell-prover || true)"
if [ -z "$PROVER" ]; then
  bin="${PROVER_DIR:-$HOME/.local/bin}"
  mkdir -p "$bin"
  tmp="$(mktemp -d)"
  base="https://github.com/NVIDIA/OpenShell/releases/download/v$VERSION"
  asset="openshell-prover-$(uname -m)-unknown-linux-musl.tar.gz"
  (cd "$tmp" && curl -fsSLO "$base/$asset" && curl -fsSLO "$base/openshell-prover-checksums-sha256.txt" \
    && grep " $asset\$" openshell-prover-checksums-sha256.txt | sha256sum -c - >/dev/null \
    && tar -xzf "$asset" && install -m 0755 openshell-prover "$bin/openshell-prover")
  rm -rf "$tmp"
  PROVER="$bin/openshell-prover"
fi

pass=0; fail=0
# The prover exits non-zero for anything but within_boundary; read the
# printed result instead of letting `set -e` stop the script.
result() { { "$PROVER" check "$1" --boundary "$BOUNDARY" 2>&1 || true; } | sed -n 's/^result: //p' | head -1; }

echo "1. The real policy must stay inside the boundary"
r="$(result "$POLICY")"
if [ "$r" = within_boundary ]; then echo "  PASS  hermes/policy.yaml: $r"; pass=$((pass + 1))
else echo "  FAIL  hermes/policy.yaml: ${r:-error}"; "$PROVER" check "$POLICY" --boundary "$BOUNDARY" || true; fail=$((fail + 1)); fi

echo "2. Risky edits must be caught (anything but within_boundary)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mutate() {  # name, description, then a sed/awk program applied to the policy
  local name="$1" desc="$2"; shift 2
  "$@" "$POLICY" > "$work/$name.yaml"
  local r; r="$(result "$work/$name.yaml")"
  if [ "$r" != within_boundary ]; then echo "  PASS  caught: $desc -> ${r:-error}"; pass=$((pass + 1))
  else echo "  FAIL  NOT caught: $desc"; fail=$((fail + 1)); fi
}
mutate internet  "open egress to api.github.com" \
  awk '{print} END {print "  github:\n    endpoints:\n      - { host: api.github.com, port: 443, protocol: rest, enforcement: enforce, access: full }\n    binaries:\n      - path: /usr/bin/curl"}'
mutate curl      "let curl call the bridge" \
  sed 's#^\(      - path: /opt/hermes/tools/.*\)$#\1\n      - path: /usr/bin/curl#'
mutate landlock  "Landlock hard_requirement -> best_effort" \
  sed 's/compatibility: hard_requirement/compatibility: best_effort/'
mutate etc_write "make /etc writable" \
  sed 's#^  read_write:$#  read_write:\n    - /etc#'
mutate audit     "bridge rules in audit mode (log only, don't block)" \
  sed 's/enforcement: enforce/enforcement: audit/'
mutate any_path  "allow every method and path on the bridge" \
  sed 's#- allow: { method: GET, path: /health }#- allow: { method: "*", path: "/**" }#'
mutate root      "run the workload as root (uid 0)" \
  sed 's/run_as_user: "10000"/run_as_user: "0"/'
mutate any_ip    "add a raw IP destination (1.1.1.1)" \
  sed 's/host: host.openshell.internal/host: 1.1.1.1/'

echo
echo "Note: 'unsupported' means the prover could not model the change (for"
echo "example any filesystem widening, or audit mode). It is NOT a proof; this"
echo "script and CI fail closed on it, as the OpenShell docs require."

echo
echo "3. The live sandbox's effective policy (incl. provider rules) must stay inside the boundary"
if command -v "${OPENSHELL:-openshell}" >/dev/null 2>&1 \
   && "${OPENSHELL:-openshell}" sandbox get "${SANDBOX_NAME:-hermes}" >/dev/null 2>&1; then
  "${OPENSHELL:-openshell}" sandbox get "${SANDBOX_NAME:-hermes}" --policy-only > "$work/effective.yaml" 2>/dev/null
  r="$(result "$work/effective.yaml")"
  if [ "$r" = within_boundary ]; then echo "  PASS  effective policy of '${SANDBOX_NAME:-hermes}': $r"; pass=$((pass + 1))
  else echo "  FAIL  effective policy of '${SANDBOX_NAME:-hermes}': ${r:-error}"; fail=$((fail + 1)); fi
else
  echo "  SKIP  no OpenShell CLI or sandbox here (CI); run on the server"
fi

echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
