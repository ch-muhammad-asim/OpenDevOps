# Cloudflare Workers AI free-model test (2026-10-31-reasoning-recheck)

- Endpoint: `https://api.cloudflare.com/client/v4/accounts/<account>/ai/v1/chat/completions` (OpenAI-compatible)  
- Started 2026-10-31 11:31:10 UTC, finished 2026-10-31 11:33:00 UTC; rounds=3, max_tokens=1500, rpm=20.0  
- Requests: 31, 429 retries: 0, tokens used: 8122, Neurons used: 166.3 of the 10,000 free per day (incl. 1.1 for probes)  
- Run result: **completed**

Per round: (a) random a+b, the exact number must be in the reply; (b) only for models that advertise function calling: an OpenAI `tools` call to `list_dir` with valid JSON arguments, then (c) a follow-up turn with the tool result must give a final text answer. A failed round stops that model. **Passed** = all rounds run, 100% correct, tools 100% (where supported), no errors.

## Models tested (3 of 39 text-generation models)

| Model | Passed | Rounds | Correct | Tools | Latency p50 / max s | Neurons | Beta | Notes |
|---|---|---|---|---|---|---|---|---|
| `@cf/qwen/qwen3-30b-a3b-fp8` | ✅ | 3 | 100% | 100% | 1.65 / 4.24 | 69.8 |  |  |
| `@cf/zai-org/glm-4.7-flash` | ✅ | 3 | 100% | 100% | 2.27 / 6.54 | 57.3 |  |  |
| `@cf/google/gemma-4-26b-a4b-it` | ✅ | 3 | 100% | 100% | 3.64 / 6.13 | 38.1 |  |  |
