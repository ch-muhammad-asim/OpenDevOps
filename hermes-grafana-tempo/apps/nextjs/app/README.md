# 📁 app: Next.js App Router pages and route handlers

Next.js maps each folder here to a URL; `route.ts` answers the request, `page.tsx` renders a page.
Next.js ignores these `README.md` files. Back to the [app README](../README.md).

| Path | File | What it does |
|---|---|---|
| `/` | [`page.tsx`](page.tsx), [`layout.tsx`](layout.tsx) | Server-rendered list of the scenarios (no client JavaScript) |
| `/healthz` | [`healthz/route.ts`](healthz/route.ts) | Probe endpoint, not traced |
| `/api/*` | [`api/`](api/README.md) | The four scenario routes with the planted issues |

## 🏭 Production checklist

See the [nextjs-web production checklist](../README.md#-production-checklist).
