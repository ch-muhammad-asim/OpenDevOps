# 💓 /healthz

`GET /healthz` returns `200 {"status":"ok"}` for the Kubernetes readiness and liveness probes.
Not traced: the sampler in [`instrumentation.node.ts`](../../instrumentation.node.ts) drops its spans.

## 🏭 Production checklist

See the [nextjs-web production checklist](../../README.md#-production-checklist).
