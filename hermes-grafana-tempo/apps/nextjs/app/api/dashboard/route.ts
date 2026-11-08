import { SpanStatusCode, trace } from '@opentelemetry/api';
import { ordersFetch, type Order } from '../../../orders';

export const dynamic = 'force-dynamic';
const tracer = trace.getTracer('nextjs-web');

// GET /api/dashboard: the order list with full details for each order.
export async function GET() {
  return tracer.startActiveSpan('dashboard.load_orders', async (span) => {
    try {
      const list = await ordersFetch('/orders');
      if (!list.ok) throw new Error(`nodejs-orders GET /orders returned HTTP ${list.status}`);
      const { orders } = (await list.json()) as { orders: Order[] };

      // PLANTED ISSUE: N+1 HTTP fan-out. One request per order, awaited one after the
      // other, so the page waits for 1 + N round trips in a waterfall. Fix: add a batch
      // endpoint (GET /orders?ids=1,2,3 or include details in GET /orders), or at least
      // run the calls concurrently with Promise.all and a concurrency limit.
      const details: Order[] = [];
      const failed: number[] = [];
      for (const order of orders) {
        const res = await ordersFetch(`/orders/${order.id}`);
        if (!res.ok) {
          // One bad order should not break the dashboard: record it and show partial data.
          failed.push(order.id);
          span.addEvent('order.fetch_failed', {
            'app.order.id': order.id,
            'http.response.status_code': res.status,
          });
          console.warn(`dashboard: order ${order.id} failed with HTTP ${res.status}`);
          continue;
        }
        details.push((await res.json()) as Order);
      }

      span.setAttributes({
        'app.orders.count': details.length,
        'app.orders.failed': failed.length,
        'app.orders.requests': orders.length + 1,
      });
      return Response.json({ partial: failed.length > 0, failed, count: details.length, orders: details });
    } catch (err) {
      span.recordException(err as Error);
      span.setStatus({ code: SpanStatusCode.ERROR, message: (err as Error).message });
      return Response.json({ error: 'orders service unavailable' }, { status: 502 });
    } finally {
      span.end();
    }
  });
}
