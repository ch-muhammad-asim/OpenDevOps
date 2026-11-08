"""python-inventory: a small FastAPI inventory service with planted bugs for tracing demos.

Tracing is zero-code: `opentelemetry-instrument` (see Dockerfile) patches FastAPI and
sqlite3 before this module is imported. This file only uses the OpenTelemetry API to add
a few manual spans, attributes and events where they make a trace easier to read.
"""

import asyncio
import os
import sqlite3
import time
from contextlib import asynccontextmanager, closing

from fastapi import FastAPI, Query, Request
from fastapi.responses import JSONResponse
from opentelemetry import trace

DB_PATH = os.getenv("INVENTORY_DB_PATH", "/tmp/inventory.db")
SUPPLIER_SYNC_SECONDS = float(os.getenv("SUPPLIER_SYNC_SECONDS", "3"))
FIB_MAX_N = 35

tracer = trace.get_tracer("python-inventory")

# Item cache, filled once at startup and used by GET /inventory/items/{sku}.
CATALOG: dict[str, dict] = {}


def connect() -> sqlite3.Connection:
    # Run queries through conn.cursor(): the sqlite3 instrumentation traces cursor.execute(),
    # not the sqlite3-only shortcut conn.execute().
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def seed() -> None:
    """Create a fresh database with SKU-001..SKU-020 and fill the item cache."""
    rows = [
        (f"SKU-{i:03d}", f"Widget {i}", 5 + (i * 7) % 40, round(2.5 * i, 2))
        for i in range(1, 21)
    ]
    with tracer.start_as_current_span("inventory.seed") as span, closing(connect()) as conn:
        cur = conn.cursor()
        cur.execute("DROP TABLE IF EXISTS items")
        cur.execute(
            "CREATE TABLE items (id INTEGER PRIMARY KEY, sku TEXT UNIQUE NOT NULL,"
            " name TEXT NOT NULL, quantity INTEGER NOT NULL, price REAL NOT NULL)"
        )
        cur.executemany("INSERT INTO items (sku, name, quantity, price) VALUES (?, ?, ?, ?)", rows)
        conn.commit()
        CATALOG.clear()
        for row in cur.execute("SELECT sku, name, quantity, price FROM items"):
            CATALOG[row["sku"]] = dict(row)
        span.set_attribute("app.items.count", len(CATALOG))


@asynccontextmanager
async def lifespan(_: FastAPI):
    seed()
    yield


app = FastAPI(title="python-inventory", version="1.0.3", lifespan=lifespan)


SVC = 'resource.service.name = "python-inventory"'
INDEX = {
    "service": "python-inventory",
    "description": "FastAPI inventory API on SQLite with planted bugs, traced with OpenTelemetry.",
    "tempo": "Grafana > Explore > Tempo: paste a TraceQL query below.",
    "endpoints": [
        {"method": "GET", "path": "/inventory/items", "issue": "None: healthy baseline, one SQL query",
         "traceql": f'{{ {SVC} && span.http.route = "/inventory/items" }} >> {{ span.db.system = "sqlite" }} | count() = 1'},
        {"method": "GET", "path": "/inventory/items/SKU-999", "issue": "Unhandled exception: KeyError for an unknown SKU, 500",
         "traceql": f'{{ {SVC} && event.exception.type = "KeyError" }}'},
        {"method": "GET", "path": "/inventory/report", "issue": "N+1 SQL: one SELECT per item (21 db spans)",
         "traceql": f'{{ {SVC} && kind = server }} >> {{ span.db.system = "sqlite" }} | count() > 10'},
        {"method": "GET", "path": "/inventory/slow", "issue": "Slow endpoint: legacy supplier sync takes ~3 s",
         "traceql": f'{{ {SVC} && name = "legacy_supplier_sync" && span:duration > 2s }}'},
        {"method": "GET", "path": "/inventory/fib?n=30", "issue": "CPU hog: recursive fib blocks the event loop (try n=35)",
         "traceql": f'{{ {SVC} && span.http.route = "/inventory/fib" && span:duration > 150ms }}'},
        {"method": "GET", "path": "/stress/cpu?ms=500", "issue": "Stress test (off unless STRESS_ENABLED=true, in-cluster only): bounded busy loop",
         "traceql": f'{{ {SVC} && name = "stress.cpu" }}'},
        {"method": "GET", "path": "/stress/memory?mb=32&hold_s=5", "issue": "Stress test (off unless STRESS_ENABLED=true, in-cluster only): hold MiB then release",
         "traceql": f'{{ {SVC} && name = "stress.memory" }}'},
        {"method": "GET", "path": "/healthz", "issue": "None: probe endpoint, not traced", "traceql": None},
    ],
}


