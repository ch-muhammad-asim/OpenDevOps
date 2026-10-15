# 🤖 Docker Agent — Local → Docker Hub → Kubernetes

> **Status: Planned / documentation only.** This folder is a placeholder for an upcoming Docker Agent experiment. No agent has been built, tested, published to Docker Hub, or deployed to Kubernetes yet.

**Upstream docs:** [Docker Agent](https://docs.docker.com/ai/docker-agent/) · [Official source](https://github.com/docker/docker-agent)

## Overview

[Docker Agent](https://docs.docker.com/ai/docker-agent/) (formerly called **cagent** in earlier Docker Desktop versions) is Docker's open-source framework for defining and orchestrating specialized AI agents in YAML or HCL. Agents can use models from different providers and connect to tools, including MCP servers. This is **not** Docker's separate built-in AI assistant, Gordon (`docker ai`).

**Goal for OpenDevOps:** evaluate Docker Agent as a **security-first DevOps/SRE assistant**, starting locally and promoting only a tested version to Docker Hub and Kubernetes.

```text
Develop agent config
        │
        ▼
Local Docker Agent CLI + provider/local model
        │  validate configuration, run tests, evaluate tool permissions
        ▼
Publish agent definition (OCI artifact) to Docker Hub
        │
        ├── docker agent share push    [agent configuration, NOT a runnable image]
        │
        ▼
Build + scan separate container runtime image
        │
        └── docker buildx build --push [runnable container image]
        │
        ▼
Kubernetes test cluster
   Deployment · Secret · Service · NetworkPolicy · observability
        │
        ▼
Promote to production only after security/performance approval
```

## Scope and working agreement

- **Now:** create this `docker-agent/` project directory and README, with the upstream references and an implementation checklist.
- **Later:** write the `agent.yaml`, choose a model/provider, test locally, package a container runtime, push to **your Docker Hub**, and deploy to a Kubernetes **test** environment.
- Do **not** enable cluster writes, shell execution, Docker socket mounts, or unreviewed third-party MCP tools by default.
- Keep this project **independent** of the existing Hermes/Claude Code bridge until compatibility and security are tested.

## Phase 1 — Develop and test locally (planned)

### 1. Prerequisites

- Docker Desktop **4.63+** includes the `docker agent` CLI plugin; alternatives include `brew install docker-agent`, Windows Winget, or the official [GitHub releases](https://github.com/docker/docker-agent/releases).
- Choose a model path: a cloud API (OpenAI/Anthropic/Gemini), a local model through [Docker Model Runner](https://docs.docker.com/ai/model-runner/), or an approved custom OpenAI-compatible endpoint.
- Credentials must come from environment variables or a secret manager — **never from a committed YAML file**.
- GPU hardware is **not required just to run the Docker Agent orchestration CLI** when calling cloud-hosted models. A locally hosted model may need CPU/GPU resources depending on its size and latency requirements.

### 2. Proposed starter configuration

When implementation begins, save the following *illustrative, not yet tested* definition to `docker-agent/agent.yaml`. Confirm the model identifier against `docker agent models` before use. This deliberately provides **no shell, filesystem, cluster, GitHub, or MCP tool access**.

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/docker/docker-agent/main/agent-schema.json
version: 15
metadata:
  description: Read-only DevOps/SRE investigation assistant (local prototype)
  version: "0.1.0"
agents:
  root:
    model: openai/gpt-5-mini
    description: DevOps/SRE advisor
    instruction: |
      Help analyze incidents, Kubernetes events, CI/CD failures and logs
      provided by the user. Recommend safe diagnostic commands, but do
      not claim to have inspected live systems. Never change infrastructure.
    toolsets:
      - type: think
```

Proposed first-run commands, **after** the file has been created and credentials configured:

```bash
cd docker-agent
docker agent version
docker agent setup           # choose a provider or local model
docker agent doctor ./agent.yaml
docker agent run ./agent.yaml --dry-run
docker agent run ./agent.yaml --safety strict
docker agent run --exec ./agent.yaml --safety restricted "Explain a Kubernetes CrashLoopBackOff diagnostic workflow."
```

**Local test acceptance criteria**

- [ ] Pin and record a tested Docker Agent version and selected model.
- [ ] Validate schema and credentials; confirm that no secrets appear in git, output, or images.
- [ ] Verify interactive and non-interactive execution on the local machine.
- [ ] Confirm the agent cannot execute shell commands or access a live cluster with the starter configuration.
- [ ] Add small repeatable evaluation prompts (diagnosis correctness, refusal of unauthorized mutations, latency, token cost).
- [ ] Test provider/network failures and rate limits; document CPU/memory footprint.

References: [Installation](https://docs.docker.com/ai/docker-agent/getting-started/installation/), [Model setup](https://docs.docker.com/ai/docker-agent/getting-started/set-up-a-model/), [Configuration](https://docs.docker.com/ai/docker-agent/configuration/overview/), [CLI reference](https://docs.docker.com/ai/docker-agent/features/cli/).

## Phase 2 — Publish to Docker Hub (planned)

**Two different artifacts must be distinguished:**

| Artifact | Purpose | Future publishing command |
|---|---|---|
| **Agent configuration OCI artifact** | Versioned agent YAML/config that Docker Agent can pull and run | `docker agent share push` |
| **Runnable Docker/OCI container image** | Contains a pinned Docker Agent runtime and launches an API/server for Kubernetes | `docker buildx build --push` |

**Agent definition distribution**, once tested:

```bash
docker login docker.io
docker agent share push ./agent.yaml docker.io/YOUR_DOCKERHUB_USERNAME/opendevops-agent:v0.1.0
docker agent share pull docker.io/YOUR_DOCKERHUB_USERNAME/opendevops-agent:v0.1.0
docker agent run docker.io/YOUR_DOCKERHUB_USERNAME/opendevops-agent:v0.1.0 --safety strict
```

**Runnable container image**, once a reviewed `Dockerfile` exists (not included yet):

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t docker.io/YOUR_DOCKERHUB_USERNAME/opendevops-agent-runtime:v0.1.0 \
  --push .
```

Never assume that an artifact from `docker agent share push` can be used directly as a Kubernetes Pod's `image:`; design and publish a **runnable runtime image** separately. Before publishing, scan the image (e.g. Trivy), generate an SBOM, pin base image/runtime versions, avoid baked credentials, and use immutable version tags or digests. Confirm that the image supports the required platform architectures.

See [Agent distribution](https://docs.docker.com/ai/docker-agent/concepts/distribution/).

## Phase 3 — Kubernetes test deployment (planned)

Decide whether the Kubernetes entry point will be:

1. `docker agent serve chat` — an **OpenAI-compatible chat completion API** (useful for gateways/clients); or
2. `docker agent serve api` — Docker Agent's native HTTP API.

Both are documented by Docker, but the endpoint, flags, health-check routes, state storage, and authentication must be tested against the exact pinned Docker Agent release **before** writing manifests. In particular, server modes default to loopback listening; a Kubernetes Service requires deliberate Pod-network binding and authentication.

**Expected files when this phase begins** (not created yet):

```text
docker-agent/
├── README.md
├── agent.yaml
├── Dockerfile
├── .dockerignore
├── tests/
└── kubernetes/
    ├── namespace.yaml
    ├── deployment.yaml
    ├── service.yaml
    ├── networkpolicy.yaml
    └── README.md
```

**Deployment and security acceptance criteria**

- [ ] Start with a single replica in a dedicated namespace in **test**, not production.
- [ ] Pin the runtime image and agent config by digest/immutable version; roll out with controlled updates.
- [ ] Enforce non-root UID, `allowPrivilegeEscalation: false`, dropped Linux capabilities, seccomp `RuntimeDefault`, appropriate read-only filesystem/volumes, and resource requests/limits.
- [ ] No privileged mode, host networking, hostPath Docker socket, Kubernetes service-account token mounting, or cluster-admin permissions.
- [ ] Disable service-account token auto-mount by default; add **read-only**, namespace-scoped RBAC only if a future tool truly requires the Kubernetes API.
- [ ] Use Kubernetes Secrets or workload identity for model-provider credentials; restrict egress to approved providers/MCP services.
- [ ] Require authenticated API access and TLS via approved ingress/gateway; keep the service internal until reviewed.
- [ ] Review readiness/liveness strategy against real endpoints and confirm persistent/session-storage behavior (the API server can use SQLite, which affects multi-replica designs).
- [ ] Verify safe tool approval settings, prompt-injection resistance, audit logs and alerts, latency, scaling and rollback.
- [ ] Do not auto-install untrusted runtime tools or permit arbitrary shell/host access in production.

Documentation: [CLI: API & chat server](https://docs.docker.com/ai/docker-agent/features/cli/), [Headless runs](https://docs.docker.com/ai/docker-agent/guides/headless/).

## Definition of done

| Milestone | Status |
|---|---|
| Create project directory and link it in OpenDevOps | ✅ |
| Design `agent.yaml` with approved model and tools | ⬜ Planned |
| Build and test locally | ⬜ Planned |
| Push tested agent OCI artifact to Docker Hub | ⬜ Planned |
| Build, scan, and push runtime container image | ⬜ Planned |
| Deploy to Kubernetes test cluster and validate | ⬜ Planned |
| Security review and production promotion | ⬜ Planned |

**Decisions to confirm when we begin:** Docker Hub username/repository, local machine OS and architecture, provider/local model, Kubernetes distribution or cluster (GKE, EKS, or local), and whether the exposed API should be Docker Agent native or OpenAI-compatible.

---

[← OpenDevOps home](../README.md) · [Docker Agent official docs](https://docs.docker.com/ai/docker-agent/) · [Upstream GitHub](https://github.com/docker/docker-agent)
