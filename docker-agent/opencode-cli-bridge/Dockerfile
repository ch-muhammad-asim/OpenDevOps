FROM --platform=$BUILDPLATFORM alpine:3.22 AS fetch
ARG TARGETARCH
ARG OPENCODE_VERSION=v1.19.3
ARG OPENCODE_SHA256_amd64=13a8fb2978302071b86f9d7e00da9c8895f9cd846978379c3bdc6a5333536c9b
ARG OPENCODE_SHA256_arm64=7900818a6a98881edbbadab4b7525940eff3b9750040c200481f9f56cacee405
RUN apk add --no-cache curl \
 && OC_ARCH=$([ "$TARGETARCH" = amd64 ] && echo x64 || echo arm64) \
 && curl -fsSLo /oc.tgz "https://github.com/sst/opencode/releases/download/${OPENCODE_VERSION}/opencode-linux-${OC_ARCH}.tar.gz" \
 && eval "echo \"\${OPENCODE_SHA256_${TARGETARCH}}  /oc.tgz\"" | sha256sum -c - \
 && tar -xzf /oc.tgz -C / opencode \
 && chmod 0755 /opencode \
 && mkdir -p /workspace

# glibc + python3: the opencode binary is dynamically linked, the bridge is stdlib-only Python
FROM gcr.io/distroless/python3-debian12:nonroot
COPY --from=fetch /opencode /usr/local/bin/opencode
COPY opencode-cli-bridge/opencode_bridge.py /app/opencode_bridge.py
# Tool policy: only read-only tools confined to the empty workspace; bash/edit/write/patch/web/task denied
# ("deny" removes the tool). The free tier rejects requests with NO tools, so a fully empty policy is not an option.
COPY opencode-cli-bridge/opencode.json /etc/opencode/opencode.json
# Dedicated EMPTY workspace: the only directory OpenCode's read-only tools may touch (external_directory: deny)
COPY --from=fetch --chown=65532:65532 /workspace /home/nonroot/workspace
ENV HOME=/home/nonroot \
    XDG_CONFIG_HOME=/home/nonroot/.config \
    XDG_DATA_HOME=/home/nonroot/.local/share \
    XDG_CACHE_HOME=/home/nonroot/.cache \
    XDG_STATE_HOME=/home/nonroot/.local/state \
    OPENCODE_CONFIG=/etc/opencode/opencode.json \
    OPENCODE_BIN=/usr/local/bin/opencode \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
WORKDIR /home/nonroot
USER nonroot:nonroot
EXPOSE 18387
ENTRYPOINT ["/usr/bin/python3", "/app/opencode_bridge.py"]
# Loopback by default (sidecar-safe); compose.yaml overrides --host so the agent service can reach it
# --max-images 0: text only, so the bridge never reads attachment files/URLs before OpenCode's policy applies
CMD ["--host", "127.0.0.1", "--port", "18387", "--model", "opencode/mimo-v2.6-flash-free", "--free-only", \
     "--cwd", "/home/nonroot/workspace", "--max-images", "0", "--max-concurrency", "2", "--timeout", "180"]
