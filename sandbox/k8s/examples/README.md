# ⚠️ `k8s/examples/`: alternatives, not deployed

Variants kept **for reference only**. `kubectl apply -k sandbox/k8s` does **not** include this folder ([`../kustomization.yaml`](../kustomization.yaml)). Parent folder: [`../README.md`](../README.md).

| File | What it shows | Why it isn't the default |
|---|---|---|
| [`env-secretkeyref.example.yaml`](env-secretkeyref.example.yaml) | Handing the NVIDIA key to a pod as an **environment variable** (`valueFrom.secretKeyRef`), for tools that only read `NVIDIA_API_KEY` from the environment. | An env var is inherited by every child process, shows up in env dumps, debug endpoints and crash reports, is readable via `/proc/<pid>/environ` by the same uid, and is fixed at container start (rotation needs a restart). The default, [`../provider-bootstrap-job.yaml`](../provider-bootstrap-job.yaml), mounts the key as a **read-only file**, which the kubelet refreshes on rotation. |

Full comparison: [`../../KUBERNETES.md`, Step 2](../../KUBERNETES.md#-step-2-consume-it-file-vs-env-and-hand-it-to-openshell).
