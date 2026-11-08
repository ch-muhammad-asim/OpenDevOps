import { ordersFetch } from '../../../orders';

export const dynamic = 'force-dynamic';

type CartItem = { sku: string; quantity: number; price: number };
type Cart = { customer?: string; items: CartItem[] };

// POST /api/checkout  body: {"customer":"c1","items":[{"sku":"SKU-001","quantity":2,"price":9.5}]}
export async function POST(request: Request) {
  const cart = (await request.json().catch(() => ({}))) as Cart;

  // PLANTED ISSUE: unhandled exception. The cart is trusted as-is; an empty body or {}
  // has no `items`, so `cart.items.reduce` throws "TypeError: Cannot read properties of
  // undefined (reading 'reduce')". Next.js records it on the request span and answers
  // 500. Fix: validate the body (e.g. a schema check) and return 400 for a bad cart.
  const total = cart.items.reduce((sum, item) => sum + item.price * item.quantity, 0);

  const res = await ordersFetch('/orders', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ customer: cart.customer ?? 'guest', items: cart.items }),
  });
  const order = await res.json();
  return Response.json({ order, total }, { status: res.status });
}
