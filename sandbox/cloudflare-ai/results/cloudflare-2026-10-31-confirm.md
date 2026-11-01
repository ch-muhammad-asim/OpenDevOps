# Cloudflare Workers AI free-model test (2026-10-31-confirm)

- Endpoint: `https://api.cloudflare.com/client/v4/accounts/<account>/ai/v1/chat/completions` (OpenAI-compatible)  
- Started 2026-10-31 10:58:18 UTC, finished 2026-10-31 11:05:05 UTC; rounds=5, max_tokens=200, rpm=20.0  
- Requests: 128, 429 retries: 0, tokens used: 32917, Neurons used: 1437 of the 10,000 free per day  
- Run result: **completed**

Per round: (a) random a+b, the exact number must be in the reply; (b) only for models that advertise function calling: an OpenAI `tools` call to `list_dir` with valid JSON arguments, then (c) a follow-up turn with the tool result must give a final text answer. A failed round stops that model. **Passed** = all rounds run, 100% correct, tools 100% (where supported), no errors.

## Models tested (10 of 39 text-generation models)

| Model | Passed | Rounds | Correct | Tools | Latency p50 / max s | Neurons | Beta | Notes |
|---|---|---|---|---|---|---|---|---|
| `@cf/daily-co/phonellm-mini-alpha-2` | ✅ | 5 | 100% | 100% | 0.63 / 1.50 | 24.1 |  |  |
| `@cf/meta/llama-4-scout-17b-16e-instruct` | ✅ | 5 | 100% | 100% | 0.70 / 1.63 | 177.7 |  |  |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | ✅ | 5 | 100% | 100% | 0.81 / 1.44 | 127.2 |  |  |
| `@cf/openai/gpt-oss-20b` | ✅ | 5 | 100% | 100% | 0.92 / 4.48 | 66.3 |  |  |
| `@cf/openai/gpt-oss-120b` | ✅ | 5 | 100% | 100% | 1.43 / 2.98 | 152.6 |  |  |
| `@cf/nvidia/nemotron-3-120b-a12b` | ✅ | 5 | 100% | 100% | 1.63 / 2.69 | 351.3 |  |  |
| `@cf/qwen/qwen3.8-27b` | ✅ | 5 | 100% | 100% | 1.84 / 22.97 | 487.1 |  |  |
| `@cf/google/gemma-4-26b-a4b-it` | ❌ | 1 | 0% | 100% | 1.32 / 5.09 | 12.6 |  | sum: wanted 14644, got '' |
| `@cf/mistralai/mistral-small-3.1-24b-instruct` | ❌ | 2 | 50% | 100% | 1.35 / 1.74 | 22.4 |  | sum: wanted 17999, got '18009' |
| `@cf/zai-org/glm-4.7-flash` | ❌ | 1 | 0% | 100% | 1.84 / 3.50 | 15.7 |  | sum: wanted 10042, got '' |
