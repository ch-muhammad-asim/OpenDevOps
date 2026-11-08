'use strict';
// nodejs-orders: a small Express 5 orders API that calls python-inventory.
// HTTP server/client spans come from auto-instrumentation (see instrumentation.js);
// this file adds manual spans, attributes and events with @opentelemetry/api.
// Five issues are planted on purpose. Each is marked `PLANTED ISSUE:` with its fix.
const crypto = require('node:crypto');
const express = require('express');
const { trace, SpanStatusCode } = require('@opentelemetry/api');

const PORT = Number(process.env.PORT || 3000);
const INVENTORY_URL = (process.env.INVENTORY_URL || 'http://python:8000').replace(/\/+$/, '');
const tracer = trace.getTracer('nodejs-orders');

// Ten demo orders. Order 7 points at SKU-999, which python-inventory fails on (HTTP 500).
const ORDERS = Array.from({ length: 10 }, (_, i) => {
  const id = i + 1;
  return {
    id,
    customer: `customer-${String(id).padStart(3, '0')}`,
    sku: id === 7 ? 'SKU-999' : `SKU-${String(id).padStart(3, '0')}`,
    quantity: (id % 4) + 1,
    status: id % 3 === 0 ? 'shipped' : 'pending',
  };
});

class UpstreamError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'UpstreamError';
    this.status = status;
  }
}

const app = express();
app.disable('x-powered-by');
app.use(express.json());

// GET /: self-description - every endpoint, the issue it demonstrates and the TraceQL that finds it.
const SVC = 'resource.service.name = "nodejs-orders"';
const INDEX = {
  service: 'nodejs-orders',
  description: 'Express 5 orders API with planted bugs, traced with OpenTelemetry. Calls python-inventory.',
  tempo: 'Grafana > Explore > Tempo: paste a TraceQL query below.',
  endpoints: [
    { method: 'GET', path: '/orders', issue: 'Memory leak: every call keeps a 1 MiB audit copy (capped at 120 MiB)',
      traceql: `{ ${SVC} && span.app.cache.bytes > 0 } | max_over_time(span.app.cache.bytes)` },
    { method: 'GET', path: '/orders/1', issue: 'None: healthy baseline (calls python for stock data)',
      traceql: `{ ${SVC} && name = "GET /orders/:id" && status != error }` },
    { method: 'GET', path: '/orders/7', issue: 'Cross-service error chain: python fails on SKU-999, nodejs answers 502',
      traceql: `{ ${SVC} && kind = server && status = error } >> { resource.service.name = "python-inventory" && status = error }` },
    { method: 'GET', path: '/orders/3/stock', issue: 'External call timeout: 2 s timeout on a 3 s python endpoint, 504',
      traceql: `{ ${SVC} && kind = client && status = error && span:duration >= 2s }` },
    { method: 'GET', path: '/orders/report', issue: 'CPU hog: synchronous crypto blocks the event loop for ~1-2 s',
      traceql: `{ ${SVC} && name = "orders.build_report" && span:duration > 1s }` },
    { method: 'POST', path: '/orders', body: '{}', issue: 'Unhandled exception: missing items -> TypeError, 500',
      traceql: `{ ${SVC} && name = "POST /orders" && status = error } && { event.exception.type = "TypeError" }` },
    { method: 'GET', path: '/stress/cpu?ms=500', issue: 'Stress test (off unless STRESS_ENABLED=true, in-cluster only): bounded busy loop',
      traceql: `{ ${SVC} && name = "stress.cpu" }` },
    { method: 'GET', path: '/stress/memory?mb=32&hold_s=5', issue: 'Stress test (off unless STRESS_ENABLED=true, in-cluster only): hold MiB then release',
      traceql: `{ ${SVC} && name = "stress.memory" }` },
    { method: 'GET', path: '/healthz', issue: 'None: probe endpoint, not traced', traceql: null },
  ],
};
app.get('/', (req, res) => {
  res.json(INDEX);
});

// Not traced: instrumentation.js tells the HTTP instrumentation to skip this path.
app.get('/healthz', (req, res) => {
  res.json({ status: 'ok' });
});

// ---------------------------------------------------------------------------
// GET /orders: list orders, and keep an "audit copy" of each response.
// ---------------------------------------------------------------------------
const RENDER_BUFFER_BYTES = 1024 * 1024; // reusable 1 MiB scratch buffer for serialising responses
const AUDIT_CACHE_MAX_BYTES = 120 * 1024 * 1024; // lab guard only: stops growth before the 256Mi limit
const renderBuffer = Buffer.alloc(RENDER_BUFFER_BYTES);
const auditCache = [];
let auditCacheBytes = 0;

