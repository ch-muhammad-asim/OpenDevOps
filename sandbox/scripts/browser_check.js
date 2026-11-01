// Real-browser check of the Hermes Chat page (what a user actually sees).
//
//   HERMES_DASHBOARD_PASSWORD=... node browser_check.js https://host [IDLE_SECONDS]
//
// Logs in, opens /chat?profile=default in Chromium, and checks: the chat
// terminal (/api/pty), side panel (/api/ws) and event (/api/events) sockets
// open; the side panel shows "live"; no "interrupted"/"could not connect"
// banner; the chat terminal is in colour (escape codes, like a plain
// install; see start-hermes.sh on TERM=dumb); the side panel's "Live
// tool activity" feed never shows "paused" / "stopped" / "Reconnect side
// panel"; all sockets stay open for IDLE_SECONDS idle (default 180). Then it
// reloads the page and checks again. With LLM_CHECKS=1 it also types a random
// sum into the chat and waits for the right answer in the terminal output.
// With SWITCH_CHECK=1 it also switches the model in the side panel's "Switch
// model" dialog to SWITCH_MODEL (default openai/gpt-oss-20b, a tested fallback),
// clicks "Reload" in the page's "Switch model?" prompt like a user would, checks
// again (SWITCH_IDLE_SECONDS idle, default 30), then switches back the same way.
// It expects the live default to be SWITCH_RESTORE_MODEL (default the nemotron
// seed; otherwise it does not switch) and, once it has switched, always tries
// to restore it at the end, even when a step fails, and FAILs loudly if it can't.
// SWITCH_PROVIDER / SWITCH_RESTORE_PROVIDER default to nvidia.
// Prints PASS/FAIL lines; exit 0 only if everything passed.
const { chromium } = require('playwright-core');

