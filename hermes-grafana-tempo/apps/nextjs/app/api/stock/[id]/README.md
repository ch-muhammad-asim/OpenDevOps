# 📦 /api/stock/:id

`GET /api/stock/:id` proxies `nodejs-orders` `GET /orders/:id/stock` with no timeout of its own, so the
upstream `504` after ~2 s reaches the user (planted cascading timeout). See [`route.ts`](route.ts) and
the [app README](../../../../README.md#-planted-issues-and-how-to-find-them-in-tempo).

## 🏭 Production checklist

See the [nextjs-web production checklist](../../../../README.md#-production-checklist).
