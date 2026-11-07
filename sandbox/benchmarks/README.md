# 📊 `benchmarks/`: NVIDIA model test results

Results of [`../scripts/nvidia_bench.py`](../scripts/nvidia_bench.py), which tested every chat model on the **NVIDIA API Catalog** for what Hermes needs: correct answers, reliable OpenAI-style **tool calls**, and low latency. These results chose Hermes's default model and its two fallbacks ([`../hermes/config.yaml`](../hermes/config.yaml)).

> 📘 How models are chosen and switched: [`../README.md`](../README.md) (NVIDIA models) · Cloudflare's free models: [`../cloudflare-ai/`](../cloudflare-ai/README.md)

---

## 📁 Files

| File | What it is |
|---|---|
| [`nvidia-2026-10-30.md`](nvidia-2026-10-30.md) | **Main report**: the recommendation, the ranked table of every chat model tested, the confirmation results, and every model not usable (retired, not enabled, errors). |
| [`nvidia-2026-10-30.json`](nvidia-2026-10-30.json) | Raw data for the report (screening run plus the merged confirmation results). |
| [`nvidia-2026-10-30-confirm.json`](nvidia-2026-10-30-confirm.json), [`nvidia-2026-10-30-confirm-2.json`](nvidia-2026-10-30-confirm-2.json) | Raw data of the 5-round **stability confirmation** of the top candidates (merged into the main report). |
| [`nvidia-2026-10-30-glm-retest.md`](nvidia-2026-10-30-glm-retest.md) + [`.json`](nvidia-2026-10-30-glm-retest.json) | Single-model retest of `z-ai/glm-5.3-flash`: still timed out (no first token within 30 s). |

---

## 🏆 Result (stability-confirmed, 5 rounds each)

| Role in Hermes | Model | Total latency p50 / p95 |
|---|---|---|
| ⭐ Default | `nvidia/nemotron-3.5-super-vl-120b-a12b` | 0.95 / 1.75 s |
| Fallback 1 | `openai/gpt-oss-20b` | 2.18 / 3.64 s |
| Fallback 2 | `meta/muse-glimmer-30b` | 5.30 / 18.62 s |

Each round: a random `a + b` (exact answer), a `list_dir` tool call with valid JSON arguments, and a follow-up turn with the tool result that must give a final answer.

---

## ▶️ Re-run

Run from your laptop (key in `~/.config/hermes-sandbox/creds/nvidia/api` or the file in `NVIDIA_API_KEY_FILE`, `600`); re-run before changing models and whenever NVIDIA retires one:

```bash
python3 sandbox/scripts/nvidia_bench.py                              # screening: every chat model, 1 round
python3 sandbox/scripts/nvidia_bench.py --models a,b,c --requests 5 \
  --confirm-of sandbox/benchmarks/nvidia-$(date -u +%F).json          # confirm the top 3
```

The key is only sent in the `Authorization` header and is redacted from every report.
