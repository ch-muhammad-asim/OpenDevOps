// k6 driver for the resource and resilience tests (tests/run.sh cpu|memory|oom|dependency|podkill).
//   APP=nextjs|nodejs|python  MODE=cpu|memory|oom|dependency|podkill  SCALE (default 1)
//   cpu/memory: stress VUs call /stress/* while one probe VU measures a healthy endpoint.
//   oom: one /stress/memory call above the pod limit (BASE_URL = the throwaway pod).
//   dependency/podkill: steady traffic; run.sh breaks the dependency or deletes a pod meanwhile.
// Docs: https://grafana.com/docs/k6/latest/using-k6/scenarios/
import http from 'k6/http';
import { check } from 'k6';

const APP = __ENV.APP || 'python';
const MODE = __ENV.MODE || 'cpu';
const SCALE = Number(__ENV.SCALE || 1);
const d = (s) => `${Math.max(1, Math.round(s * SCALE))}s`;
const BASES = { nextjs: 'http://nextjs.tempo-apps:3000', nodejs: 'http://nodejs.tempo-apps:3000', python: 'http://python.tempo-apps:8000' };
const HEALTHY = { nextjs: '/', nodejs: '/orders/1', python: '/inventory/items' };
const BASE = __ENV.BASE_URL || BASES[APP];

const CPU_MS = Number(__ENV.CPU_MS || 500);
const MEM_MB = Number(__ENV.MEM_MB || 40);
const HOLD_S = Number(__ENV.HOLD_S || 10);

const probe = { executor: 'constant-vus', vus: 1, duration: d(90), exec: 'healthy' };
const MODES = {
  cpu: { stress: { executor: 'constant-vus', vus: 4, duration: d(60), startTime: d(15), exec: 'cpu' }, probe },
  memory: { stress: { executor: 'constant-vus', vus: 4, duration: d(60), startTime: d(15), exec: 'memory' }, probe },
  oom: { oom: { executor: 'shared-iterations', vus: 1, iterations: 1, exec: 'oom', maxDuration: '60s' } },
  dependency: { traffic: { executor: 'constant-arrival-rate', rate: 5, timeUnit: '1s', duration: d(120),
    preAllocatedVUs: 20, maxVUs: 50, exec: 'dashboard' } },
  podkill: { traffic: { executor: 'constant-arrival-rate', rate: 20, timeUnit: '1s', duration: d(90),
    preAllocatedVUs: 20, maxVUs: 100, exec: 'healthy' } },
};
if (!MODES[MODE]) throw new Error(`unknown MODE ${MODE}`);

export const options = {
  scenarios: MODES[MODE],
  // Informational thresholds: these tests are judged on the Grafana panels and the numbers in the summary.
  thresholds: {
    'http_req_duration{scenario:probe}': ['p(95)<1000'],
    'http_req_failed{scenario:probe}': ['rate<0.05'],
  },
  tags: { app: APP, scenario: MODE },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export function healthy() {
  const res = http.get(`${BASE}${HEALTHY[APP]}`, { tags: { name: HEALTHY[APP] }, timeout: '10s' });
  check(res, { 'healthy 200': (r) => r.status === 200 });
}
export function cpu() {
  const res = http.get(`${BASE}/stress/cpu?ms=${CPU_MS}`, { tags: { name: '/stress/cpu' }, timeout: '30s' });
  check(res, { 'cpu 200': (r) => r.status === 200 });
}
export function memory() {
  const res = http.get(`${BASE}/stress/memory?mb=${MEM_MB}&hold_s=${HOLD_S}`, { tags: { name: '/stress/memory' }, timeout: '60s' });
  check(res, { 'memory 200 or 429 (budget)': (r) => r.status === 200 || r.status === 429 });
}
export function oom() {
  const res = http.get(`${BASE}/stress/memory?mb=${MEM_MB}&hold_s=${HOLD_S}`, { timeout: '30s' });
  console.log(`oom request status=${res.status} error=${res.error || ''}`);
}
export function dashboard() {
  const res = http.get(`http://nextjs.tempo-apps:3000/api/dashboard`, { tags: { name: '/api/dashboard' }, timeout: '15s' });
  check(res, { 'dashboard 200': (r) => r.status === 200 });
}
