# hermes-herdr-egress: the only way out of the POC's internal network. tinyproxy allows HTTPS CONNECT to the
# hosts in allowlist (the NVIDIA model API) and refuses everything else. Runs as nobody, no ports published.
FROM alpine:3.24.2

# `apk upgrade` applies this Alpine release's security fixes at build time.
# hadolint ignore=DL3018
RUN apk upgrade --no-cache && apk add --no-cache tinyproxy

COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY allowlist /etc/tinyproxy/allowlist
RUN chmod 0644 /etc/tinyproxy/tinyproxy.conf /etc/tinyproxy/allowlist

USER nobody
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD nc -z 127.0.0.1 8888 || exit 1
ENTRYPOINT ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
