# nodejs-orders: Express 5 + OpenTelemetry auto-instrumentation.

# ---- deps: install production dependencies exactly as locked ----
FROM node:26.13.0-alpine3.24@sha256:8996bb5821d62a8fd9bb27c1cb07462f3fdce6e47d640c6a881ead0b064ce216 AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
 && npm cache clean --force

# ---- runtime: app code + node_modules, no npm cache, non-root ----
FROM node:26.13.0-alpine3.24@sha256:8996bb5821d62a8fd9bb27c1cb07462f3fdce6e47d640c6a881ead0b064ce216
ENV NODE_ENV=production \
    PORT=3000 \
    OTEL_SERVICE_NAME=nodejs-orders \
    OTEL_TRACES_EXPORTER=otlp \
    OTEL_METRICS_EXPORTER=none \
    OTEL_LOGS_EXPORTER=none \
    OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    OTEL_TRACES_SAMPLER=parentbased_always_on \
    OTEL_NODE_ENABLED_INSTRUMENTATIONS=http,express,undici \
    OTEL_NODE_RESOURCE_DETECTORS=env,host,os,serviceinstance
WORKDIR /app
COPY --from=deps --chown=root:root /app/node_modules ./node_modules
COPY --chown=root:root package.json instrumentation.js server.js ./
# Numeric UID so Kubernetes runAsNonRoot can verify it; files stay root-owned (read-only).
USER 10001:10001
EXPOSE 3000
CMD ["node", "--require", "./instrumentation.js", "server.js"]
