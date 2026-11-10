# GCP VM — OpenCode bridge for Hermes (separate from OpenCode Desktop)

[← Main bridge guide](../README.md) · [Full GCP runbook and diagrams](../../opentunnel/hermes-bridge-gcp.md) · [Already verified Desktop/Web path](../../opentunnel/remote-desktop-gcp.md)

Your Mac's OpenCode Desktop **already worked** with the VM's native OpenCode Web `:8443`. The Hermes OpenAI-compatible **bridge** is a different process: `:18282/v1`, not yet validated on that VM.

**On GCP Ubuntu VM**, use the single Python source in this repository:

```bash
git clone https://github.com/ch-muhammad-asim/OpenDevOps.git
cd OpenDevOps/opencode/kubernetes/bridge
BRIDGE_SELFCHECK=1 python3 opencode_bridge.py
mkdir -p "$HOME/opencode-bridge-workspace"
read -rs -p "Bridge key: " OPENCODE_BRIDGE_API_KEY; echo
export OPENCODE_BRIDGE_API_KEY

# Free-only model discovery (no --models pin); safe first-run approvals OFF.
python3 opencode_bridge.py --host 127.0.0.1 --port 18282 \
  --cwd "$HOME/opencode-bridge-workspace" \
  --api-key "$OPENCODE_BRIDGE_API_KEY" \
  --free-only --no-auto-approve
```

From another GCP terminal: `curl -H "Authorization: Bearer $OPENCODE_BRIDGE_API_KEY" http://127.0.0.1:18282/v1/models`. For a real completion, refer to the [full runbook](../../opentunnel/hermes-bridge-gcp.md).

**On Mac**, forward a *separate* local 18282 port (leave the Desktop 8443 forward untouched):

```bash
gcloud compute ssh instance-20261110-043424 \
  --project=playground-s-11-fffe4a40 --zone=us-central1-c \
  -- -N -L 127.0.0.1:18282:127.0.0.1:18282
```

For **Hermes on the Mac**, use `http://127.0.0.1:18282/v1`, the Bearer key, auto-discovered free models, then Test → Save → Use. **For Hermes in GKE, that Mac localhost URL cannot work**; see [Kubernetes](../kubernetes/README.md) for in-pod bridge or create a private GKE-to-VM path. Do not expose a credentialed agent endpoint publicly.
