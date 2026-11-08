import { ordersFetch } from '../../../orders';

export const dynamic = 'force-dynamic';

// GET /api/report: revenue report built by nodejs-orders.
// The latency is not in this app: the CLIENT span shows nextjs-web waiting, and the child
// span `orders.build_report` in nodejs-orders shows where the time goes (a CPU-bound loop).
export async function GET() {
  const started = performance.now();
  const res = await ordersFetch('/orders/report');
  const report = await res.json();
  return Response.json(
    { report, upstreamMs: Math.round(performance.now() - started) },
    { status: res.ok ? 200 : 502 },
  );
}
