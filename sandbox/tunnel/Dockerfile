# OpenShell CLI only: holds the port forwards into the Hermes sandbox so
# Traefik can reach Hermes's built-in dashboard (9119) and API (8642).
# No web server in here; Traefik talks to the forwarded ports directly.
FROM alpine:3.24.2

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ARG OPENSHELL_VERSION=0.1.6
WORKDIR /tmp/openshell-dl
# Real lsof: `openshell forward` asks lsof whether the port is free, and
# BusyBox's lsof ignores its arguments, so every port looks taken.
# `apk upgrade` applies this Alpine release's security fixes at build time.
# curl stays: the health loop probes the forwards with real WebSocket upgrades.
# hadolint ignore=DL3018
RUN apk upgrade --no-cache && \
    apk add --no-cache openssh-client lsof curl && \
    base="https://github.com/NVIDIA/OpenShell/releases/download/v${OPENSHELL_VERSION}" && \
    curl -fsSLO "$base/openshell-x86_64-unknown-linux-musl.tar.gz" && \
    curl -fsSLO "$base/openshell-checksums-sha256.txt" && \
    grep " openshell-x86_64-unknown-linux-musl.tar.gz$" openshell-checksums-sha256.txt | sha256sum -c - && \
    tar -xzf openshell-x86_64-unknown-linux-musl.tar.gz && \
    install -m 0755 openshell /usr/local/bin/openshell && \
    rm -rf /tmp/openshell-dl && \
    adduser -D -H -u 10001 tunnel
WORKDIR /

COPY --chmod=0755 entrypoint.sh /usr/local/bin/hermes-tunnel

USER tunnel
EXPOSE 9119 8642
ENTRYPOINT ["/usr/local/bin/hermes-tunnel"]
