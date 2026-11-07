# 🔎 `herdr-agent-detection/`: herdr's state rules for Hermes

A pinned herdr agent-detection manifest for Hermes Agent. With it, herdr reports the Hermes pane correctly as `idle`, `working` or `blocked`, which `agent prompt --wait`, `agent wait` and the tests rely on. Where it sits: see [Architecture](../README.md#️-architecture) and [Components](../README.md#-components).

## 📁 Files

| File | What it does |
|------|--------------|
| [`hermes.toml`](hermes.toml) | Manifest `id = "hermes"`, version `2026.11.07.1`, engine ≥ 2. It has herdr's bundled Hermes rules (2026.07.24.1) plus `tui_turn_working`, which matches the Hermes v0.22.5+ TUI line "type to redirect this turn" and its spinner |
| `README.md` | This page (not copied into the image) |

## ⚙️ How it is used

- [`../Dockerfile`](../Dockerfile) copies the folder to `/opt/hermes-herdr/herdr-agent-detection` (root-owned, files 0644).
- [`../entrypoint.sh`](../entrypoint.sh) copies `hermes.toml` to `$HOME/.config/herdr/agent-detection/hermes.toml` (`HOME=/data/home` on the `hermes-herdr-data` volume, uid 10000) before it starts the herdr server.
- herdr reads the override only when it starts: after a change, rebuild and restart `herdr-hermes` ([Troubleshooting](../README.md#-troubleshooting)).
- Rule order: the `blocked` prompt rules (approval, clarification, credential and confirmation, priority 900) outrank the added `tui_turn_working` rule (850), so an approval prompt during a turn still shows as `blocked`.

## 🛡️ Security notes

- Detection only: it decides which state herdr reports and grants no access. A wrong rule can hide a `blocked` approval prompt from the operator, so test 3 must pass after any change.
- No secrets, hostnames or IPs; it contains only screen-text patterns.

## 🧪 Tests

| # | What it proves |
|---|----------------|
| 1 | herdr recognizes Hermes (kind `hermes`) and sees idle → working → idle |
| 3 | A dangerous command's approval prompt shows as `blocked` in herdr, Deny is chosen, and the command doesn't run |
| 14 | After `docker restart herdr-hermes` the agent is back `idle` |

Last full run: 15/15 PASS on Hermes Agent v0.22.5 and herdr 0.9.5 (2026-11-07, [`../scripts/e2e-test.sh`](../scripts/e2e-test.sh)); the v0.23.0 re-run is in progress ([Tests](../README.md#-tests)).

⬆️ Back to [herdr + Hermes Agent POC](../README.md)
