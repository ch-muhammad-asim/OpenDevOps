// Server-rendered index of the demo scenarios. No client-side JavaScript.
export const dynamic = 'force-dynamic';

const scenarios = [
  { href: '/api/dashboard', label: 'Dashboard', issue: 'N+1 HTTP fan-out: 1 list call + 10 sequential detail calls' },
  { href: '/api/stock/3', label: 'Stock check', issue: 'Cascading timeout: upstream 504 after ~2 s' },
  { href: '/api/report', label: 'Report', issue: 'Slow upstream: CPU-bound report in nodejs-orders' },
];

export default function Home() {
  return (
    <main>
      <h1>nextjs-web</h1>
      <p>Sample app for Grafana Tempo. Each link runs one planted issue; find it in Tempo by trace.</p>
      <ul>
        {scenarios.map((s) => (
          <li key={s.href}>
            <a href={s.href}>{s.label}</a> <code>GET {s.href}</code>: {s.issue}
          </li>
        ))}
        <li>
          Checkout <code>POST /api/checkout</code>: unhandled TypeError on an empty cart. Try{' '}
          <code>curl -X POST -H &apos;content-type: application/json&apos; -d &apos;{'{}'}&apos; /api/checkout</code>
        </li>
      </ul>
      <p>
        Stress tests (off unless <code>STRESS_ENABLED=true</code>, in-cluster only): <code>GET /stress/cpu?ms=500</code>{' '}
        bounded busy loop, <code>GET /stress/memory?mb=32&amp;hold_s=5</code> holds memory then releases it.
      </p>
    </main>
  );
}
