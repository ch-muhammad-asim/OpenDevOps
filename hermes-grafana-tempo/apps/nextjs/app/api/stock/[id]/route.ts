import { ordersFetch } from '../../../../orders';

export const dynamic = 'force-dynamic';

// GET /api/stock/:id: live stock for one order, proxied from nodejs-orders.
export async function GET(_request: Request, ctx: { params: Promise<{ id: string }> }) {
  const { id } = await ctx.params;

  // PLANTED ISSUE: cascading timeout. No timeout and no fallback here: the request waits
  // as long as nodejs-orders does (2 s, then 504) and passes the 504 to the user. Under
  // load every waiting request holds a connection. Fix: set a budget below the caller's
  // (signal: AbortSignal.timeout(500)), serve a cached/"unknown" stock value on timeout,
  // and fix the slow dependency itself.
  const res = await ordersFetch(`/orders/${encodeURIComponent(id)}/stock`);
  return new Response(await res.text(), {
    status: res.status,
    headers: { 'content-type': res.headers.get('content-type') ?? 'application/json' },
  });
}
