# 🎬 `demo/scripts/`: demo verification scripts

Scripts behind the **DevSecOps demo**: one `verify-NN.sh` per use case proves on the live server that the control shown in the demo really holds, plus reset and a full repeatable dry run. Run them **on the server**.

> 📘 The demo guide (script, talking points, use cases): [`../README.md`](../README.md) · the use cases: [`../use-cases/`](../use-cases/README.md)

---

## 📁 Files

| Script | What it does |
|---|---|
| [`reset.sh`](reset.sh) | Restores a clean demo state (idempotent): deletes demo files and processes, the throwaway `hermes-abuse` sandbox and `DEMO-` chat sessions; checks the live policy equals [`../../hermes/policy.yaml`](../../hermes/policy.yaml) and re-applies it on drift (`RESET_NO_REAPPLY=1` only reports); then health checks. |
| [`run-all.sh`](run-all.sh) | Full dry run: reset → verify 01..08 → reset → verify 01..08 → health. The second round proves the demo is repeatable. Full output also goes to a log file. |
| [`verify-01.sh`](verify-01.sh) | UC 01: the agent answers through the approved model endpoints only (exec proof on the bridge) |
| [`verify-02.sh`](verify-02.sh) | UC 02: create, read, edit and delete a file in the workspace |
| [`verify-03.sh`](verify-03.sh) | UC 03: nothing crosses the network boundary except the model endpoints (checked in the OCSF logs too) |
| [`verify-04.sh`](verify-04.sh) | UC 04: host secrets, host files and cloud credentials are out of reach |
| [`verify-05.sh`](verify-05.sh) | UC 05: no path from the agent user to root |
| [`verify-06.sh`](verify-06.sh) | UC 06: no installing software, persisting or exposing a service |
| [`verify-07.sh`](verify-07.sh) | UC 07: a successful prompt injection still can't exfiltrate or loosen the policy |
| [`verify-08.sh`](verify-08.sh) | UC 08: resource abuse is contained by the cgroup limits (uses a throwaway sandbox, never the live one) |
| [`ask.sh`](ask.sh) | Sends one prompt to Hermes's API (same agent, tools and model as the web chat) and prints the reply; used by the [guardrail prompts](../../README.md#-try-it-yourself-guardrail-prompts). |
| [`lib.sh`](lib.sh) | Shared helpers (sourced, not run): PASS/FAIL output, sandbox exec with timeouts, log checks, the LLM budget, health checks. |

---

## ▶️ How to run

```bash
sandbox/demo/scripts/reset.sh                 # before and after a demo
sandbox/demo/scripts/verify-03.sh             # one use case
sandbox/demo/scripts/run-all.sh               # everything, twice
sandbox/demo/scripts/run-all.sh --with-llm    # also send the DEMO-NN prompts to the model
```

- 🪙 **Model calls are opt-in** (`--with-llm`) and capped at `LLM_BUDGET` prompts per run (default 3); steps report `SKIP` while the model quota is used up.
- 🛡️ The scripts never re-create or restart the live sandbox (`run-all.sh` checks its container ID before and after), never print secrets, and clean up what they create.
- ⚙️ Settings (`SANDBOX_NAME`, `HERMES_ADDR`, `LLM_TIMEOUT`, …): [`../../ENVIRONMENT.md` §8.1 and §9](../../ENVIRONMENT.md#-9-tests).
