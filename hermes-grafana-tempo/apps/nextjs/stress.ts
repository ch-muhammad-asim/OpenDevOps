// Stress endpoints (tests/): bounded CPU and memory load for resource tests. OFF unless
// STRESS_ENABLED=true; caps come from env; requests that came through Traefik (any
// X-Forwarded-For header) get 404, so they answer in-cluster callers only.
import { trace } from '@opentelemetry/api';

export const tracer = trace.getTracer('nextjs-web');
export const STRESS_MAX_CPU_MS = Number(process.env.STRESS_MAX_CPU_MS || 5000);
export const STRESS_MAX_MB = Number(process.env.STRESS_MAX_MB || 128); // total MiB held at once
export const STRESS_MAX_HOLD_S = Number(process.env.STRESS_MAX_HOLD_S || 30);

export function stressAllowed(req: Request): boolean {
  return process.env.STRESS_ENABLED === 'true' && !req.headers.get('x-forwarded-for');
}

export function notFound(): Response {
  return Response.json({ error: 'not found' }, { status: 404 });
}

export function clampInt(value: string | null, fallback: number, max: number): number {
  const n = Math.floor(Number(value ?? fallback) || 0);
  return Math.max(0, Math.min(n, max));
}

// Module-level budget shared by every request in this process.
export const memoryBudget = { heldMb: 0 };