@app.get("/")
def index() -> dict:
    """Self-description: endpoints, the issue each demonstrates and the TraceQL that finds it."""
    return INDEX


@app.get("/healthz")
def healthz() -> dict:
    return {"status": "ok"}


@app.get("/inventory/items")
def list_items() -> list[dict]:
    """Healthy baseline: one query returns every item."""
    with closing(connect()) as conn:
        cur = conn.cursor()
        return [dict(r) for r in cur.execute("SELECT sku, name, quantity, price FROM items ORDER BY sku")]


@app.get("/inventory/items/{sku}")
def get_item(sku: str) -> dict:
    span = trace.get_current_span()
    span.set_attribute("app.item.sku", sku)
    # PLANTED ISSUE: unhandled KeyError for an unknown SKU (e.g. SKU-999) -> HTTP 500.
    # Fix: item = CATALOG.get(sku); if item is None: raise HTTPException(404, "unknown sku").
    item = CATALOG[sku]
    return item


@app.get("/inventory/report")
def stock_report() -> dict:
    """Stock value per item."""
    with tracer.start_as_current_span("inventory.report.build") as span, closing(connect()) as conn:
        cur = conn.cursor()
        ids = [r["id"] for r in cur.execute("SELECT id FROM items ORDER BY id")]
        span.set_attribute("app.items.count", len(ids))
        lines = []
        # PLANTED ISSUE: N+1 queries - one SELECT per item inside the loop (21 queries for 20 items).
        # Fix: one query, e.g. SELECT sku, quantity, quantity * price AS value FROM items.
        for item_id in ids:
            row = cur.execute("SELECT sku, quantity, price FROM items WHERE id = ?", (item_id,)).fetchone()
            lines.append({"sku": row["sku"], "quantity": row["quantity"], "value": round(row["quantity"] * row["price"], 2)})
        span.add_event("report.built", {"app.report.lines": len(lines)})
        return {"items": lines, "total_value": round(sum(line["value"] for line in lines), 2)}


def legacy_supplier_sync() -> int:
    """Refresh supplier stock levels before answering (legacy behaviour)."""
    with tracer.start_as_current_span("legacy_supplier_sync") as span:
        span.set_attribute("app.supplier.name", "legacy-erp")
        span.add_event("supplier.lock.wait")
        # PLANTED ISSUE: a synchronous supplier sync holds the request for ~3 s (simulated lock wait).
        # Fix: run the sync as a background job and serve the cached stock levels here.
        time.sleep(SUPPLIER_SYNC_SECONDS)
        span.add_event("supplier.lock.acquired")
        with closing(connect()) as conn:
            cur = conn.cursor()
            return cur.execute("SELECT COUNT(*) FROM items WHERE quantity < 10").fetchone()[0]


@app.get("/inventory/slow")
def low_stock() -> dict:
    low = legacy_supplier_sync()
    return {"low_stock_items": low}


def fib(n: int) -> int:
    return n if n < 2 else fib(n - 1) + fib(n - 2)


@app.get("/inventory/fib")
async def forecast(n: int = Query(30, ge=0)) -> dict:
    n = min(n, FIB_MAX_N)
    trace.get_current_span().set_attribute("app.fib.n", n)
    # PLANTED ISSUE: exponential recursive fib runs on the event loop inside an `async def`
    # route, so it burns CPU and blocks every other request (even /healthz) until it ends.
    # Fix: use an iterative or memoised fib, and run CPU-bound work off the event loop.
    return {"n": n, "value": fib(n)}


