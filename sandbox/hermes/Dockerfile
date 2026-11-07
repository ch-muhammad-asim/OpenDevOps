# Hermes Agent, adapted to run as an OpenShell sandbox workload.
#
# OpenShell replaces the image ENTRYPOINT (s6-overlay /init) with its own
# supervisor and refuses root workloads, so this image:
#   - runs as the image's existing `hermes` user (uid/gid 10000),
#   - moves HERMES_HOME into the /sandbox workspace,
#   - ships start-hermes, which runs the dashboard + gateway that s6 would
#     normally supervise. Pass it after `--` in `openshell sandbox create`.
ARG HERMES_IMAGE=nousresearch/hermes-agent:v0.23.0
# The tag is pinned through the ARG above, which hadolint can't see.
# hadolint ignore=DL3006
FROM ${HERMES_IMAGE}

COPY --chmod=0755 start-hermes.sh /usr/local/bin/start-hermes
COPY config.yaml /opt/hermes-sandbox/config.yaml

# `COPY --chmod` would also apply the file mode to the new directory, so set
# modes explicitly. Pre-create HERMES_HOME owned by hermes so a fresh named
# volume mounted there inherits that ownership on first use.
RUN chmod 0755 /opt/hermes-sandbox && chmod 0644 /opt/hermes-sandbox/config.yaml && \
    mkdir -p /sandbox/hermes && chown -R hermes:hermes /sandbox

ENV HERMES_HOME=/sandbox/hermes \
    HERMES_WRITE_SAFE_ROOT=/sandbox/hermes \
    HOME=/sandbox/hermes \
    PATH=/opt/hermes/bin:/opt/hermes/.venv/bin:/sandbox/hermes/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

USER hermes
WORKDIR /sandbox
