# hermes-herdr-work: the herdr server for the herdr-operator skill's work panes, and the ONLY place its real herdr
# binary exists. The workbench reaches it through herdr-broker (sshd ForceCommand, exact-argv allowlist, no shell).
# Each work pane's shell is an SSH session back into hermes-workbench, so commands still run in the workbench.
# Non-root, no secrets, no internet.
FROM alpine:3.24.2

ARG HERDR_VERSION=0.9.5
ARG HERDR_SHA256=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d

# hadolint ignore=DL3018
RUN apk upgrade --no-cache && \
    apk add --no-cache openssh-server openssh-client python3 procps && \
    apk add --no-cache --virtual .dl curl && \
    curl -fsSL -o /usr/local/bin/herdr \
      "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-x86_64" && \
    echo "${HERDR_SHA256}  /usr/local/bin/herdr" | sha256sum -c - && \
    chmod 0755 /usr/local/bin/herdr && \
    apk del .dl && \
    adduser -D -h /data/home -s /bin/sh -u 10000 herdr && \
    sed -i 's/^herdr:!/herdr:*/' /etc/shadow && \
    mkdir -p /etc/herdr-work /usr/local/libexec /data /ctlkeys /panekeys /work/workspace && \
    chown herdr:herdr /data /panekeys && chmod 0700 /data

COPY sshd_config /etc/herdr-work/sshd_config
COPY herdr-broker /usr/local/libexec/herdr-broker
COPY workbench-shell /usr/local/bin/workbench-shell
COPY herdr-close-extra-panes /usr/local/bin/herdr-close-extra-panes
COPY entrypoint.sh /usr/local/bin/hermes-herdr-work
RUN chmod 0644 /etc/herdr-work/sshd_config && \
    chmod 0755 /usr/local/libexec/herdr-broker /usr/local/bin/workbench-shell /usr/local/bin/hermes-herdr-work \
      /usr/local/bin/herdr-close-extra-panes

# /work/workspace exists only because herdr checks a pane's --cwd locally; the pane shell cds there in the workbench.
ENV HOME=/data/home LANG=C.UTF-8 TERM=xterm-256color SHELL=/usr/local/bin/workbench-shell
USER herdr
WORKDIR /data
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
  CMD herdr status 2>/dev/null | grep -q 'status: running' && pgrep -x sshd >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/hermes-herdr-work"]