# ---------------------------------------------------------------------------
# Stress endpoints (tests/): bounded CPU and memory load for resource tests. OFF unless
# STRESS_ENABLED=true; caps come from env; requests that came through Traefik (any
# X-Forwarded-For header) get 404, so they answer in-cluster callers only.
# ---------------------------------------------------------------------------
STRESS_ENABLED = os.getenv("STRESS_ENABLED", "false") == "true"
STRESS_MAX_CPU_MS = int(os.getenv("STRESS_MAX_CPU_MS", "5000"))
STRESS_MAX_MB = int(os.getenv("STRESS_MAX_MB", "128"))  # total MiB held at once, all requests
STRESS_MAX_HOLD_S = int(os.getenv("STRESS_MAX_HOLD_S", "30"))
_stress_held_mb = 0
NOT_FOUND = {"detail": "Not Found"}


def _stress_allowed(request: Request) -> bool:
    return STRESS_ENABLED and "x-forwarded-for" not in request.headers


@app.get("/stress/cpu")
def stress_cpu(request: Request, ms: int = Query(200, ge=0)):
    """Busy loop for ms (capped). Sync route: runs in the threadpool, but still holds the GIL."""
    if not _stress_allowed(request):
        return JSONResponse(NOT_FOUND, status_code=404)
    ms = min(ms, STRESS_MAX_CPU_MS)
    with tracer.start_as_current_span("stress.cpu") as span:
        span.set_attribute("app.stress.cpu.ms", ms)
        end = time.perf_counter() + ms / 1000
        rounds = 0
        while time.perf_counter() < end:
            sum(i * i for i in range(1000))
            rounds += 1
        span.set_attribute("app.stress.cpu.rounds", rounds)
    return {"ms": ms, "rounds": rounds}


@app.get("/stress/memory")
async def stress_memory(request: Request, mb: int = Query(32, ge=0), hold_s: int = Query(5, ge=0)):
    """Allocate mb MiB (capped, budget shared by all requests), hold hold_s seconds, release."""
    global _stress_held_mb
    if not _stress_allowed(request):
        return JSONResponse(NOT_FOUND, status_code=404)
    mb, hold_s = min(mb, STRESS_MAX_MB), min(hold_s, STRESS_MAX_HOLD_S)
    with tracer.start_as_current_span("stress.memory") as span:
        span.set_attributes({"app.stress.memory.mb": mb, "app.stress.memory.hold_s": hold_s})
        if _stress_held_mb + mb > STRESS_MAX_MB:
            span.set_attribute("app.stress.memory.rejected", True)
            return JSONResponse(
                {"error": "stress memory budget in use", "held_mb": _stress_held_mb, "max_mb": STRESS_MAX_MB},
                status_code=429,
            )
        _stress_held_mb += mb
        try:
            block = bytearray(b"\x01") * (mb * 1024 * 1024)  # filled, so every page is resident
            span.add_event("memory.allocated", {"app.stress.memory.held_mb": _stress_held_mb})
            await asyncio.sleep(hold_s)
            del block
            span.add_event("memory.released")
        finally:
            _stress_held_mb -= mb
    return {"mb": mb, "hold_s": hold_s}


def close_connection_on_5xx(asgi_app):
    """Ask clients to drop the keep-alive connection after a 5xx response.

    After an unhandled exception uvicorn closes the socket without telling the client, so a
    keep-alive caller (nodejs-orders' fetch pool) may reuse the dead socket for its next
    request and fail with "fetch failed". Sending `connection: close` keeps the planted
    500 contained to the request that caused it.
    """

    async def wrapped(scope, receive, send):
        async def send_with_close(message):
            if message["type"] == "http.response.start" and message["status"] >= 500:
                headers = [h for h in message.get("headers", []) if h[0].lower() != b"connection"]
                message = {**message, "headers": [*headers, (b"connection", b"close")]}
            await send(message)

        await asgi_app(scope, receive, send_with_close if scope["type"] == "http" else send)

    return wrapped


# ASGI entry point served by uvicorn (see Dockerfile): the traced FastAPI app plus the wrapper.
asgi = close_connection_on_5xx(app)
