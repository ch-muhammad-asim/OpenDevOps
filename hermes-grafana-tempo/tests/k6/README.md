# 📈 k6 scripts

[`load.js`](load.js) is the single [Grafana k6](https://grafana.com/docs/k6/latest/) script behind every load scenario.
`tests/run.sh` mounts it into a Kubernetes Job; see the [tests README](../README.md) for scenarios, thresholds and results.

| Env | Values | Default |
|---|---|---|
| `APP` | `nextjs`, `nodejs`, `python` | `nodejs` |
| `SCENARIO` | `smoke`, `load`, `stress`, `spike`, `soak` | `smoke` |
| `SCALE` | multiplier for every stage duration | `1` |
| `SOAK_DURATION` | soak hold time, e.g. `2h` | `120s × SCALE` |
| `BASE_URL` | target override | in-cluster Service of `APP` |
