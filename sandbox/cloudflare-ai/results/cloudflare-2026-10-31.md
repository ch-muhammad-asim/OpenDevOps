# Cloudflare Workers AI free-model test (2026-10-31)

- Endpoint: `https://api.cloudflare.com/client/v4/accounts/<account>/ai/v1/chat/completions` (OpenAI-compatible)  
- Started 2026-10-31 10:53:38 UTC, finished 2026-10-31 10:57:53 UTC; rounds=1, max_tokens=200, rpm=20.0  
- Requests: 77, 429 retries: 0, tokens used: 9580, Neurons used: 427 of the 10,000 free per day  
- Run result: **completed**

Per round: (a) random a+b, the exact number must be in the reply; (b) only for models that advertise function calling: an OpenAI `tools` call to `list_dir` with valid JSON arguments, then (c) a follow-up turn with the tool result must give a final text answer. A failed round stops that model. **Passed** = all rounds run, 100% correct, tools 100% (where supported), no errors.

## Models tested (19 of 39 text-generation models)

| Model | Passed | Rounds | Correct | Tools | Latency p50 / max s | Neurons | Beta | Notes |
|---|---|---|---|---|---|---|---|---|
| `@cf/daily-co/phonellm-mini-alpha-2` | ✅ | 1 | 100% | 100% | 0.64 / 0.98 | 4.8 |  |  |
| `@cf/meta/llama-4-scout-17b-16e-instruct` | ✅ | 1 | 100% | 100% | 0.64 / 0.71 | 35.5 |  |  |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | ✅ | 1 | 100% | 100% | 0.71 / 1.38 | 25.4 |  |  |
| `@cf/mistralai/mistral-small-3.1-24b-instruct` | ✅ | 1 | 100% | 100% | 0.83 / 2.12 | 11.2 |  |  |
| `@cf/openai/gpt-oss-120b` | ✅ | 1 | 100% | 100% | 0.84 / 1.03 | 23.6 |  |  |
| `@cf/openai/gpt-oss-20b` | ✅ | 1 | 100% | 100% | 0.84 / 1.09 | 13.0 |  |  |
| `@cf/nvidia/nemotron-3-120b-a12b` | ✅ | 1 | 100% | 100% | 1.70 / 1.80 | 70.9 |  |  |
| `@cf/qwen/qwen3.8-27b` | ✅ | 1 | 100% | 100% | 1.76 / 13.48 | 84.9 |  |  |
| `@cf/zai-org/glm-4.7-flash` | ✅ | 1 | 100% | 100% | 1.85 / 12.10 | 14.5 |  |  |
| `@cf/google/gemma-4-26b-a4b-it` | ✅ | 1 | 100% | 100% | 2.03 / 3.62 | 11.2 |  |  |
| `@cf/meta/llama-3.2-3b-instruct` | ✅ | 1 | 100% | n/a | 0.30 / 0.30 | 0.3 |  |  |
| `@cf/aisingapore/gemma-sea-lion-v4-27b-it` | ✅ | 1 | 100% | n/a | 0.49 / 0.49 | 1.3 |  |  |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | ✅ | 1 | 100% | n/a | 0.62 / 0.62 | 3.4 |  |  |
| `@cf/meta/llama-3.1-8b-instruct-fp8` | ✅ | 1 | 100% | n/a | 0.67 / 0.67 | 0.5 |  |  |
| `@cf/deepseek-ai/deepseek-r1-distill-qwen-32b` | ✅ | 1 | 100% | n/a | 5.96 / 5.96 | 90.0 |  |  |
| `@cf/qwen/qwq-32b` | ✅ | 1 | 100% | n/a | 6.10 / 6.10 | 20.0 |  |  |
| `@cf/qwen/qwen3-30b-a3b-fp8` | ❌ | 1 | 0% | 100% | 1.21 / 2.50 | 16.0 |  | sum: wanted 12451, got '' |
| `@cf/ibm-granite/granite-4.0-h-micro` | ❌ | 1 | 100% | 0% | 1.50 / 2.20 | 0.7 |  | bad tool call: list_dir "{\n  \"path\": \"/etc/hermes\"\n}" |
| `@cf/meta/llama-3.2-1b-instruct` | ❌ | 1 | 0% | n/a | 0.50 / 0.50 | 0.1 |  | sum: wanted 9120, got '10220' |

## Not tested

| Model | Status |
|---|---|
| `@cf/cloudflare/clairic` | not a chat model (Cloudflare task-specific input schema) |
| `@cf/cloudflare/clef` | not a chat model (Cloudflare task-specific input schema) |
| `@cf/cloudflare/clef-flash` | not a chat model (Cloudflare task-specific input schema) |
| `@cf/cloudflare/clef-omni` | not a chat model (Cloudflare task-specific input schema) |
| `@cf/deepseek-ai/deepseek-v4-flash-0731` | paid plan only (Workers Paid) |
| `@cf/deepseek-ai/deepseek-v4-pro-0813` | paid plan only (Workers Paid) |
| `@cf/deepseek-ai/deepseek-v4.1-flash-1017` | paid plan only (Workers Paid) |
| `@cf/google/gemma-2b-it-lora` | not a chat model (LoRA base or safety classifier) |
| `@cf/google/gemma-7b-it-lora` | not a chat model (LoRA base or safety classifier) |
| `@cf/meta-llama/llama-2-7b-chat-hf-lora` | not a chat model (LoRA base or safety classifier) |
| `@cf/meta/llama-3.2-11b-vision-instruct` | needs a one-time licence agreement (send the prompt 'agree') |
| `@cf/meta/llama-guard-3-8b` | not a chat model (LoRA base or safety classifier) |
| `@cf/mistral/mistral-7b-instruct-v0.2-lora` | not a chat model (LoRA base or safety classifier) |
| `@cf/moonshotai/kimi-k2.6` | paid plan only (Workers Paid) |
| `@cf/moonshotai/kimi-k2.7-code` | paid plan only (Workers Paid) |
| `@cf/swiss-ai/apertus-v1.5-8b` | probe HTTP 403: {"errors":[{"message":"AiError: Ai: This account is not allowed to access @cf/swiss-ai/apertus-v1.5-8b. (3bc564ac-5a05-47a3-a4f0-357e414a0ad |
| `@cf/utter-project/eurollm-9b-it` | probe HTTP 400: {"errors":[{"message":"AiError: AiError: AI model does not have config (15fc976b-c010-4d68-b9e8-25ecf8dee33d)","code":4003}],"success":false |
| `@cf/zai-org/glm-5.2` | paid plan only (Workers Paid) |
| `@cf/zai-org/glm-5.3` | paid plan only (Workers Paid) |
| `@cf/zai-org/glm-5.3-flash` | paid plan only (Workers Paid) |
