# herdr-hermes: herdr (terminal workspace manager for AI agents) + Hermes Agent in one hardened container.
# herdr runs as the main process; the Hermes CLI runs as the foreground process of a herdr pane, so herdr
# recognises it as agent kind `hermes` and can prompt it, read it and see when it is blocked on an approval.
# No OpenShell here: protection comes from Hermes's own guardrails (config.yaml) and the container settings
# in docker-compose.yml. Same image is meant for Kubernetes later (README "Run on GKE later").
ARG HERMES_IMAGE=nousresearch/hermes-agent:v0.23.0
# The tag is pinned through the ARG above, which hadolint can't see.
# hadolint ignore=DL3006
FROM ${HERMES_IMAGE}

ARG HERDR_VERSION=0.9.5
# SHA-256 of herdr-linux-x86_64 v0.9.5 from https://herdr.dev/latest.json (same value as the release manifest).
ARG HERDR_SHA256=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d

USER root
SHELL ["/bin/sh", "-eu", "-c"]
# ssh/scp: Hermes's ssh terminal backend (commands run in hermes-workbench). The hermes user's home moves to the
# /data volume because OpenSSH reads ~/.ssh (known_hosts) from the passwd home, and the rootfs is read-only.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends openssh-client bash && \
    rm -rf /var/lib/apt/lists/* && \
    usermod -d /data/home hermes
# Pinned, checksum-verified herdr binary; /data is the only writable path at runtime (named volume).
RUN curl -fsSL -o /usr/local/bin/herdr \
      "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-x86_64" && \
    echo "${HERDR_SHA256}  /usr/local/bin/herdr" | sha256sum -c - && \
    chmod 0755 /usr/local/bin/herdr && \
    mkdir -p /opt/hermes-herdr /data /keys /work/workspace && chown hermes:hermes /data /keys && \
    chmod 0750 /data && chmod 0755 /keys
# /work/workspace exists here only so Hermes's local cwd check passes; commands run in hermes-workbench.

COPY entrypoint.sh /usr/local/bin/herdr-hermes
COPY hermes-shim /opt/hermes-herdr/bin/hermes
COPY hermes-herdr-up.sh /usr/local/bin/hermes-herdr-up
COPY config.yaml /opt/hermes-herdr/config.yaml
# Managed (administrator) config: root-owned on a read-only rootfs, so the agent cannot relax its guardrails.
COPY hermes-managed.yaml /etc/hermes/config.yaml
# The one installed skill (root-owned, read-only; skill create/edit tools stay disabled) and herdr's pinned
# detection rules for this Hermes version.
COPY skills /opt/hermes-herdr/skills
COPY herdr-agent-detection /opt/hermes-herdr/herdr-agent-detection
RUN mkdir -p /opt/hermes-herdr/no-bundled-skills && \
    chmod 0755 /usr/local/bin/herdr-hermes /usr/local/bin/hermes-herdr-up /opt/hermes-herdr /etc/hermes \
      /opt/hermes-herdr/bin /opt/hermes-herdr/bin/hermes /opt/hermes-herdr/no-bundled-skills && \
    chmod 0644 /opt/hermes-herdr/config.yaml /etc/hermes/config.yaml && \
    chown -R root:root /etc/hermes /opt/hermes-herdr && \
    find /opt/hermes-herdr/skills /opt/hermes-herdr/herdr-agent-detection -type d -exec chmod 0755 {} + && \
    find /opt/hermes-herdr/skills /opt/hermes-herdr/herdr-agent-detection -type f -exec chmod 0644 {} +
# The profile config's _config_version must match this Hermes release (no migration prompt at start): take it from
# the base image's own defaults, so one config.yaml serves every pinned Hermes version.
RUN v="$(/opt/hermes/.venv/bin/python -c 'from hermes_cli.config_defaults import DEFAULT_CONFIG as d; print(d["_config_version"])')" && \
    sed -i "s/^_config_version: .*/_config_version: ${v}/" /opt/hermes-herdr/config.yaml && \
    grep -q "^_config_version: ${v}$" /opt/hermes-herdr/config.yaml

# HOME (herdr socket + state) and HERMES_HOME (Hermes config, sessions, memory) live on the /data volume;
# the root filesystem is mounted read-only by docker-compose.yml. HERMES_BUNDLED_SKILLS points at an empty dir so
# Hermes seeds none of its bundled skills; /opt/hermes-herdr/bin/hermes loads the model key (hermes-shim).
ENV HOME=/data/home \
    HERMES_HOME=/data/hermes \
    HERMES_WRITE_SAFE_ROOT=/work/workspace \
    HERMES_BUNDLED_SKILLS=/opt/hermes-herdr/no-bundled-skills \
    HERMES_MANAGED_DIR=/etc/hermes \
    SHELL=/bin/sh \
    TERM=xterm-256color \
    COLORTERM=truecolor \
    LANG=C.UTF-8 \
    PATH=/opt/hermes-herdr/bin:/opt/hermes/bin:/opt/hermes/.venv/bin:/usr/local/bin:/usr/bin:/bin

USER hermes
WORKDIR /data
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD herdr status 2>/dev/null | grep -q 'status: running' || exit 1
ENTRYPOINT ["/usr/local/bin/herdr-hermes"]
