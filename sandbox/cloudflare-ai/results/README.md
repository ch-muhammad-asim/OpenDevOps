# 📊 `cloudflare-ai/results/`: Workers AI test reports

Reports written by [`../cf_ai_bench.py`](../cf_ai_bench.py). Each run writes a readable **`.md`** report and the raw **`.json`** data. The Cloudflare token and account ID are redacted, and the script refuses to keep a report that contains either. Summary and recommendations: [`../README.md`](../README.md).

| Report | Run | Settings | Result |
|---|---|---|---|
| [`cloudflare-2026-10-31.md`](cloudflare-2026-10-31.md) ([json](cloudflare-2026-10-31.json)) | **Screening** of all 39 text-generation models | 1 round, 200 tokens | 19 models answered, 16 passed; 20 not tested (paid plan only, not chat models, …) |
| [`cloudflare-2026-10-31-confirm.md`](cloudflare-2026-10-31-confirm.md) ([json](cloudflare-2026-10-31-confirm.json)) | **Confirmation** of the 10 models that passed tool calling | 5 rounds, 200 tokens | 7 passed every round |
| [`cloudflare-2026-10-31-reasoning-recheck.md`](cloudflare-2026-10-31-reasoning-recheck.md) ([json](cloudflare-2026-10-31-reasoning-recheck.json)) | **Recheck** of 3 reasoning models that gave empty answers at 200 tokens | 3 rounds, 1,500 tokens | all 3 passed |

New runs land here by default (`--out-dir`, `--stamp`). Neuron use is in each report's header; all three runs together used about 2,100 of the 10,000 free daily Neurons.
