# python-inventory: FastAPI + uvicorn, traced with OpenTelemetry zero-code instrumentation.
ARG PYTHON_IMAGE=python:3.14.10-slim-trixie@sha256:af8a5aa14780025dbfbcfbc81bd8a91ebd87711dd5b0f48ed71090949dd7cb1d

# --- build: install pinned wheels into a virtualenv ---
FROM ${PYTHON_IMAGE} AS build
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
RUN python -m venv /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --only-binary=:all: -r /tmp/requirements.txt \
 && /opt/venv/bin/pip uninstall -y pip
COPY main.py /app/main.py
RUN python -m compileall -q /app /opt/venv

# --- runtime: venv + app only, non-root ---
FROM ${PYTHON_IMAGE}
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app
COPY --from=build /opt/venv /opt/venv
COPY --from=build /app /app
WORKDIR /app
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    INVENTORY_DB_PATH=/tmp/inventory.db \
    OTEL_SERVICE_NAME=python-inventory \
    OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    OTEL_TRACES_EXPORTER=otlp \
    OTEL_METRICS_EXPORTER=none \
    OTEL_LOGS_EXPORTER=none \
    OTEL_TRACES_SAMPLER=parentbased_always_on \
    OTEL_PYTHON_EXCLUDED_URLS=healthz
USER 10001:10001
EXPOSE 8000
# opentelemetry-instrument loads the installed instrumentations (fastapi, sqlite3) before the app starts.
CMD ["opentelemetry-instrument", "uvicorn", "main:asgi", "--host", "0.0.0.0", "--port", "8000", "--no-server-header"]
