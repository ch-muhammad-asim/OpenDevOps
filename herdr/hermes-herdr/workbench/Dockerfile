# hermes-workbench: where Hermes's terminal and file tools run (Hermes `terminal.backend: ssh`).
# Non-root key-only sshd on the internal network, no internet, no secrets. /work is part of the read-only root
# filesystem; only /work/workspace (volume) and /var/lib/workbench (keys, volume) are writable by `worker`.
# `herdr` here is a client for herdr-broker in hermes-herdr-work; the real herdr binary is not in this image.
# Hermes itself (and the herdr server that hosts its own pane and approval prompt) lives in herdr-hermes.
FROM alpine:3.24.2

# `apk upgrade` applies this Alpine release's security fixes at build time.
# hadolint ignore=DL3018
RUN apk upgrade --no-cache && \
    apk add --no-cache bash openssh-server openssh-sftp-server openssh-client coreutils procps grep sed findutils jq && \
    adduser -D -h /work -s /bin/bash -u 10000 worker && \
    # a locked password ("!") makes sshd refuse even key logins; "*" = no password, not locked
    sed -i 's/^worker:!/worker:*/' /etc/shadow && \
    mkdir -p /etc/workbench /work/workspace /var/lib/workbench /ctlkeys && \
    chown root:root /work && chmod 0755 /work && \
    chown worker:worker /work/workspace /var/lib/workbench /ctlkeys && chmod 0700 /var/lib/workbench

COPY sshd_config /etc/workbench/sshd_config
COPY entrypoint.sh /usr/local/bin/hermes-workbench
COPY herdr /usr/local/bin/herdr
RUN chmod 0644 /etc/workbench/sshd_config && chmod 0755 /usr/local/bin/hermes-workbench /usr/local/bin/herdr

ENV HOME=/work LANG=C.UTF-8 TERM=xterm-256color
USER worker
WORKDIR /work/workspace
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
  CMD pgrep -x sshd >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/hermes-workbench"]
