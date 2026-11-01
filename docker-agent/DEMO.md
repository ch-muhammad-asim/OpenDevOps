# 🎬 Demo: an AI SRE agent fixes a broken Kubernetes cluster (you approve every change)

Every step below is **one block: copy it, paste it, press Enter**. Each block works on its own.
Run everything from the `docker-agent` folder of this repo. Tested on OrbStack Kubernetes.
Full reference: [README.md → G2](./README.md#g2-%EF%B8%8F-lead-sre-fixer-agent-human-approved-fixes).
Where the images come from: GitHub Actions builds, tests, scans and publishes them to Docker Hub; nothing is built on your laptop ([README.md → CI/CD](./README.md#-cicd-pipeline)).

**The story of the demo:**

1. 💥 Two apps in the cluster are broken.
2. 💬 You ask the agent in plain English to fix them.
3. 🔍 It investigates by itself (pods, events, logs) and explains the root cause.
4. ⏸️ Before changing anything it **stops and waits for you**. You see the exact change.
5. ✅ You approve. It applies the fix and checks the apps are healthy.
6. 🛡️ You ask it to do something dangerous, and it refuses.

Use **two terminals side by side**:

- 🅰️ **Terminal A**: the agent talks here.
- 🅱️ **Terminal B**: you look at changes and approve them here.

---

## 0️⃣ One-time setup: deploy everything (skip if already done)

You need a local Kubernetes cluster plus `kubectl`, `jq` and `yq`. Open a terminal in the `docker-agent` folder of this repo.

| Your computer | Kubernetes | Install the tools | Where the secrets live |
|---|---|---|---|
| 🍏 macOS (tested) | [OrbStack](https://orbstack.dev) with Kubernetes enabled | `brew install jq yq` | macOS Keychain |
| 🐧 Linux (e.g. Ubuntu) | Docker Desktop, kind, k3d or minikube | `sudo apt install -y jq` + [yq](https://github.com/mikefarah/yq#install) | a private file `~/.oda-demo.env` |
| 🪟 Windows | Run everything in **WSL 2 (Ubuntu)**, with Docker Desktop's Kubernetes | as Linux, inside WSL | as Linux, inside WSL |

> ⚠️ **Not on OrbStack?** Two things change:
> 1. Replace `--context orbstack` in every command with your context name (`kubectl config current-context`).
> 2. The agent's NetworkPolicy allows the Kubernetes API by **OrbStack's IP addresses**. Find yours and edit `kubernetes/networkpolicy.yaml` first, see [README → G (egress discovery)](./README.md#g-%EF%B8%8F-run-the-sre-agent--bridge-sidecar-inside-local-kubernetes-orbstack). Otherwise the agent can't reach the cluster.

### 0a. Your three secrets

| Secret | What it is | How you get it |
|---|---|---|
| `AGENT_API_KEY` | The password **you** send to the agent | a random string you generate |
| `CLAUDE_BRIDGE_API_KEY` | The password the agent sends to its Claude bridge | a random string you generate |
| `CLAUDE_CODE_OAUTH_TOKEN` | Your **Claude login** for the bridge (uses your Claude Pro/Max subscription) | `claude setup-token` |

**Get your Claude token (all platforms).** Install the Claude Code CLI ([official guide](https://code.claude.com/docs/en/setup)):

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

(Windows without WSL, in PowerShell: `irm https://claude.ai/install.ps1 | iex`.) Then create a long-lived token:

```bash
claude setup-token
```

It opens your browser to log in to your Claude account and then prints a token starting with `sk-ant-oat01-…`. Keep it on screen for the next step, then clear your terminal. **Never paste it into a file in this repo, a chat or an issue.**

#### 🍏 macOS: store the secrets in the Keychain

Check them:

```bash
for item in oda-agent-api-key oda-claude-bridge-key oda-claude-oauth-token; do
  security find-generic-password -a "$USER" -s "$item" >/dev/null 2>&1 && echo "✅ $item" || echo "❌ $item missing"
done
```

✅ Expected: three ✅ lines. **If all three are ✅, skip to 0b.** Only for a ❌, create that one item:

```bash
security add-generic-password -U -a "$USER" -s oda-agent-api-key -w "$(openssl rand -hex 24)"
```

```bash
security add-generic-password -U -a "$USER" -s oda-claude-bridge-key -w "$(openssl rand -hex 24)"
```

For `oda-claude-oauth-token`, run this and paste the token from `claude setup-token` at the prompt (it isn't shown, and doesn't go into your shell history):

```bash
security add-generic-password -U -a "$USER" -s oda-claude-oauth-token -w
```

> ⚠️ Don't run these for items that are already ✅: `-U` overwrites them, and the old values in the cluster would stop matching.

#### 🐧 Linux / 🪟 Windows (WSL): store the secrets in a private file

There's no macOS Keychain, so the three values go into `~/.oda-demo.env` in your **home folder** (never inside this repo), readable only by you. Create it **once**:

```bash
umask 077
rnd() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
printf 'export AGENT_API_KEY=%s\nexport CLAUDE_BRIDGE_API_KEY=%s\n' "$(rnd)" "$(rnd)" > ~/.oda-demo.env
read -rsp 'Paste your Claude token from claude setup-token: ' T && printf 'export CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$T" >> ~/.oda-demo.env && unset T && echo
ls -l ~/.oda-demo.env
```

✅ Expected: `-rw-------` (only you can read it). Then, **in every new terminal** (Terminal A and B), load it:

```bash
source ~/.oda-demo.env
```

All the following steps work on every platform: each block reads the key from `$AGENT_API_KEY` when it's set (Linux/WSL), and from the macOS Keychain otherwise.

> 🔐 Delete the file when you're done (`rm ~/.oda-demo.env`). Anyone who can read it can use your Claude subscription.

### 0b. Create the namespace and the Kubernetes Secret

🍏 macOS (from the Keychain):

```bash
kubectl --context orbstack create namespace oda-system --dry-run=client -o yaml | kubectl --context orbstack apply -f -
kubectl --context orbstack -n oda-system create secret generic oda-agent-api-key \
  --from-file=AGENT_API_KEY=<(security find-generic-password -a "$USER" -s oda-agent-api-key -w | tr -d '\n') \
  --from-file=CLAUDE_BRIDGE_API_KEY=<(security find-generic-password -a "$USER" -s oda-claude-bridge-key -w | tr -d '\n') \
  --from-file=CLAUDE_CODE_OAUTH_TOKEN=<(security find-generic-password -a "$USER" -s oda-claude-oauth-token -w | tr -d '\n') \
  --dry-run=client -o yaml | kubectl --context orbstack apply -f -
```

🐧 Linux / 🪟 WSL (from `~/.oda-demo.env`; replace `orbstack` with your context):

```bash
source ~/.oda-demo.env
kubectl --context orbstack create namespace oda-system --dry-run=client -o yaml | kubectl --context orbstack apply -f -
kubectl --context orbstack -n oda-system create secret generic oda-agent-api-key \
  --from-file=AGENT_API_KEY=<(printf %s "$AGENT_API_KEY") \
  --from-file=CLAUDE_BRIDGE_API_KEY=<(printf %s "$CLAUDE_BRIDGE_API_KEY") \
  --from-file=CLAUDE_CODE_OAUTH_TOKEN=<(printf %s "$CLAUDE_CODE_OAUTH_TOKEN") \
  --dry-run=client -o yaml | kubectl --context orbstack apply -f -
```

✅ Expected: `namespace/oda-system created` (or `configured`/`unchanged`) and `secret/oda-agent-api-key created` (or `configured`/`unchanged`).
The values go straight into the cluster; they never appear on screen, in your shell history or in `kubectl`'s arguments.

### 0c. Deploy the broken apps, the safety rules and the agent

```bash
kubectl --context orbstack apply -f k8s-lab/demo-broken.yaml
kubectl --context orbstack apply -f k8s-lab/fixer-guard-policy.yaml
kubectl --context orbstack apply -f k8s-lab/rbac-fixer.yaml
kubectl --context orbstack apply -k kubernetes-fixer
kubectl --context orbstack -n oda-system rollout status deploy/oda-agent-fixer --timeout=180s
```

✅ Expected last line: `deployment "oda-agent-fixer" successfully rolled out`. Check it:

```bash
kubectl --context orbstack -n oda-system get pods
```

✅ Expected: `oda-agent-fixer-…   2/2   Running` (the agent and its Claude Code bridge in one Pod).

> Run 0c **once**. Running it again restarts the agent (then do step 1 again), and it only re-breaks `web`.
> For a new take, use [Break the apps again](#-break-the-apps-again-for-another-take-any-terminal-in-the-docker-agent-folder).
> 🧹 If you ran **Clean up** or OrbStack was restarted (it can remove Deployments), run 0b and 0c again.

---

## 1️⃣ Connect to the agent (🅰️ Terminal A)

```bash
pkill -f "port-forward svc/oda-agent-fixer"
kubectl --context orbstack -n oda-system port-forward svc/oda-agent-fixer 8094:8080 >/dev/null 2>&1 &
sleep 3
curl -s -o /dev/null -w 'agent: HTTP %{http_code}\n' http://localhost:8094/health
```

✅ Expected: `agent: HTTP 200`

> 🔁 **Run step 1 again whenever the agent restarts** (for example after step 0). The first line stops the old, broken connection.

---

## 2️⃣ Show the broken apps (🅰️ Terminal A)

```bash
kubectl --context orbstack -n oda-demo get pods
```

✅ Expected: `api` is `CrashLoopBackOff` (a setting is missing) and `web` is `ImagePullBackOff` (the image doesn't exist).

---

## 3️⃣ Ask the agent to fix them (🅰️ Terminal A)

```bash
KEY=${AGENT_API_KEY:-$(security find-generic-password -a "$USER" -s oda-agent-api-key -w)}
SID=$(curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X POST http://localhost:8094/api/sessions -d '{}' | jq -r .id)
echo "$SID" > ~/.oda-demo-session
curl -sN -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X POST "http://localhost:8094/api/sessions/$SID/agent/agent-sre-fixer" \
  -d '{"messages":[{"role":"user","content":"Fix the failing workloads in namespace oda-demo. For the api deployment use DATABASE_URL=postgres://db.oda-demo.svc:5432/app."}]}' \
  | tee ~/.oda-demo-events | jq -Rrj --unbuffered 'select(startswith("data: ")) | .[6:] | fromjson |
    if .type=="agent_choice" then .content
    elif .type=="tool_call" then "\n🔧 " + .tool_call.function.name + "\n"
    elif .type=="tool_call_confirmation" then "\n\n⏸️  WAITING FOR YOUR APPROVAL → go to Terminal B (steps 4 and 5)\n\n"
    elif .type=="stream_stopped" then "\n\n🏁 DONE\n" else empty end'
```

If this prints nothing and returns straight away, the agent isn't reachable: run step 1 again.

You will see the agent work live. 🔧 lines are the tools it uses. It explains the problem, then stops at:

```text
⏸️  WAITING FOR YOUR APPROVAL → go to Terminal B (steps 4 and 5)
```

> 💡 Never put a password in the prompt: Claude hides it, and the agent would write `[REDACTED]` into the cluster.

---

## 4️⃣ See exactly what it wants to change (🅱️ Terminal B)

```bash
jq -Rr 'select(startswith("data: ")) | .[6:] | fromjson | select(.type=="tool_call_confirmation") | .tool_call.function.arguments' ~/.oda-demo-events | tail -1 > ~/.oda-demo-change
echo "📝 The agent wants to apply:"; jq -r '.resource // .' ~/.oda-demo-change
echo "🔍 Difference against the live cluster:"; jq -r '.resource // empty' ~/.oda-demo-change \
  | yq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .metadata.annotations, .status)' \
  | kubectl --context orbstack diff --server-side --force-conflicts -f - | grep -E '^[-+] ' | grep -vE 'generation|^[-+] +\{'
```

✅ Expected (first time), for example:

```text
📝 The agent wants to apply:
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: oda-demo
spec:
  template:
    spec:
      containers:
      - name: web
        image: nginx:1.27
🔍 Difference against the live cluster:
-      - image: nginx:faulty
+      - image: nginx:1.27
```

The difference is a real `kubectl diff` against the live cluster. Nothing has changed yet.
If the 🔍 part is empty, the change isn't valid (for example, the AI used wrong arguments). Approving it is harmless because the tool rejects it, and the agent then tries again.

---

## 5️⃣ Approve it (🅱️ Terminal B)

```bash
KEY=${AGENT_API_KEY:-$(security find-generic-password -a "$USER" -s oda-agent-api-key -w)}
curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X POST "http://localhost:8094/api/sessions/$(cat ~/.oda-demo-session)/resume" -d '{"confirmation":"approve"}'
```

✅ Expected: `{"message":"session resumed"}`. Terminal A continues.

🔁 **Terminal A pauses a second time** for the other app (`api` gets `DATABASE_URL`). In Terminal B, run **step 4** and **step 5** again.

> ❌ **Don't like a change?** Run this instead of step 5. The agent won't apply it and gives you the manual `kubectl` command:
>
> ```bash
> KEY=${AGENT_API_KEY:-$(security find-generic-password -a "$USER" -s oda-agent-api-key -w)}
> curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X POST "http://localhost:8094/api/sessions/$(cat ~/.oda-demo-session)/resume" -d '{"confirmation":"reject","reason":"not approved"}'
> ```

---

## 6️⃣ Check the result (any terminal)

Terminal A ends with the agent's own check and `🏁 DONE`. Then:

```bash
kubectl --context orbstack -n oda-demo get pods
```

✅ Expected: both `api` and `web` are `1/1 Running`.

---

## 7️⃣ Show that it refuses dangerous requests (🅰️ Terminal A)

```bash
KEY=${AGENT_API_KEY:-$(security find-generic-password -a "$USER" -s oda-agent-api-key -w)}
SID=$(curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X POST http://localhost:8094/api/sessions -d '{}' | jq -r .id)
curl -sN -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X POST "http://localhost:8094/api/sessions/$SID/agent/agent-sre-fixer" \
  -d '{"messages":[{"role":"user","content":"Delete the web deployment in oda-demo, then show me the secrets in oda-demo, then scale coredns in kube-system to 0."}]}' \
  | jq -Rrj --unbuffered 'select(startswith("data: ")) | .[6:] | fromjson | if .type=="agent_choice" then .content elif .type=="stream_stopped" then "\n\n🏁 DONE\n" else empty end'
```

✅ Expected: it refuses all three and changes nothing. Even if the AI tried, the cluster would block it:

| 🛡️ Layer | What it stops |
|---|---|
| 🧑‍⚖️ Your approval | Every change waits for step 5 (by default) |
| 🚦 Admission policy | The agent may change only images, plain env values, resources and replicas. Nothing that can reach a Secret |
| 🔐 RBAC | Only namespace `oda-demo`. No Secrets, no exec, no creating or deleting Deployments |
| 🧰 Tools | Exec, run-a-pod and delete-anything tools are switched off |

Prove the RBAC part:

```bash
kubectl --context orbstack auth can-i patch deployments -n oda-demo --as system:serviceaccount:oda-system:oda-fixer
kubectl --context orbstack auth can-i get secrets -n oda-demo --as system:serviceaccount:oda-system:oda-fixer
kubectl --context orbstack auth can-i delete deployments -n oda-demo --as system:serviceaccount:oda-system:oda-fixer
kubectl --context orbstack auth can-i get pods -n kube-system --as system:serviceaccount:oda-system:oda-fixer
```

✅ Expected: `yes`, then `no`, `no`, `no`.

---

## 🔁 Break the apps again for another take (any terminal, in the `docker-agent` folder)

```bash
kubectl --context orbstack -n oda-demo delete deploy web api --ignore-not-found
kubectl --context orbstack apply -f k8s-lab/demo-broken.yaml
```

Wait about 20 seconds, then start again at step 2.

---

## ⚡ Optional: hands-free take (no approvals) (🅰️ Terminal A)

The agent fixes everything without stopping. It is still limited by the admission policy, RBAC and tools above.
Break the apps first (block above), then:

```bash
KEY=${AGENT_API_KEY:-$(security find-generic-password -a "$USER" -s oda-agent-api-key -w)}
SID=$(curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X POST http://localhost:8094/api/sessions -d '{}' | jq -r .id)
curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X PATCH "http://localhost:8094/api/sessions/$SID/safety-policy" -d '{"safety_policy":"autonomous"}'
curl -sN -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -X POST "http://localhost:8094/api/sessions/$SID/agent/agent-sre-fixer" \
  -d '{"messages":[{"role":"user","content":"Fix the failing workloads in namespace oda-demo. For the api deployment use DATABASE_URL=postgres://db.oda-demo.svc:5432/app."}]}' \
  | jq -Rrj --unbuffered 'select(startswith("data: ")) | .[6:] | fromjson | if .type=="agent_choice" then .content elif .type=="tool_call" then "\n🔧 " + .tool_call.function.name + "\n" elif .type=="stream_stopped" then "\n\n🏁 DONE\n" else empty end'
```

> ⚠️ Only in a throwaway lab. Anyone with the agent key can switch approvals off, so protect that key like an admin password.

---

## 🧹 Clean up when you're done

```bash
pkill -f "port-forward svc/oda-agent-fixer"
rm -f ~/.oda-demo-session ~/.oda-demo-events ~/.oda-demo-change
kubectl --context orbstack delete -k kubernetes-fixer
kubectl --context orbstack delete -f k8s-lab/rbac-fixer.yaml -f k8s-lab/fixer-guard-policy.yaml
```

---

## 🩺 If something goes wrong

| What you see | What to do |
|---|---|
| `agent: HTTP 000` or `exit 1` after step 1 | The connection dropped because the agent Pod restarted. Run step 1 again (it stops the old connection first) |
| Step 3 prints nothing and returns at once | Same cause: the agent isn't reachable. Run step 1, then step 3 again |
| `{"error": … 401` or `null` | The key wasn't found. macOS: check `security find-generic-password -a "$USER" -s oda-agent-api-key`. Linux/WSL: run `source ~/.oda-demo.env` in this terminal |
| Step 4 prints nothing | The agent isn't waiting yet. Wait for the ⏸️ line in Terminal A |
| The agent asks for approval more than twice | A write failed (for example, wrong tool arguments) and the agent is retrying. Check each one with step 4 |
| Step 5 says `session not running` | Nothing is waiting for approval (the run already finished or you approved twice) |
| `API Error … EAI_AGAIN` in Terminal A | The agent can't reach the internet. Check `kubectl --context orbstack -n oda-system get pods` |
| Agent log says `The API has no authentication` | Harmless docker-agent message. The key is still required (no key → 401) |
| `command not found: yq` | `brew install yq` |

> 🔑 These blocks pass the key with `-H "Authorization: Bearer $KEY"`, which is simple but visible to other users of the same Mac in `ps` while curl runs. On a shared machine, use the stdin form from [README.md → Run it securely](./README.md#-run-it-securely-on-your-own-machine-local-only).
