// Small client for nodejs-orders (ORDERS_URL). Global fetch is traced by
// @vercel/otel, so every call is a CLIENT span with `traceparent` propagated.
export const ORDERS_URL = (process.env.ORDERS_URL ?? 'http://localhost:3001').replace(/\/+$/, '');

export type Order = { id: number; customer: string; sku: string; quantity: number; status: string };

export function ordersFetch(path: string, init: RequestInit = {}): Promise<Response> {
  return fetch(`${ORDERS_URL}${path}`, { cache: 'no-store', ...init });
}