app.get('/orders', (req, res) => {
  const body = JSON.stringify({ count: ORDERS.length, orders: ORDERS });
  const written = renderBuffer.write(body, 0, 'utf8');

  // PLANTED ISSUE: memory leak. Buffer.from(renderBuffer) copies the WHOLE 1 MiB scratch
  // buffer (not just the `written` bytes) into a module-level array that is never evicted,
  // so every call adds ~1 MiB to the process. Fix: do not keep per-request copies in memory
  // (send audit records to a log/queue), or keep `renderBuffer.subarray(0, written)` in a
  // bounded LRU with a TTL.
  if (auditCacheBytes + RENDER_BUFFER_BYTES <= AUDIT_CACHE_MAX_BYTES) {
    const snapshot = Buffer.from(renderBuffer);
    auditCache.push({ at: Date.now(), path: req.originalUrl, snapshot });
    auditCacheBytes += snapshot.length;
  }

  const span = trace.getActiveSpan();
  span?.setAttributes({
    'app.cache.entries': auditCache.length,
    'app.cache.bytes': auditCacheBytes,
    'app.orders.count': ORDERS.length,
  });

  res.type('application/json').send(renderBuffer.subarray(0, written));
});

// ---------------------------------------------------------------------------
// GET /orders/report: revenue report. Must be declared before /orders/:id.
// ---------------------------------------------------------------------------
const REPORT_ROUNDS = Number(process.env.REPORT_ROUNDS || 10);
const REPORT_ITERATIONS = 100000;

app.get('/orders/report', (req, res) => {
  const report = tracer.startActiveSpan('orders.build_report', (span) => {
    try {
      span.setAttribute('app.report.rounds', REPORT_ROUNDS);
      // PLANTED ISSUE: CPU hog. pbkdf2Sync runs on the event loop, so while the report is
      // built (about 1-2 s) this process cannot serve ANY other request, including other
      // users' /orders calls. Fix: use the async crypto.pbkdf2 (thread pool), move the work
      // to a worker_thread or a batch job, or cache the report.
      let signature = Buffer.alloc(0);
      for (let round = 0; round < REPORT_ROUNDS; round += 1) {
        signature = crypto.pbkdf2Sync(JSON.stringify(ORDERS), signature, REPORT_ITERATIONS, 64, 'sha512');
      }
      span.addEvent('report.signed', { 'app.report.signature_bytes': signature.length });
      const units = ORDERS.reduce((sum, o) => sum + o.quantity, 0);
      return { orders: ORDERS.length, units, signature: signature.toString('hex').slice(0, 16) };
    } finally {
      span.end();
    }
  });
  res.json(report);
});

// Calls python-inventory. Global fetch (undici) is auto-instrumented, so the client span
// is created and the W3C `traceparent` header is injected for us.
async function getInventoryItem(sku, options = {}) {
  const res = await fetch(`${INVENTORY_URL}/inventory/items/${encodeURIComponent(sku)}`, options);
  if (!res.ok) {
    throw new UpstreamError(`python-inventory returned HTTP ${res.status} for ${sku}`, res.status);
  }
  return res.json();
}

function findOrder(req, res) {
  const order = ORDERS.find((o) => o.id === Number(req.params.id));
  if (!order) res.status(404).json({ error: 'order not found' });
  return order;
}

// ---------------------------------------------------------------------------
// GET /orders/:id: order plus live inventory from python-inventory.
// ---------------------------------------------------------------------------
app.get('/orders/:id', async (req, res) => {
  const order = findOrder(req, res);
  if (!order) return;
  const span = trace.getActiveSpan();
  span?.setAttributes({ 'app.order.id': order.id, 'app.order.sku': order.sku });
  try {
    const item = await getInventoryItem(order.sku);
    res.json({ ...order, inventory: item });
  } catch (err) {
    // PLANTED ISSUE: cross-service error chain. Order 7 references SKU-999, which crashes
    // python-inventory (HTTP 500); we surface it as 502. The trace shows the error on the
    // python span, the fetch client span and this server span. Fix: repair the data/handler
    // in python-inventory, and here degrade gracefully (return the order without stock).
    span?.recordException(err);
    span?.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
    res.status(502).json({ error: 'inventory lookup failed', detail: err.message });
  }
});

// ---------------------------------------------------------------------------
// GET /orders/:id/stock: real-time stock check.
// ---------------------------------------------------------------------------
const STOCK_TIMEOUT_MS = 2000;

app.get('/orders/:id/stock', async (req, res) => {
  const order = findOrder(req, res);
  if (!order) return;
  const span = trace.getActiveSpan();
  span?.setAttributes({ 'app.order.id': order.id, 'app.stock.timeout_ms': STOCK_TIMEOUT_MS });
  try {
    // PLANTED ISSUE: external call timeout. /inventory/slow takes ~3 s but we abort after
    // 2 s and have no fallback, so every call fails with 504. Fix: call the fast endpoint
    // (or cache stock levels), and set timeouts from the dependency's measured p99 with a
    // fallback response.
    const upstream = await fetch(`${INVENTORY_URL}/inventory/slow`, {
      signal: AbortSignal.timeout(STOCK_TIMEOUT_MS),
    });
    res.json({ id: order.id, sku: order.sku, stock: await upstream.json() });
  } catch (err) {
    // An abort is a DOMException whose numeric `code` (23) would become exception.type;
    // pass name/message/stack so the event says `TimeoutError` instead.
    span?.recordException({ name: err.name, message: err.message, stack: err.stack });
    span?.setStatus({ code: SpanStatusCode.ERROR, message: `stock check failed: ${err.name}` });
    const timedOut = err.name === 'TimeoutError';
    res.status(timedOut ? 504 : 502).json({ error: timedOut ? 'inventory timeout' : 'inventory error' });
  }
});

