// k6 load test for one sample app. One script, five scenarios, picked by env:
//   APP=nextjs|nodejs|python  SCENARIO=smoke|load|stress|spike|soak
//   SCALE (default 1) multiplies every duration; SOAK_DURATION overrides the soak hold (e.g. 2h).
//   BASE_URL overrides the in-cluster Service URL.
// Docs: https://grafana.com/docs/k6/latest/testing-guides/test-types/
import http from 'k6/http';
import { check } from 'k6';

const APP = __ENV.APP || 'nodejs';
const SCENARIO = __ENV.SCENARIO || 'smoke';
const SCALE = Number(__ENV.SCALE || 1);

// Healthy endpoints only, so thresholds measure capacity, not the planted bugs.
const TARGETS = {
  nextjs: { base: 'http://nextjs.tempo-apps:3000', paths: ['/'] },
  nodejs: { base: 'http://nodejs.tempo-apps:3000', paths: ['/orders/1', '/orders/2'] },
  python: { base: 'http://python.tempo-apps:8000', paths: ['/inventory/items'] },
};
const target = TARGETS[APP];
if (!target) throw new Error(`unknown APP ${APP}`);
const BASE = __ENV.BASE_URL || target.base;

const d = (s) => `${Math.max(1, Math.round(s * SCALE))}s`;

const SCENARIOS = {
  // A few requests: does it work at all?
  smoke: { executor: 'constant-vus', vus: 2, duration: d(15) },
  // Expected traffic: steady 10 VUs.
  load: { executor: 'ramping-vus', stages: [
    { duration: d(10), target: 10 }, { duration: d(40), target: 10 }, { duration: d(10), target: 0 }] },
  // Ramp far past expected traffic to find the breaking point (thresholds do not abort).
  stress: { executor: 'ramping-vus', stages: [
    { duration: d(20), target: 20 }, { duration: d(20), target: 50 }, { duration: d(20), target: 100 },
    { duration: d(20), target: 150 }, { duration: d(10), target: 0 }] },
  // Sudden jump from 2 to 100 VUs and back.
  spike: { executor: 'ramping-vus', stages: [
    { duration: d(10), target: 2 }, { duration: d(5), target: 100 }, { duration: d(20), target: 100 },
    { duration: d(5), target: 2 }, { duration: d(10), target: 2 }] },
  // Moderate load held for a long time (short in the lab; SOAK_DURATION=2h for a real soak).
  soak: { executor: 'constant-vus', vus: 10, duration: __ENV.SOAK_DURATION || d(120) },
};
if (!SCENARIOS[SCENARIO]) throw new Error(`unknown SCENARIO ${SCENARIO}`);

// p95 latency and error-rate thresholds per scenario (ms, ratio).
const LIMITS = {
  smoke: [500, 0.01], load: [500, 0.01], soak: [500, 0.01], spike: [2000, 0.05], stress: [2000, 0.05],
};
const [p95, errRate] = LIMITS[SCENARIO];

export const options = {
  scenarios: { [SCENARIO]: SCENARIOS[SCENARIO] },
  thresholds: {
    http_req_duration: [`p(95)<${p95}`],
    http_req_failed: [`rate<${errRate}`],
    checks: ['rate>0.95'],
  },
  tags: { app: APP, scenario: SCENARIO },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const path = target.paths[Math.floor(Math.random() * target.paths.length)];
  const res = http.get(`${BASE}${path}`, { tags: { name: path }, timeout: '10s' });
  check(res, { 'status is 200': (r) => r.status === 200 });
}
