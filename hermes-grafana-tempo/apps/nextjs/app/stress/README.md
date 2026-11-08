# 🔥 Stress routes

Bounded CPU and memory load for the [resource tests](../../../../tests/README.md). Both are off unless
`STRESS_ENABLED=true`, are capped by env, and answer 404 to any request that came through Traefik (it sets
`X-Forwarded-For`), so only in-cluster callers reach them. Shared helpers are in [`stress.ts`](../../stress.ts).

| Route | Query | Cap (env, default) | Span |
|---|---|---|---|
| `GET /stress/cpu` | `ms` (default 200) | `STRESS_MAX_CPU_MS` 5000 | `stress.cpu` |
| `GET /stress/memory` | `mb` (default 32), `hold_s` (default 5) | `STRESS_MAX_MB` 128 (total held), `STRESS_MAX_HOLD_S` 30 | `stress.memory`; 429 when the budget is in use |
