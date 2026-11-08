// Liveness/readiness probe. Not traced: instrumentation.node.ts drops /healthz root spans.
export const dynamic = 'force-dynamic';

export function GET() {
  return Response.json({ status: 'ok' });
}
