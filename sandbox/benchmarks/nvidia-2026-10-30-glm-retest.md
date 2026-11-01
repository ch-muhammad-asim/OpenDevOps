# NVIDIA API Catalog benchmark for Hermes Agent (glm-retest)

> Single-model retest of `z-ai/glm-5.3-flash` only (1 probe). It is not a full benchmark, so the empty ranking and "no model met the bar" below refer to this one model.

- Base URL: `https://integrate.api.nvidia.com/v1`  
- Started: 2026-10-30 18:23:24 UTC, finished: 2026-10-30 18:23:56 UTC  
- Settings: rounds=1, rpm=30, max_tokens=300, timeouts 30s first token / 90s total, streaming SSE  
- Requests sent: 2; HTTP 429 retries: 0; quota events: 0  
- Run result: **completed**

Tests per round: (a) random a+b, exact number in reply; (b) OpenAI `tools` `list_dir` call with valid JSON args; (c) follow-up turn with role `tool` result must produce a final text answer. A model failing a round gets no further rounds. Qualified = all rounds run, 100% correct, 100% tool call+follow-up, 0 errors/timeouts; ranked by total-latency p95.

## Catalogue

85 model ids. non-chat: 26, skipped: 58, timeout: 1

## Recommendation

No model met the qualification bar.

## Chat models tested (ranked)

| Model | Status | Rounds | Correct | Tool call+follow-up | TTFT p50/p95 s | Total p50/p95 s | Err/TO | 429s | Notes |
|---|---|---|---|---|---|---|---|---|---|

## Not tested: retired / unavailable / errors

| Model | Status | Detail |
|---|---|---|
| `z-ai/glm-5.3-flash` | timeout | timeout: The read operation timed out |

## Non-chat models (excluded by name)

| Model | Class |
|---|---|
| `adept/fuyu-8b` | vision-only |
| `google/deplot` | vision-only |
| `meta/llama-guard-4-12b` | guard/safety |
| `microsoft/kosmos-2` | vision-only |
| `nvidia/ai-synthetic-video-detector` | vision-only |
| `nvidia/embed-qa-4` | embedding |
| `nvidia/llama-3.1-nemoguard-8b-content-safety` | guard/safety |
| `nvidia/llama-3.1-nemoguard-8b-topic-control` | guard/safety |
| `nvidia/llama-3.1-nemotron-safety-guard-8b-v3` | guard/safety |
| `nvidia/llama-3.2-nemoretriever-1b-vlm-embed-v1` | embedding |
| `nvidia/llama-3.2-nv-embedqa-1b-v1` | embedding |
| `nvidia/llama-nemotron-embed-vl-1b-v2` | embedding |
| `nvidia/nemotron-3-embed-1b` | embedding |
| `nvidia/nemotron-3.5-content-safety` | guard/safety |
| `nvidia/nemotron-3.5-embed-1b` | embedding |
| `nvidia/nemotron-3.5-embed-8b` | embedding |
| `nvidia/nemotron-4-340b-reward` | reward |
| `nvidia/nemotron-parse` | parse/ocr |
| `nvidia/nemotron-parse-2.0` | parse/ocr |
| `nvidia/neva-22b` | vision-only |
| `nvidia/nv-embedqa-mistral-7b-v2` | embedding |
| `nvidia/nvclip` | embedding |
| `nvidia/riva-translate-4b-instruct` | translate |
| `nvidia/riva-translate-4b-instruct-v2` | translate |
| `nvidia/vila` | vision-only |
| `snowflake/arctic-embed-l` | embedding |
