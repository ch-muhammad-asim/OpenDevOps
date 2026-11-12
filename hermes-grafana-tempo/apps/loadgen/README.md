# 🔁 loadgen: continuous demo traffic

One tiny `curlimages/curl` pod that calls the healthy endpoints of the sample apps in a loop, so
Tempo keeps receiving traces and the [Tempo Service Graph](../README.md) always has nodes and edges
to draw. **Why:** `scripts/load.sh` is a one-shot run, so a stack that has been idle since the last
demo has no recent traces: Explore Traces looks empty and the service graph loses its edges.

It hits `nextjs/`, `nextjs/api/dashboard` (the traced `nextjs → nodejs → python → sqlite` chain) and
`nodejs/orders` and `python/inventory/items` directly, once every `INTERVAL_SECONDS` (8 s), so all
five graph nodes stay warm at roughly the rate Explore shows by default. Every call is a healthy
one: no planted-error endpoint, so error-rate alerts are not affected.

| Knob | Default | Meaning |
|---|---|---|
| `spec.replicas` | 1 | One loop is enough; more only adds load |
| `INTERVAL_SECONDS` | 8 | Seconds between rounds |
| `NEXTJS_URL`, `NODEJS_URL`, `PYTHON_URL` | cluster Services | Where to send traffic |

Restricted-PSS compliant: non-root uid 100, read-only root filesystem, all capabilities dropped,
`RuntimeDefault` seccomp, no service-account token, tiny requests/limits. In-cluster calls are
allowed by the `allow-same-namespace` NetworkPolicy in `tempo-apps`.

Turn it off for a quiet cluster: `kubectl -n tempo-apps scale deployment/loadgen --replicas=0`.
