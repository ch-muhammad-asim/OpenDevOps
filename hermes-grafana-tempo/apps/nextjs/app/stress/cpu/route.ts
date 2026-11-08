import { createHash } from 'node:crypto';
import { STRESS_MAX_CPU_MS, clampInt, notFound, stressAllowed, tracer } from '../../../stress';

export const dynamic = 'force-dynamic';

// GET /stress/cpu?ms=500: busy loop for ms (capped by STRESS_MAX_CPU_MS). See tests/README.md.
export function GET(req: Request) {
  if (!stressAllowed(req)) return notFound();
  const ms = clampInt(new URL(req.url).searchParams.get('ms'), 200, STRESS_MAX_CPU_MS);
  return tracer.startActiveSpan('stress.cpu', (span) => {
    span.setAttribute('app.stress.cpu.ms', ms);
    const end = performance.now() + ms;
    let rounds = 0;
    while (performance.now() < end) {
      createHash('sha256').update(String(rounds)).digest();
      rounds += 1;
    }
    span.setAttribute('app.stress.cpu.rounds', rounds);
    span.end();
    return Response.json({ ms, rounds });
  });
}
