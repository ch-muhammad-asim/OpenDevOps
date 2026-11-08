# 📈 /api/report

`GET /api/report` fetches the report from `nodejs-orders`; its ~1.3 s latency comes from a CPU-bound
loop upstream (span `orders.build_report`). See [`route.ts`](route.ts) and the
[app README](../../../README.md#-planted-issues-and-how-to-find-them-in-tempo).

## 🏭 Production checklist

See the [nextjs-web production checklist](../../../README.md#-production-checklist).
