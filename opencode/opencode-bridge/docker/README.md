# Docker / containers — OpenCode bridge (Kubernetes implementation available)

[← Main bridge guide](../README.md) · [Existing Kubernetes sidecar](../../kubernetes/README.md)

The repository already contains an **OpenCode bridge container workflow inside the Hermes + bridge Kubernetes deployment**, backed by [`opencode_bridge.py`](../../kubernetes/bridge/opencode_bridge.py). It dynamically discovers **all OpenCode models with zero advertised input/output cost** and Hermes uses it as the **default provider** in the existing Kubernetes configuration.

**No tested standalone Docker Compose OpenCode bridge installation has been identified in this repository.** The root [`docker-bridge/`](../../../docker-bridge/README.md) and [`docker/`](../../../docker/README.md) folders refer to **Claude Code** bridges and must not be copied under an OpenCode label.

For a containerized deployment today, use or adapt the [existing Kubernetes manifests](../../kubernetes/README.md) with a reviewed image, policy, workspace, secret injection and loopback/container networking. See the [Kubernetes entry point](../kubernetes/README.md). Do not assume a standalone Compose service exists or is tested.

**Hermes default endpoint in the existing shared-pod design:** `http://127.0.0.1:18282/v1` with provider `opencode-bridge`. This only works when Hermes and the bridge share the same pod network namespace. A separate Docker container requires a real service name and isolated network; its own `127.0.0.1` cannot reach another container.
