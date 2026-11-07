# Dashboard Hermes + herdr: a thin layer on top of the OpenShell Hermes image (sandbox/hermes), so the Hermes in the
# dashboard can use herdr (terminal workspace manager) through the read-only herdr-operator skill.
# herdr runs INSIDE the OpenShell sandbox: same Landlock/seccomp/uid 10000, same network policy, no Docker socket.
# Build from the repository root:
#   docker buildx build --load -f sandbox/k8s/gke/herdr/Dockerfile \
#     --build-arg BASE_IMAGE=$R/hermes-openshell:v0.23.0 -t $R/hermes-openshell:v0.23.0-herdr0.9.5 .
ARG BASE_IMAGE=hermes-openshell:v0.23.0
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

ARG HERDR_VERSION=0.9.5
# SHA-256 of herdr-linux-x86_64 v0.9.5 (same pin as herdr/hermes-herdr/Dockerfile).
ARG HERDR_SHA256=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d

USER root
SHELL ["/bin/sh", "-eu", "-c"]
# jq: the skill's commands parse herdr's JSON output.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends jq && rm -rf /var/lib/apt/lists/* && \
    mkdir -p /usr/local/libexec/herdr /usr/local/lib/herdr-allowlist && \
    curl -fsSL -o /usr/local/libexec/herdr/herdr \
      "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-x86_64" && \
    echo "${HERDR_SHA256}  /usr/local/libexec/herdr/herdr" | sha256sum -c - && chmod 0755 /usr/local/libexec/herdr/herdr && \
    mkdir -p /work && ln -s /sandbox/hermes/workspace /work/workspace
# /work/workspace: the skill's pane working directory, pointing into the sandbox workspace (no new writable path).

# Managed ("administrator") config: root-owned, Hermes refuses to change these keys at runtime.
COPY sandbox/k8s/gke/herdr/hermes-managed.yaml /etc/hermes/config.yaml
# The one herdr skill: the herdr-hermes POC skill with the same rules, worded for the sandbox (no workbench);
# root-owned and read-only.
COPY sandbox/k8s/gke/herdr/skills/herdr-operator /opt/hermes-sandbox/skills/herdr-operator
COPY --chmod=0755 sandbox/k8s/gke/herdr/start-hermes-herdr.sh /usr/local/bin/start-hermes-herdr
# `herdr` on PATH is an exact-argv allowlist (pane operations only) in front of the real binary in libexec. The
# allowlist is the herdr-hermes POC's herdr-broker, unchanged (one script for both). Defence in depth: the herdr
# server runs as the same uid 10000, so the OpenShell sandbox stays the security boundary.
COPY --chmod=0755 sandbox/k8s/gke/herdr/herdr-allowlist /usr/local/bin/herdr
COPY --chmod=0644 herdr/hermes-herdr/work/herdr-broker /usr/local/lib/herdr-allowlist/herdr-broker
RUN chown -R root:root /etc/hermes/config.yaml /opt/hermes-sandbox/skills /usr/local/bin/herdr /usr/local/lib/herdr-allowlist \
      /usr/local/libexec/herdr && chmod 0644 /etc/hermes/config.yaml && \
    find /opt/hermes-sandbox/skills -type d -exec chmod 0755 {} + && \
    find /opt/hermes-sandbox/skills -type f -exec chmod 0644 {} +

ENV SHELL=/bin/bash
USER hermes
