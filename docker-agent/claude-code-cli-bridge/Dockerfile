FROM --platform=$BUILDPLATFORM alpine:3.22 AS fetch
ARG TARGETARCH
ARG CLAUDE_CODE_VERSION=2.1.302
ARG CLAUDE_SHA256_amd64=60d7eb7f12fbb28a52533fe8be5884097403562aa02dc73991a021c7067e29a5
ARG CLAUDE_SHA256_arm64=2bd4f4e5ed5cb09955b490098f745321cb5491e7ea8c752ba1e3bb010cdadb10
RUN apk add --no-cache curl \
 && CLAUDE_ARCH=$([ "$TARGETARCH" = amd64 ] && echo x64 || echo arm64) \
 && curl -fsSLo /claude "https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}/linux-${CLAUDE_ARCH}/claude" \
 && eval "echo \"\${CLAUDE_SHA256_${TARGETARCH}}  /claude\"" | sha256sum -c - \
 && chmod 0755 /claude

# glibc + python3: the claude binary is dynamically linked, the bridge and its MCP shim are Python
FROM gcr.io/distroless/python3-debian12:nonroot
COPY --from=fetch /claude /usr/local/bin/claude
COPY claude-code-cli-bridge/claude_native_bridge.py claude-code-cli-bridge/mcp_shim.py /app/
COPY claude-code-cli-bridge/managed-settings.json /etc/claude-code/managed-settings.json
ENV HOME=/home/nonroot \
    CLAUDE_CONFIG_DIR=/home/nonroot/.claude \
    CLAUDE_BIN=/usr/local/bin/claude \
    PYTHON_BIN=/usr/bin/python3 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_TELEMETRY=1 \
    DISABLE_ERROR_REPORTING=1 \
    CLAUDE_CODE_ALLOWED_TOOLS=""
WORKDIR /home/nonroot
USER nonroot:nonroot
EXPOSE 18188
ENTRYPOINT ["/usr/bin/python3", "/app/claude_native_bridge.py"]
# Loopback only: in Kubernetes the agent container reaches it over the shared Pod network namespace
CMD ["--host", "127.0.0.1", "--port", "18188", "--model", "claude-haiku-4-5", "--models", "claude-haiku-4-5", \
     "--effort", "low", "--cwd", "/home/nonroot", "--max-sessions", "4"]