// ---------------------------------------------------------------------------
// POST /orders: create an order. Body: {"customer":"c1","items":[{"sku":"SKU-001","quantity":1}]}
// ---------------------------------------------------------------------------
app.post('/orders', (req, res) => {
  // PLANTED ISSUE: unhandled exception. The body is never validated. With no JSON body
  // req.body is undefined in Express 5, and with {} `items` is undefined, so `.length`
  // throws a TypeError that Express turns into a 500. Fix: validate the body (e.g. with a
  // schema) and answer 400 for bad input.
  const { items, customer } = req.body;
  const lineCount = items.length;
  const quantity = items.reduce((sum, item) => sum + Number(item.quantity || 0), 0);
  const order = { id: ORDERS.length + 1, customer, lines: lineCount, quantity, status: 'pending' };
  trace.getActiveSpan()?.addEvent('order.created', { 'app.order.lines': lineCount });
  res.status(201).json(order);
});

// ---------------------------------------------------------------------------
// Stress endpoints (tests/): bounded CPU and memory load for resource tests. OFF unless
// STRESS_ENABLED=true; caps come from env; requests that came through Traefik (any
// X-Forwarded-For header) get 404, so they answer in-cluster callers only.
// ---------------------------------------------------------------------------
const STRESS_ENABLED = process.env.STRESS_ENABLED === 'true';
const STRESS_MAX_CPU_MS = Number(process.env.STRESS_MAX_CPU_MS || 5000);
const STRESS_MAX_MB = Number(process.env.STRESS_MAX_MB || 128); // total MiB held at once, all requests
const STRESS_MAX_HOLD_S = Number(process.env.STRESS_MAX_HOLD_S || 30);
let stressHeldMb = 0;

function stressAllowed(req, res) {
  if (STRESS_ENABLED && !req.get('x-forwarded-for')) return true;
  res.status(404).json({ error: 'not found' });
  return false;
}
const clampInt = (value, fallback, max) => Math.max(0, Math.min(Math.floor(Number(value ?? fallback) || 0), max));

app.get('/stress/cpu', (req, res) => {
  if (!stressAllowed(req, res)) return;
  const ms = clampInt(req.query.ms, 200, STRESS_MAX_CPU_MS);
  const result = tracer.startActiveSpan('stress.cpu', (span) => {
    span.setAttributes({ 'app.stress.cpu.requested_ms': Number(req.query.ms ?? 200), 'app.stress.cpu.ms': ms });
    const end = performance.now() + ms;
    let rounds = 0;
    while (performance.now() < end) {
      crypto.createHash('sha256').update(String(rounds)).digest();
      rounds += 1;
    }
    span.setAttribute('app.stress.cpu.rounds', rounds);
    span.end();
    return { ms, rounds };
  });
  res.json(result);
});

app.get('/stress/memory', async (req, res) => {
  if (!stressAllowed(req, res)) return;
  const mb = clampInt(req.query.mb, 32, STRESS_MAX_MB);
  const holdS = clampInt(req.query.hold_s, 5, STRESS_MAX_HOLD_S);
  await tracer.startActiveSpan('stress.memory', async (span) => {
    span.setAttributes({ 'app.stress.memory.mb': mb, 'app.stress.memory.hold_s': holdS });
    if (stressHeldMb + mb > STRESS_MAX_MB) {
      span.setAttribute('app.stress.memory.rejected', true);
      span.end();
      res.status(429).json({ error: 'stress memory budget in use', heldMb: stressHeldMb, maxMb: STRESS_MAX_MB });
      return;
    }
    stressHeldMb += mb;
    try {
      let block = Buffer.alloc(mb * 1024 * 1024, 1); // filled, so every page is resident
      span.addEvent('memory.allocated', { 'app.stress.memory.held_mb': stressHeldMb });
      await new Promise((resolve) => setTimeout(resolve, holdS * 1000));
      block = null;
      span.addEvent('memory.released');
    } finally {
      stressHeldMb -= mb;
      span.end();
    }
    res.json({ mb, holdS });
  });
});

const server = app.listen(PORT, () => {
  console.log(`nodejs-orders listening on :${PORT}, inventory at ${INVENTORY_URL}`);
});

module.exports = { app, server };
