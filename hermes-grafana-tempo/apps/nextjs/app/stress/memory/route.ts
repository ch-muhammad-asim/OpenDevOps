import {
  STRESS_MAX_HOLD_S, STRESS_MAX_MB, clampInt, memoryBudget, notFound, stressAllowed, tracer,
} from '../../../stress';

export const dynamic = 'force-dynamic';

// GET /stress/memory?mb=32&hold_s=5: allocate mb MiB (budget STRESS_MAX_MB shared by all
// requests), hold for hold_s seconds (capped by STRESS_MAX_HOLD_S), then release. See tests/README.md.
export async function GET(req: Request) {
  if (!stressAllowed(req)) return notFound();
  const params = new URL(req.url).searchParams;
  const mb = clampInt(params.get('mb'), 32, STRESS_MAX_MB);
  const holdS = clampInt(params.get('hold_s'), 5, STRESS_MAX_HOLD_S);
  return tracer.startActiveSpan('stress.memory', async (span) => {
    span.setAttributes({ 'app.stress.memory.mb': mb, 'app.stress.memory.hold_s': holdS });
    if (memoryBudget.heldMb + mb > STRESS_MAX_MB) {
      span.setAttribute('app.stress.memory.rejected', true);
      span.end();
      return Response.json(
        { error: 'stress memory budget in use', heldMb: memoryBudget.heldMb, maxMb: STRESS_MAX_MB },
        { status: 429 },
      );
    }
    memoryBudget.heldMb += mb;
    try {
      let block: Buffer | null = Buffer.alloc(mb * 1024 * 1024, 1); // filled: pages are resident
      span.addEvent('memory.allocated', { 'app.stress.memory.held_mb': memoryBudget.heldMb });
      await new Promise((resolve) => setTimeout(resolve, holdS * 1000));
      block = null;
      span.addEvent('memory.released');
      return Response.json({ mb, holdS, released: block === null });
    } finally {
      memoryBudget.heldMb -= mb;
      span.end();
    }
  });
}