const BASE = (process.argv[2] || 'https://hermes.saqlainmushtaq.com').replace(/\/$/, '');
const secs = (name, v) => {
  const n = Number(v);
  if (!Number.isInteger(n) || n < 0) { console.log(`  FAIL  ${name} must be a whole number of seconds (got "${v}")`); process.exit(2); }
  return n;
};
const IDLE = secs('IDLE_SECONDS', process.argv[3] || process.env.IDLE_SECONDS || '180');
const ASK = process.env.LLM_CHECKS === '1';
const SOCKETS = ['/api/pty', '/api/ws', '/api/events'];
let failed = 0;
const ok = (m) => console.log('  PASS  ' + m);
const bad = (m) => { console.log('  FAIL  ' + m); failed++; };
const strip = (s) => s.replace(/\x1b\[[0-9;?]*[ -\/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-B]/g, '');

// Navigation with retries: transient network changes (net::ERR_*) on the
// client must not be reported as a server failure.
async function nav(fn) {
  for (let i = 1; ; i++) {
    try { return await fn(); } catch (e) {
      if (i >= 3 || !/net::ERR_/.test(String(e))) throw e;
      await new Promise((r) => setTimeout(r, 2000 * i));
    }
  }
}

async function round(page, label, go, idle = IDLE) {
  const open = new Map();   // path -> {closed, out, colours}
  const closes = new Map(); // path -> number of closes (a drop + reconnect still counts)
  page.on('websocket', (ws) => {
    const path = SOCKETS.find((p) => ws.url().includes(p));
    if (!path) return;
    const s = { closed: false, out: '', colours: 0 };
    open.set(path, s);
    ws.on('framereceived', (f) => {
      if (path !== '/api/pty') return;
      const raw = String(f.payload);
      s.colours += (raw.match(/\x1b\[[0-9;]*[34]8;[25];/g) || []).length;
      s.out += strip(raw);
    });
    ws.on('close', () => { s.closed = true; closes.set(path, (closes.get(path) || 0) + 1); });
  });
  await go();

  // Wait for the terminal to print something, in colour (if colour never
  // comes, this just runs the full 30 s and the checks below report it).
  const ptyReady = () => { const p = open.get('/api/pty'); return !!p && p.out.trim().length > 40 && p.colours > 0; };
  for (let i = 0; i < 60 && !(SOCKETS.every((p) => open.has(p)) && ptyReady()); i++) {
    await page.waitForTimeout(500);
  }
  for (const p of SOCKETS) open.has(p) && !open.get(p).closed ? ok(`${label}: ${p} socket open`) : bad(`${label}: ${p} socket did not open`);
  // Only closes from here on count: the page may reconnect a socket once while
  // it loads (e.g. a PTY attach that fails before it is established).
  const settled = new Map(SOCKETS.map((p) => [p, closes.get(p) || 0]));
  const early = [...settled.values()].reduce((a, b) => a + b, 0);
  if (early) console.log(`  INFO  ${label}: ${early} socket reconnect(s) while the page loaded`);
  const pty = open.get('/api/pty');
  pty && pty.out.includes('Hermes') ? ok(`${label}: chat terminal shows the Hermes session`) : bad(`${label}: chat terminal stayed blank`);
  pty && pty.colours > 0 ? ok(`${label}: chat terminal is in colour (${pty.colours} colour codes)`)
    : bad(`${label}: chat terminal has no colour (TERM=dumb reached the TUI?)`);
  // The side panel's badge goes connecting -> live a moment after the sockets open.
  const live = await page.getByText('live', { exact: true }).first().waitFor({ timeout: 20000 }).then(() => true, () => false);
  live ? ok(`${label}: side panel model shows "live"`) : bad(`${label}: side panel not live within 20 s`);

  if (ASK && pty) {
    const a = 1000 + Math.floor(Math.random() * 8000), b = 1000 + Math.floor(Math.random() * 8000);
    const before = pty.out.length;
    await page.locator('.xterm').first().click();
    await page.keyboard.type(`E2E-CHECK: What is ${a}+${b}? Reply with only the number.`, { delay: 15 });
    // A freshly (re-)attached terminal can drop an Enter sent right after the
    // text, so pause first, and press Enter once more if nothing starts.
    await page.waitForTimeout(800);
    await page.keyboard.press('Enter');
    let answered = false, retried = false;
    for (let i = 0; i < 240 && !answered; i++) {
      await page.waitForTimeout(500);
      const after = pty.out.slice(before);
      answered = after.includes(String(a + b));
      if (!retried && i === 30 && !/Thinking|tokens|⚕|●/.test(after)) { await page.keyboard.press('Enter'); retried = true; }
    }
    answered ? ok(`${label}: the model answered in the chat terminal (${a}+${b}=${a + b})`) : bad(`${label}: no answer from the model within 120 s`);
  }

  // Stay idle and watch for drops or error banners.
  const banner = page.getByText(/interrupted|could not connect/i);
  // Third indicator: the side panel's "Live tool activity" feed (/api/events).
  // It only shows text when it is down ("paused - reconnecting", "stopped").
  const feedDown = page.getByText(/Live tool activity\s*(paused|stopped)/i).or(page.getByRole('button', { name: 'Reconnect side panel' }));
  let dropped = null, bannerSeen = false, feedSeen = '';
  for (let t = 0; t < idle; t += 5) {
    await page.waitForTimeout(5000);
    if (!dropped) dropped = SOCKETS.find((p) => open.get(p)?.closed || (closes.get(p) || 0) > settled.get(p)) || null;
    if ((await banner.count()) > 0) bannerSeen = true;
    if (!feedSeen) {
      const t = await feedDown.allInnerTexts().catch(() => []);
      if (t.length) feedSeen = t[0].replace(/\s+/g, ' ').slice(0, 80);
    }
  }
  dropped ? bad(`${label}: ${dropped} closed during ${idle} s idle`) : ok(`${label}: all 3 sockets stayed open for ${idle} s idle`);
  bannerSeen ? bad(`${label}: an "interrupted / could not connect" banner appeared`) : ok(`${label}: no connection error banner`);
  feedSeen ? bad(`${label}: live tool activity feed went down ("${feedSeen}")`) : ok(`${label}: live tool activity feed stayed connected`);
}

// Side panel "Switch model" dialog -> provider row -> model -> Switch, then
// "Reload" in the page's follow-up prompt (the dialog only saves the default
// for new chats; the page reloads to start one).
const modelInfo = async (page) => {
  const r = await page.request.get(BASE + '/api/model/info?profile=default');
  if (!r.ok()) throw new Error(`/api/model/info HTTP ${r.status()}`);
  return r.json();
};
// The same REST call the dialog makes; used only to put the default back.
const setModel = (page, m) => page.request.post(BASE + '/api/model/set?profile=default',
  { data: { scope: 'main', provider: m.provider, model: m.model, confirm_expensive_model: true } });

async function switchModel(page, provider, model) {
  // The side panel's model button shows the current model's short name.
  const current = (await modelInfo(page)).model.split('/').pop();
  const esc = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  await page.getByRole('button', { name: new RegExp(`^(${esc(current)}|Switch model)$`) }).first().click();
  const dlg = page.locator('[role=dialog]').filter({ hasText: /switch model/i }).first();
  await dlg.waitFor({ timeout: 15000 });
  await dlg.getByText(`${provider} · `, { exact: false }).filter({ hasText: / models$/ }).first().click();
  await dlg.locator('button').filter({ hasText: new RegExp(`^${esc(model)}(\\s|$)`) }).first().click();
  // From here on the new default is saved (Switch saves; Reload only reloads).
  await dlg.getByRole('button', { name: 'Switch', exact: true }).click();
  const reload = page.getByRole('button', { name: 'Reload', exact: true });
  await reload.waitFor({ timeout: 15000 });
  await Promise.all([page.waitForEvent('framenavigated', { timeout: 30000 }), reload.click()]);
  await page.waitForLoadState('domcontentloaded');
}

(async () => {
  // Optional extra Chromium flags, one per line, e.g. CHROME_ARGS='--host-resolver-rules=MAP host 1.2.3.4' while DNS propagates.
  const browser = await chromium.launch({ executablePath: process.env.CHROME, headless: true, args: (process.env.CHROME_ARGS || '').split('\n').map((a) => a.trim()).filter(Boolean) });
  // Optional HTTP basic auth in front of the dashboard (GKE: Traefik basicAuth).
  const edge = process.env.HERMES_EDGE_USERNAME && process.env.HERMES_EDGE_PASSWORD
    ? { httpCredentials: { username: process.env.HERMES_EDGE_USERNAME, password: process.env.HERMES_EDGE_PASSWORD } } : {};
  const page = await (await browser.newContext(edge)).newPage();
  await nav(() => page.goto(BASE + '/login', { waitUntil: 'domcontentloaded' }));
  const r = await page.request.post(BASE + '/auth/password-login', {
    data: { provider: 'basic', username: process.env.HERMES_DASHBOARD_USERNAME || 'admin', password: process.env.HERMES_DASHBOARD_PASSWORD },
  });
  r.status() === 200 ? ok('browser login') : bad(`browser login (HTTP ${r.status()})`);
  await round(page, 'first load', () => nav(() => page.goto(BASE + '/chat?profile=default', { waitUntil: 'domcontentloaded' })));
  await round(page, 'after reload', () => nav(() => page.reload({ waitUntil: 'domcontentloaded' })));
  if (process.env.SWITCH_CHECK === '1') {
    // Changes the live default for everyone for a minute or two; always put
    // the expected default back, even when a step fails.
    const from = { provider: process.env.SWITCH_RESTORE_PROVIDER || 'nvidia', model: process.env.SWITCH_RESTORE_MODEL || 'nvidia/nemotron-3.5-super-vl-120b-a12b' };
    const to = { provider: process.env.SWITCH_PROVIDER || from.provider, model: process.env.SWITCH_MODEL || 'openai/gpt-oss-20b' };
    const sidle = secs('SWITCH_IDLE_SECONDS', process.env.SWITCH_IDLE_SECONDS || '30');
    let touched = false;
    try {
      const start = await modelInfo(page);
      if (start.model !== from.model) throw new Error(`live default is ${start.model}, expected ${from.model}; not switching (set SWITCH_RESTORE_MODEL to keep it)`);
      ok(`model switch: live default is ${from.model} before the switch`);
      touched = true;
      for (const [label, m] of [[`model switch to ${to.model}`, to], [`model switch back to ${from.model}`, from]]) {
        await round(page, label, () => switchModel(page, m.provider, m.model), sidle);
        const now = await modelInfo(page);
        now.model === m.model ? ok(`${label}: default model is now ${m.model}`) : bad(`${label}: default model is ${now.model}`);
      }
    } catch (e) {
      bad(`model switch: failed (${String(e).split('\n')[0].slice(0, 160)})`);
    } finally {
      const now = await modelInfo(page).catch(() => ({}));
      if (touched && !now.model) bad('model switch: could not read /api/model/info to check the live default');
      else if (touched && now.model !== from.model) {
        await setModel(page, from).catch(() => null);
        const after = await modelInfo(page).catch(() => ({}));
        after.model === from.model ? ok(`model switch: live default restored to ${from.model}`)
          : bad(`model switch: could NOT restore the live default to ${from.model} (it is ${after.model || 'unknown'})`);
      }
    }
  }
  await page.screenshot({ path: process.env.SCREENSHOT || require('path').join(require('os').tmpdir(), `hermes-browser-check-${process.pid}.png`) });
  await browser.close();
  console.log(`Result: ${failed === 0 ? 'browser check passed' : failed + ' browser check(s) failed'}`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((e) => { console.log('  FAIL  browser check crashed: ' + String(e).slice(0, 300)); process.exit(1); });
