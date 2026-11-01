#!/usr/bin/env bash
# DevSecOps scans for the Hermes sandbox. Every tool runs from a pinned
# Docker image, so nothing is installed on the host.
#
#   sandbox/scripts/scan.sh            # static checks + image scans + SBOM
#   SKIP_IMAGES=1 sandbox/scripts/scan.sh   # static checks only (fast, CI)
#
# Fails on: leaked secrets, shell/Dockerfile lint warnings, HIGH/CRITICAL
# misconfigurations. Image CVEs are reported only (they come from upstream
# images), unless FAIL_ON_IMAGE_VULNS=1 (then fixable CRITICALs fail).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORTS="${REPORTS:-$HOME/hermes-security-reports}"
HERMES_IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent:v0.22.5}"
TUNNEL_IMAGE="${TUNNEL_IMAGE:-hermes-tunnel:0.1.6}"
TRAEFIK_IMAGE="${TRAEFIK_IMAGE:-traefik:v3.7.15}"
GITLEAKS=zricethezav/gitleaks:v8.21.2
HADOLINT=hadolint/hadolint:v2.12.0
SHELLCHECK=koalaman/shellcheck:v0.10.0
TRIVY=aquasec/trivy:0.57.1
mkdir -p "$REPORTS"

pass=0; fail=0
step() { printf '\n==> %s\n' "$1"; }
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
trivy() { docker run --rm -v trivy-cache:/root/.cache -v "$HERE:/src:ro" "$@"; }

step "Secrets (gitleaks)"
if docker run --rm -v "$HERE:/src:ro" "$GITLEAKS" dir /src --no-banner --redact >/dev/null 2>&1; then
  ok "no secrets in sandbox/"
else bad "gitleaks found possible secrets: docker run --rm -v \"$HERE:/src:ro\" $GITLEAKS dir /src --redact"; fi

step "Dockerfile lint (hadolint)"
for f in hermes/Dockerfile tunnel/Dockerfile; do
  if out="$(docker run --rm -i "$HADOLINT" < "$HERE/$f" 2>&1)"; then ok "$f"
  else bad "$f"; printf '%s\n' "$out" | sed 's/^/        /'; fi
done

step "Shell script lint (shellcheck)"
# Expand the file list here: the container has no shell to expand globs.
mapfile -t scripts < <(cd "$HERE" && ls scripts/*.sh hermes/start-hermes.sh tunnel/entrypoint.sh demo/scripts/*.sh k8s/*.sh opencode/*.sh)
if out="$(docker run --rm -v "$HERE:/src:ro" -w /src "$SHELLCHECK" -S warning "${scripts[@]}" 2>&1)"; then
  ok "all ${#scripts[@]} shell scripts"
else bad "shellcheck warnings"; printf '%s\n' "$out" | sed 's/^/        /'; fi

step "Misconfiguration (trivy config)"
if out="$(trivy "$TRIVY" config --quiet --exit-code 1 --severity HIGH,CRITICAL /src 2>&1)"; then
  ok "no HIGH/CRITICAL misconfigurations"
else bad "trivy config"; printf '%s\n' "$out" | sed 's/^/        /'; fi

step "Policy as code (OpenShell prover)"
if out="$("$HERE/scripts/policy_check.sh" 2>&1)"; then ok "policy inside boundary; risky edits caught"
else bad "policy_check.sh"; printf '%s\n' "$out" | sed 's/^/        /'; fi

if [ "${SKIP_IMAGES:-0}" != 1 ]; then
  step "Image vulnerabilities (trivy image)"
  # Hermes is scanned straight from the registry (streams layers, needs little
  # disk); our wrapper only adds scripts and config on top of it.
  for spec in "remote $HERMES_IMAGE" "remote $TRAEFIK_IMAGE" "docker $TUNNEL_IMAGE"; do
    read -r src img <<<"$spec"
    name="$(echo "$img" | tr '/:' '__')"
    extra=(); [ "$src" = docker ] && extra=(-v /var/run/docker.sock:/var/run/docker.sock:ro)
    report="$REPORTS/$name.vulns.json"
    rm -f "$report"
    # A scan that fails (e.g. registry rate limit) must fail the run, not
    # silently produce an empty report.
    if ! docker run --rm -v trivy-cache:/root/.cache "${extra[@]}" -v "$REPORTS:/reports" "$TRIVY" image --quiet \
        --image-src "$src" --scanners vuln --format json --output "/reports/$name.vulns.json" "$img" >/dev/null 2>&1 \
        || [ ! -s "$report" ]; then
      bad "$img: image scan failed (no report)"
      continue
    fi
    # Prints the summary; exit 3 = fixable CRITICALs present.
    summary="$(python3 - "$report" <<'PY'
import json, sys, collections
d = json.load(open(sys.argv[1]))
c = collections.Counter(); fixable = collections.Counter()
for r in d.get("Results") or []:
    for v in r.get("Vulnerabilities") or []:
        c[v["Severity"]] += 1
        if v.get("FixedVersion"):
            fixable[v["Severity"]] += 1
print(" ".join(f"{s}={c[s]}(fixable {fixable[s]})" for s in ("CRITICAL", "HIGH", "MEDIUM", "LOW")))
sys.exit(3 if fixable["CRITICAL"] else 0)
PY
)"
    rc=$?
    if [ "${FAIL_ON_IMAGE_VULNS:-0}" = 1 ] && [ "$rc" = 3 ]; then
      bad "$img: fixable CRITICAL vulnerabilities ($summary)"
    else
      printf '  INFO  %s: %s\n' "$img" "$summary"
    fi
  done

  step "SBOM (CycloneDX)"
  docker run --rm -v trivy-cache:/root/.cache -v "$REPORTS:/reports" "$TRIVY" image --quiet --image-src remote \
    --format cyclonedx --output /reports/hermes-agent.sbom.cdx.json "$HERMES_IMAGE" >/dev/null 2>&1 \
    && printf '  INFO  SBOM written: %s (%s components)\n' "$REPORTS/hermes-agent.sbom.cdx.json" \
      "$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('components', [])))" "$REPORTS/hermes-agent.sbom.cdx.json")" \
    || bad "SBOM generation"
fi

echo
echo "Result: $pass passed, $fail failed (reports in $REPORTS)"
[ "$fail" -eq 0 ]
