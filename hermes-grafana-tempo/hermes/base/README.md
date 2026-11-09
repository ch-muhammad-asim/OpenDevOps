# 🏭 Hermes production profile (base)

The default, production-grade manifests for Hermes Agent's gateway telemetry and its public dashboard. [`../lab/`](../lab/README.md)
overlays these for a small lab cluster. How it works, security model, alerts and runbooks:
[`../README.md`](../README.md).

| File | What it does (one line) |
|---|---|
| [`namespace.yaml`](namespace.yaml) | Namespace `hermes` with Pod Security `restricted` enforced |
| [`config.yaml`](config.yaml) | Hermes `config.yaml`: OTLP monitoring export, model via `${env:...}` (custom provider), guardrails, skill dir, Nous usage metrics off, dashboard trusted proxies |
| [`pvc.yaml`](pvc.yaml) | 10Gi PVC for `HERMES_HOME` (sessions, memory, `state.db`) |
| [`deployment.yaml`](deployment.yaml) | ServiceAccount (no token) + singleton Deployment (`gateway` + `dashboard` containers), non-root, probes, digest-pinned image |
| [`service.yaml`](service.yaml) | ClusterIP Service `hermes-dashboard:9119` |
| [`ingress.yaml`](ingress.yaml) | Traefik IngressRoute for `hermes-gke.example.com` + Cloudflare-only and security-headers Middlewares (no proxy login) |
| [`pdb.yaml`](pdb.yaml) | PodDisruptionBudget that never blocks node drains (singleton) |
| [`networkpolicy.yaml`](networkpolicy.yaml) | Default deny (all pods); Hermes egress to DNS, the Collector `:4318`, the OpenCode bridge `:18282`, Thanos querier `:10902` / Tempo `:3200` / Grafana `:3000` (read-only skill; not Prometheus `:9090`) and public HTTPS `:443` (model API); ingress only from `traefik` to `:9119`; bridge policy: ingress from Hermes only, egress DNS, HTTPS, read-only endpoints |
| [`networkpolicy-observability.yaml`](networkpolicy-observability.yaml) | Ingress in `monitoring` / `observability`: only the Hermes pod to the Thanos querier, Tempo and Grafana |
| [`opencode-bridge.yaml`](opencode-bridge.yaml) | OpenCode bridge (default model provider, free models): ServiceAccount, policy ConfigMap, Deployment, Service; script from `../../../opencode/kubernetes/bridge/` |
| [`prometheusrule.yaml`](prometheusrule.yaml) | 5 Hermes alerts with runbook links |
| [`hermes-gateway-dashboard.json`](hermes-gateway-dashboard.json) | Grafana dashboard (uid `hermes-gateway`) |
| [`skills/`](skills/README.md) | Read-only observability skill (`SKILL.md` + `scripts/obs.py`), shipped as a ConfigMap |
| [`kustomization.yaml`](kustomization.yaml) | Builds all of the above, plus the config, skill and dashboard ConfigMaps |

```bash
hermes/deploy.sh          # production profile (this directory)
```
