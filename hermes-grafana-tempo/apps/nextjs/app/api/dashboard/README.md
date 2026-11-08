# 📊 /api/dashboard

`GET /api/dashboard` loads the order list, then each order one by one (planted N+1 fan-out). Failed
orders become `order.fetch_failed` span events and `"partial": true` in the response.
See [`route.ts`](route.ts) and the [app README](../../../README.md#-planted-issues-and-how-to-find-them-in-tempo).

## 🏭 Production checklist

See the [nextjs-web production checklist](../../../README.md#-production-checklist).
