# 🏭 DevOps AI Factory

**Standalone project:** **[ch-muhammad-asim/devops-ai-factory](https://github.com/ch-muhammad-asim/devops-ai-factory)**

DevOps AI Factory is a separate Kubernetes-based AI infrastructure project. It combines **AWS infrastructure provisioned with Terragrunt/Terraform**, a **K3s Kubernetes platform**, and documentation for **GPU workloads, model serving, AI/LLM gateways, and MCP/agent connectivity**.

This directory is a **navigation and integration reference**, not a copy of the source repository or a Git submodule. For the latest configurations, source code, version pins, and deployment instructions, use the upstream project.

## Start here

| Topic | DevOps AI Factory guide |
|---|---|
| 📦 **Repository overview** | [devops-ai-factory README](https://github.com/ch-muhammad-asim/devops-ai-factory#readme) |
| ☁️ **AWS + K3s platform** | [Platform deployment](https://github.com/ch-muhammad-asim/devops-ai-factory/blob/main/docs/platform/README.md) |
| 🧱 **Infrastructure workflow** | [Terragrunt guide](https://github.com/ch-muhammad-asim/devops-ai-factory/blob/main/docs/terragrunt-workflow/README.md) |
| 🎛️ **GPU and inference workloads** | [Model serving, KServe, vLLM, Ray](https://github.com/ch-muhammad-asim/devops-ai-factory/blob/main/docs/ai-factory/inference-workloads.md) |
| 🌐 **LLM gateway** | [LiteLLM gateway](https://github.com/ch-muhammad-asim/devops-ai-factory/blob/main/docs/ai-factory/llm-gateway/README.md) |
| 🔀 **Agent gateway** | [AgentGateway for LLM, MCP, A2A](https://github.com/ch-muhammad-asim/devops-ai-factory/blob/main/docs/ai-factory/agent-gateway/README.md) |
| 🧩 **MCP gateway** | [ContextForge MCP gateway](https://github.com/ch-muhammad-asim/devops-ai-factory/blob/main/docs/ai-factory/mcp-gateway/README.md) |
| 📌 **Versions** | [Pinned dependencies](https://github.com/ch-muhammad-asim/devops-ai-factory/blob/main/VERSIONS.md) |

## How it relates to OpenDevOps

- **[OpenDevOps](../README.md)** provides Hermes/Claude Code agent bridges, SRE workflows, and deployment options across desktop, Docker, and Kubernetes.
- **[DevOps AI Factory](https://github.com/ch-muhammad-asim/devops-ai-factory)** focuses on the **infrastructure and AI platform**: Kubernetes, cloud resources, model serving, GPU and gateway components.

These projects are **complementary but independently deployed**. They are not automatically connected at runtime, and no source code is synchronized by this link.

To work directly with the AI Factory repository:

```bash
git clone https://github.com/ch-muhammad-asim/devops-ai-factory.git
cd devops-ai-factory
```

[← Return to OpenDevOps](../README.md) · [Open DevOps AI Factory →](https://github.com/ch-muhammad-asim/devops-ai-factory)
