# 🗺️ `traefik/dynamic/`: routes and TLS options

Traefik's **dynamic** configuration (file provider). Traefik watches this folder and **reloads changes live**, with no restart. Mounted read-only at `/etc/traefik/dynamic`. Parent folder: [`../README.md`](../README.md).

---

## 📁 Files

| File | What it does |
|---|---|
| [`hermes.yml`](hermes.yml) | Routers, middlewares and services for `hermes.saqlainmushtaq.com`. |
| [`tls.yml`](tls.yml) | Default TLS options for `:443`: **TLS 1.2 minimum**, modern cipher suites. `sniStrict` stays off, because the built-in default certificate doesn't match the hostname. |
| `tls-origin.yml` *(generated, git-ignored)* | Written by `scripts/https_up.sh` from [`../tls-origin.yml.tmpl`](../tls-origin.yml.tmpl) only when a Cloudflare Origin Certificate exists. Don't edit it. |

---

## 🧭 Routes in `hermes.yml`

| Router | Entry point | Matches | Goes to |
|---|---|---|---|
| `hermes-login` | `:443` | `/auth/password-login` | dashboard, with the **login rate limit** |
| `hermes-api` | `:443` | `/v1`, `/v1/…` | API (`hermes-tunnel:8642`) |
| `hermes-dashboard` | `:443` | everything else | dashboard (`hermes-tunnel:9119`) |
| `…-flexible` (3) | `:80` | same, when Cloudflare says the visitor used HTTPS (`X-Forwarded-Proto: https`, SSL mode *Flexible*) | same targets, no redirect loop |
| `hermes-redirect` | `:80` | any other plain-HTTP request | redirect to `https://` |

Every router uses the **`cloudflare-only`** middleware (`ipAllowList` of Cloudflare's published IP ranges; anyone else gets `403`). All except `hermes-redirect` (which uses `to-https`) add **`security-headers`**: HSTS for a year incl. subdomains, `nosniff`, `SAMEORIGIN` framing (also as CSP `frame-ancestors 'self'`), a referrer policy, and empty `Server`/`X-Powered-By`. The login routers add **`login-ratelimit`** (10 attempts per minute, burst 10, per real visitor IP from `CF-Connecting-IP`).

---

## ✏️ Changing it

- **Hostname:** it appears in every `rule:`; change all of them (and `HERMES_HOST` in [`../../site.env`](../../site.env)).
- **Cloudflare IP ranges:** update `sourceRange` from <https://www.cloudflare.com/ips/> when Cloudflare changes them.
- **Ports:** the `url:` values must match the tunnel's ports ([`../../tunnel/.env.example`](../../tunnel/.env.example)).
- After a change: `docker logs --tail 20 hermes-traefik` shows reload errors; then run `verify_https.sh`.
