# 🔌 /api: scenario routes

Each route calls `nodejs-orders` through [`orders.ts`](../../orders.ts) and carries one planted
issue, marked `PLANTED ISSUE:` in the code. Details and TraceQL: [app README](../../README.md#-planted-issues-and-how-to-find-them-in-tempo).

| Route | File | Planted issue |
|---|---|---|
| `GET /api/dashboard` | [`dashboard/route.ts`](dashboard/route.ts) | N+1 HTTP fan-out (and a handled downstream failure) |
| `POST /api/checkout` | [`checkout/route.ts`](checkout/route.ts) | Unhandled `TypeError` on an empty cart |
| `GET /api/stock/:id` | [`stock/[id]/route.ts`](stock/%5Bid%5D/route.ts) | Cascading timeout (no own timeout) |
| `GET /api/report` | [`report/route.ts`](report/route.ts) | Slow upstream (CPU hog in nodejs-orders) |

## 🏭 Production checklist

See the [nextjs-web production checklist](../../README.md#-production-checklist).
