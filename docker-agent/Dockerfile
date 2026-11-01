FROM --platform=$BUILDPLATFORM alpine:3.22 AS fetch
ARG TARGETARCH
ARG DOCKER_AGENT_VERSION=v1.150.0
ARG SHA256_amd64=791fa6bac9f829847f00ab948f838bf54d11e0830988a5e5bce88d65ea65f2d1
ARG SHA256_arm64=12ae093844531a60f32c344f4afb90bc92a010ea8438a5a760b3e79f8e81c8e7
ARG K8S_MCP_VERSION=v0.0.67
ARG K8S_MCP_SHA256_amd64=d791c22b5367813cc9e7c66e405d8ff7f7d51189b5bd619fdd84a99cf7a1c116
ARG K8S_MCP_SHA256_arm64=d9378039b68b5247796655ba8bbb210d5e94287e56bd532112d81950a19f0e50
RUN apk add --no-cache curl \
 && curl -fsSLo /docker-agent "https://github.com/docker/docker-agent/releases/download/${DOCKER_AGENT_VERSION}/docker-agent-linux-${TARGETARCH}" \
 && eval "echo \"\${SHA256_${TARGETARCH}}  /docker-agent\"" | sha256sum -c - \
 && curl -fsSLo /kubernetes-mcp-server "https://github.com/containers/kubernetes-mcp-server/releases/download/${K8S_MCP_VERSION}/kubernetes-mcp-server-linux-${TARGETARCH}" \
 && eval "echo \"\${K8S_MCP_SHA256_${TARGETARCH}}  /kubernetes-mcp-server\"" | sha256sum -c - \
 && chmod 0755 /docker-agent /kubernetes-mcp-server \
 && mkdir -p -m 700 /data

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=fetch /docker-agent /usr/local/bin/docker-agent
COPY --from=fetch /kubernetes-mcp-server /usr/local/bin/kubernetes-mcp-server
# Persistent agent memory (sqlite) for agent-sre.yaml; mount a volume here to keep it across restarts
COPY --from=fetch --chown=65532:65532 --chmod=0700 /data /data
COPY agent.yaml agent-sre.yaml /app/
COPY k8s-mcp/config.toml /etc/kubernetes-mcp-server/config.toml
ENV HOME=/home/nonroot \
    TELEMETRY_ENABLED=false
WORKDIR /home/nonroot
USER nonroot:nonroot
EXPOSE 8083
ENTRYPOINT ["/usr/local/bin/docker-agent"]
CMD ["serve", "chat", "/app/agent.yaml", "--listen", "0.0.0.0:8083", "--api-key-env", "AGENT_API_KEY", "--safety", "strict"]
