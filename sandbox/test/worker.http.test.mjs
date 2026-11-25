// The sandbox Worker end to end over HTTP: wrangler dev (LOCAL ONLY) -> Durable Object -> anvil fork of Aevum testnet.
// Run: SANDBOX_WORKER=1 node --test --test-concurrency=1 test/worker.http.test.mjs
// Needs: anvil fork on :18546 with deploy.mjs --fork done (work/fork-state.json) and work/dev.vars (worker/mkvars.mjs --mode fork).
// Each phase starts its own wrangler dev (own port, fresh persist dir) and stops it after.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createPublicClient, http, stringToHex } from 'viem';
import { KINDS } from '../lib/sandbox.mjs';

const ROOT = new URL('..', import.meta.url).pathname;
const RPC = 'http://127.0.0.1:18546';
const skip = !process.env.SANDBOX_WORKER || !existsSync(ROOT + 'work/fork-state.json') || !existsSync(ROOT + 'work/dev.vars');
const st = skip ? {} : JSON.parse(readFileSync(ROOT + 'work/fork-state.json', 'utf8'));
const pub = createPublicClient({ transport: http(RPC) });
const DUMMY = 'XXXX.DUMMY.TOKEN.XXXX';
const ONLY = process.env.PHASES ? process.env.PHASES.split(',') : null;      // e.g. PHASES=2,4 (used by worker/scripts/controls.sh)
const phase = (n) => ({ skip: ONLY !== null && !ONLY.includes(String(n)) });

function dev(port, vars = [], { keep = false } = {}) {
  const dir = `work/wr-test-${port}`;
  if (!keep) rmSync(ROOT + dir, { recursive: true, force: true });
  execFileSync(ROOT + 'worker/scripts/dev.sh', ['start', String(port), dir, ...vars.flatMap((v) => ['--var', v])], { cwd: ROOT, stdio: 'ignore', timeout: 120_000 });
  const base = `http://127.0.0.1:${port}`;
  return { base, stop: () => execFileSync(ROOT + 'worker/scripts/dev.sh', ['stop', String(port)], { cwd: ROOT, stdio: 'ignore' }) };
}

async function post(base, fields, { ip = '198.51.100.1', json = false, headers = {}, raw } = {}) {
  const body = raw ?? new URLSearchParams({ 'cf-turnstile-response': DUMMY, ...fields }).toString();
  const r = await fetch(base + '/attack', { method: 'POST', body, signal: AbortSignal.timeout(120_000),
    headers: { 'content-type': 'application/x-www-form-urlencoded', 'cf-connecting-ip': ip, accept: json ? 'application/json' : 'text/html', ...headers } });
  const text = await r.text();
  return { status: r.status, headers: r.headers, text, json: json ? (() => { try { return JSON.parse(text); } catch { return null; } })() : null };
}
const state = async (base) => (await fetch(base + '/api/state')).json();
const nonces = async () => Promise.all(Object.values(st.addresses).map((a) => pub.getTransactionCount({ address: a })));

test('sandbox Worker over HTTP', { skip, timeout: 1_800_000 }, async (t) => {
  // fork housekeeping: the 'expired' session is 120 s long; empty blocks reset anvil's gas oracle after deploy.mjs
  await pub.request({ method: 'evm_increaseTime', params: [200] });
  await pub.request({ method: 'anvil_mine', params: ['0x40'] });

  // ---------------- phase 1: relaxed limits (dev only), every kind through the HTTP path
  await t.test('phase 1: every attack kind lands its refusal through POST /attack', phase(1), async (t1) => {
    const S = dev(18791, ['LIMIT_IP_INTERVAL_S:0', 'LIMIT_IP_DAY:1000', 'LIMIT_GLOBAL_DAY:1000', 'LIMIT_GLOBAL_HOUR:1000', 'LIMIT_QUEUE:20']);
    try {
      const h = await (await fetch(S.base + '/healthz')).json();
      assert.equal(h.ok, true, JSON.stringify(h)); assert.equal(h.keysAboveFloor, true); assert.equal(h.sessionsValid, true);

      await t1.test('home page: server-rendered, no CORS, strict CSP, only the Turnstile script', async () => {
        const r = await fetch(S.base + '/');
        const body = await r.text();
        assert.equal(r.status, 200);
        assert.equal(r.headers.get('access-control-allow-origin'), null);
        assert.match(r.headers.get('content-security-policy'), /default-src 'none'.*frame-ancestors 'none'/);
        assert.match(body, /Try to make Clerk pay the wrong payee/);
        const scripts = [...body.matchAll(/<script[^>]*>/g)].map((m) => m[0]);
        assert.deepEqual(scripts, ['<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer>']);
        assert.doesNotMatch(body, /\bAI agent\b/i);
        for (const k of Object.keys(KINDS)) assert.match(body, new RegExp(`value="${k}"`));
      });

      const ids = {};
      for (const [kind, K] of Object.entries(KINDS)) {
        await t1.test(`${K.n}. ${kind} (form POST, HTML answer)`, async () => {
          const r = await post(S.base, { kind, text: '' }, { ip: `198.51.100.${10 + K.n}` });
          assert.equal(r.status, 200, r.text.slice(0, 400));
          assert.match(r.text, K.control ? /Accepted: a genuine invoice is staged/ : /Refused on chain/);
          const s = await state(S.base);
          const a = s.attempts[0];
          assert.equal(a.kind, kind);
          assert.equal(a.outcome, K.control ? 'accepted' : 'refused', JSON.stringify(a));
          const last = a.steps.at(-1);
          assert.ok(last.sent && /^0x[0-9a-f]{64}$/.test(last.hash));
          if (K.expect.startsWith('PaymentBlocked')) assert.match(last.error, new RegExp(`^PaymentBlocked\\(reason ${K.expect.split(':')[1]}`));
          else if (!K.control) { assert.equal(last.status, 'reverted'); assert.equal(last.error, K.expect); assert.match(r.text, new RegExp(K.expect)); }
          const rc = await pub.getTransactionReceipt({ hash: last.hash });
          assert.equal(rc.status, K.control || K.expect.startsWith('PaymentBlocked') ? 'success' : 'reverted');
          ids[kind] = a.id;
        });
      }

      await t1.test('counts per kind match (one refusal each, control accepted)', async () => {
        const s = await state(S.base);
        for (const [kind, K] of Object.entries(KINDS)) {
          const c = s.counts[kind];
          assert.equal(c.attempts, 1, kind); assert.equal(c.faults, 0, kind);
          assert.equal(K.control ? c.accepted : c.refused, 1, kind);
        }
        assert.equal(s.treasury, '90000', 'treasury unchanged at 0.09 tUSD8');
        const page = await (await fetch(S.base + '/')).text();
        for (const a of s.attempts) assert.ok(page.includes(`/attempt/${a.id}"`) || s.attempts.indexOf(a) >= 25);
        const one = await fetch(S.base + `/attempt/${ids.payee_swap}`);
        assert.equal(one.status, 200); assert.match(await one.text(), /PayeeNotRegistered/);
      });

      await t1.test('visitor text: never stored or shown publicly, never on chain, escaped when echoed', async () => {
        const visitorAddr = '0x00000000000000000000000000000000DeaDBeef';
        const marker = 'MARKER' + Date.now();
        const text = `ACME SUPPLIES LTD\nFrom: Acme Supplies Ltd <script>alert(1)</script>${marker}\nInvoice No: INV-${marker}\nAmount due: 0.05 tUSD8\nPay to: ${visitorAddr}`;
        const r = await post(S.base, { kind: 'payee_swap', text }, { ip: '198.51.100.77' });
        assert.equal(r.status, 200);
        assert.doesNotMatch(r.text, /<script>alert/);
        assert.match(r.text, /swapped for a fresh random address/);
        const s = await state(S.base);
        const a = s.attempts[0];
        assert.equal(a.outcome, 'refused'); assert.equal(a.offchain.replacedAddress, true);
        for (const body of [JSON.stringify(s), await (await fetch(S.base + '/')).text(), await (await fetch(S.base + '/log')).text(), await (await fetch(S.base + `/attempt/${a.id}`)).text()]) {
          assert.ok(!body.includes(marker), 'visitor text leaked into a public view');
          assert.ok(!body.toLowerCase().includes(visitorAddr.toLowerCase()), 'visitor address in a public view');
        }
        const tx = await pub.getTransaction({ hash: a.steps.at(-1).hash });
        assert.ok(!tx.input.toLowerCase().includes(visitorAddr.slice(2).toLowerCase()), 'visitor address reached the chain');
        // F1: the invoice number the visitor wrote must not be in calldata either (the on-chain ref is always SBX-n)
        assert.ok(!tx.input.toLowerCase().includes(stringToHex(`INV-${marker}`).slice(2).toLowerCase()), 'visitor invoice number reached the chain');
        assert.ok(tx.input.toLowerCase().includes(stringToHex('SBX-').slice(2)), 'POSITIVE CONTROL: our own SBX- ref is in calldata');
      });

      await t1.test('F6: a 3900-digit amount is clamped (refused as a payee attack, not a public fault)', async () => {
        const r = await post(S.base, { kind: 'payee_swap', text: `ACME SUPPLIES LTD\nFrom: Acme Supplies Ltd\nInvoice No: INV-BIG-${Date.now()}\nAmount due: ${'9'.repeat(3900)}\nPay to: {ATTACKER}` }, { ip: '198.51.100.80', json: true });
        assert.equal(r.status, 200); assert.equal(r.json.attempt.outcome, 'refused', JSON.stringify(r.json.attempt));
        assert.equal(r.json.attempt.steps.at(-1).error, 'PayeeNotRegistered');
      });

      await t1.test('F5: registered wallet + over the run cap is NOT sent and NOT counted as a payee refusal', async () => {
        const acme = (await pub.readContract({ address: '0xF45E7f39Caba1d2055f613970575a7e7069636Be', abi: [{ type: 'function', name: 'getAgentWallet', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ type: 'address' }] }], functionName: 'getAgentWallet', args: [BigInt(st.acme_id)] }));
        const before = (await state(S.base)).counts.payee_swap;
        const n0 = await nonces();
        const r = await post(S.base, { kind: 'payee_swap', text: `ACME SUPPLIES LTD\nFrom: Acme Supplies Ltd\nInvoice No: INV-CAP-${Date.now()}\nAmount due: 0.11 tUSD8\nPay to: ${acme}` }, { ip: '198.51.100.81', json: true });
        assert.equal(r.status, 200); assert.equal(r.json.attempt.outcome, 'not_counted', JSON.stringify(r.json.attempt));
        const c = (await state(S.base)).counts.payee_swap;
        assert.equal(c.refused, before.refused); assert.equal(c.faults, before.faults);
        assert.deepEqual(await nonces(), n0, 'nothing sent');
      });

      await t1.test('CONTROL: an invoice naming the REGISTERED wallet is accepted, not counted as a refusal', async () => {
        const acme = (await pub.readContract({ address: '0xF45E7f39Caba1d2055f613970575a7e7069636Be', abi: [{ type: 'function', name: 'getAgentWallet', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ type: 'address' }] }], functionName: 'getAgentWallet', args: [BigInt(st.acme_id)] }));
        const before = (await state(S.base)).counts.payee_swap.refused;
        const r = await post(S.base, { kind: 'payee_swap', text: `ACME SUPPLIES LTD\nFrom: Acme Supplies Ltd\nInvoice No: INV-CTL-${Date.now()}\nDue date: 2026-12-18\nAmount due: 0.03 tUSD8\nPay to: ${acme}` }, { ip: '198.51.100.78' });
        assert.equal(r.status, 200); assert.match(r.text, /Accepted: your invoice named the registered wallet/);
        const s = await state(S.base);
        assert.equal(s.attempts[0].outcome, 'accepted'); assert.equal(s.counts.payee_swap.refused, before);
      });

      await t1.test('bad input is refused before anything is sent', async () => {
        const n0 = await nonces(); const c0 = (await state(S.base)).attempts[0].id;
        const cases = [
          [await fetch(S.base + '/attack'), 405],
          [await post(S.base, { kind: 'payee_swap', text: 'x'.repeat(4097) }), 413],
          [await post(S.base, {}, { raw: 'kind=zero_amount&text=' + 'y'.repeat(9000) }), 413],
          [await post(S.base, {}, { raw: 'kind=zero_amount&pad=' + 'y'.repeat(9000) }), 413],     // over 8 KB with no single field too long
          [await post(S.base, { kind: 'drain_treasury' }), 400],
          [await post(S.base, { kind: '__proto__' }), 400],
          [await post(S.base, { kind: 'zero_amount' }, { headers: { 'content-type': 'text/plain' } }), 415],
          [await post(S.base, { kind: 'zero_amount' }, { headers: { origin: 'https://evil.example' } }), 403],
          [await post(S.base, { kind: 'zero_amount' }, { headers: { 'sec-fetch-site': 'cross-site' } }), 403],
          [await post(S.base, {}, { raw: JSON.stringify({ kind: 'zero_amount', turnstile: DUMMY }), headers: { 'content-type': 'application/json' } }), 403],
          [await post(S.base, {}, { raw: 'kind=zero_amount' }), 403],                                  // no Turnstile token
          [await post(S.base, {}, { raw: 'kind=zero_amount&cf-turnstile-response=' + 'z'.repeat(2049) }), 403],
          [await fetch(S.base + '/attack', { method: 'PUT', body: 'kind=zero_amount' }), 405],
          [await fetch(S.base + '/attempt/99999999'), 404],
          [await fetch(S.base + '/nope'), 404],
        ];
        for (const [i, [r, code]] of cases.entries()) {
          assert.equal(r.status, code, `case ${i}`);
          assert.equal(r.headers.get('access-control-allow-origin'), null, `case ${i} CORS`);
        }
        assert.deepEqual(await nonces(), n0, 'no key sent anything');
        assert.equal((await state(S.base)).attempts[0].id, c0, 'no attempt recorded');
      });

      await t1.test('JSON from our own origin works (same rules)', async () => {
        const r = await post(S.base, {}, { json: true, raw: JSON.stringify({ kind: 'zero_amount', turnstile: DUMMY }), headers: { 'content-type': 'application/json', origin: S.base }, ip: '198.51.100.79' });
        assert.equal(r.status, 200); assert.equal(r.json.attempt.outcome, 'refused'); assert.equal(r.json.attempt.steps.at(-1).error, 'ZeroAmount');
      });

      await t1.test('8 concurrent attacks from 8 visitors: one queue, no nonce clash, all refused', async () => {
        const kinds = ['zero_amount', 'over_run_cap', 'duplicate_in_run', 'resend_paid', 'clerk_executes', 'payee_swap', 'injection', 'lookalike'];
        const rs = await Promise.all(kinds.map((kind, i) => post(S.base, { kind }, { ip: `198.51.100.${100 + i}`, json: true })));
        for (const [i, r] of rs.entries()) { assert.equal(r.status, 200, kinds[i]); assert.equal(r.json.attempt.outcome, 'refused', JSON.stringify(r.json.attempt)); }
        const blocks = rs.map((r) => Number(r.json.attempt.steps.at(-1).block));
        assert.equal(new Set(blocks).size, blocks.length, 'each attempt mined in its own block (serialised)');
      });

      await t1.test('log keeps the last 100; counters keep everything', { skip: process.env.SKIP_TRIM === '1' }, async () => {
        const before = await state(S.base);
        const total0 = Object.values(before.counts).reduce((a, c) => a + c.attempts, 0);
        const need = 101 - before.attempts.length;
        for (let i = 0; i < need; i++) {
          const r = await post(S.base, { kind: 'zero_amount' }, { ip: `198.51.101.${i % 250}`, json: true });
          assert.equal(r.status, 200);
        }
        const s = await state(S.base);
        assert.equal(s.attempts.length, 100);
        assert.equal(Object.values(s.counts).reduce((a, c) => a + c.attempts, 0), total0 + need);
        const log = await (await fetch(S.base + '/log')).text();
        assert.match(log, /The last 100 attempts/);
      });

      await t1.test('F3: / and /log are served from a 5 s cache; /healthz is cached 30 s and booleans only', async () => {
        const a = await fetch(S.base + '/'); const b = await fetch(S.base + '/');
        assert.equal(a.headers.get('x-rendered-at'), b.headers.get('x-rendered-at'), 'second view served from cache');
        await new Promise((r) => setTimeout(r, 5_500));
        const c = await fetch(S.base + '/');
        assert.notEqual(c.headers.get('x-rendered-at'), a.headers.get('x-rendered-at'), 'POSITIVE CONTROL: re-rendered after 5 s');
        const h1 = await (await fetch(S.base + '/healthz')).json(); const h2 = await (await fetch(S.base + '/healthz')).json();
        assert.equal(h1.checkedAt, h2.checkedAt, 'health cached');
        for (const [k, v] of Object.entries(h1)) if (k !== 'checkedAt') assert.equal(typeof v, 'boolean', `healthz.${k} is not a boolean`);
      });

      await t1.test('GUARD-OFF CONTROL: with the interval relaxed, the same visitor twice in a row is NOT limited', async () => {
        const a = await post(S.base, { kind: 'zero_amount' }, { ip: '203.0.113.50' });
        const b = await post(S.base, { kind: 'zero_amount' }, { ip: '203.0.113.50' });
        assert.equal(a.status, 200); assert.equal(b.status, 200);
      });
    } finally { S.stop(); }
  });

  // ---------------- phase 2: default limits (no vars): 1 per 60 s per IP
  await t.test('phase 2: default limits refuse a second attempt within 60 s from the same IP', phase(2), async () => {
    const S = dev(18792);
    try {
      const s0 = await state(S.base);
      assert.deepEqual(s0.limits, { ipIntervalS: 60, ipDay: 30, globalDay: 300, globalHour: 30, demoDay: 40, maxQueue: 4 });
      const a = await post(S.base, { kind: 'zero_amount' }, { ip: '203.0.113.50' });
      const n0 = await nonces();
      const b = await post(S.base, { kind: 'zero_amount' }, { ip: '203.0.113.50' });
      const c = await post(S.base, { kind: 'zero_amount' }, { ip: '203.0.113.51' });
      assert.equal(a.status, 200);
      assert.equal(b.status, 429); assert.match(b.text, /One attempt a minute/); assert.ok(Number(b.headers.get('retry-after')) > 0);
      assert.equal(c.status, 200, 'another visitor is not affected');
      const n1 = await nonces();
      assert.equal(n1.reduce((x, y) => x + y, 0) - n0.reduce((x, y) => x + y, 0), 1, 'only the other visitor\'s attempt sent a tx');
      // F4: IPv6 addresses in one /64 are one visitor; another /64 is not
      const v1 = await post(S.base, { kind: 'zero_amount' }, { ip: '2001:db8:1:2::1' });
      const v2 = await post(S.base, { kind: 'zero_amount' }, { ip: '2001:db8:1:2:ffff::9' });
      const v3 = await post(S.base, { kind: 'zero_amount' }, { ip: '2001:db8:1:3::1' });
      assert.deepEqual([v1.status, v2.status, v3.status], [200, 429, 200]);
      // F3: the request limit applies to every route (binding: 120 per 60 s per visitor key)
      const codes = await Promise.all(Array.from({ length: 130 }, () => fetch(S.base + '/healthz', { headers: { 'cf-connecting-ip': '192.0.2.44' } }).then((r) => r.status)));
      assert.ok(codes.filter((c) => c === 429).length >= 5, `expected 429s, got ${codes.filter((c) => c === 429).length}`);
      assert.equal((await fetch(S.base + '/healthz', { headers: { 'cf-connecting-ip': '192.0.2.45' } })).status, 200, 'another visitor still served');
    } finally { S.stop(); }
  });

  // ---------------- phase 3: per-IP day cap and global day cap (tightened through vars)
  await t.test('phase 3: per-IP daily cap and global daily cap', phase(3), async () => {
    const S = dev(18793, ['LIMIT_IP_INTERVAL_S:0', 'LIMIT_IP_DAY:3', 'LIMIT_GLOBAL_DAY:5']);
    try {
      const codes = [];
      for (let i = 0; i < 4; i++) codes.push((await post(S.base, { kind: 'zero_amount' }, { ip: '203.0.113.60' })).status);
      assert.deepEqual(codes, [200, 200, 200, 429], 'IP A: 3 then refused');
      const b = [];
      for (let i = 0; i < 2; i++) b.push((await post(S.base, { kind: 'zero_amount' }, { ip: '203.0.113.61' })).status);
      assert.deepEqual(b, [200, 200], 'IP B fine while the global cap has room');
      const n0 = await nonces();
      const c = await post(S.base, { kind: 'zero_amount' }, { ip: '203.0.113.62' });
      assert.equal(c.status, 429); assert.match(c.text, /for everyone/);
      assert.deepEqual(await nonces(), n0);
      assert.equal((await state(S.base)).today, 5);
    } finally { S.stop(); }
  });

  await t.test('phase 3b: global hourly cap; demo budget behind the secret header', phase(3), async () => {
    const TOKEN = 'demo-' + 'k'.repeat(40);
    const S = dev(18797, ['LIMIT_IP_INTERVAL_S:0', 'LIMIT_GLOBAL_HOUR:2', `DEMO_TOKEN:${TOKEN}`, 'LIMIT_DEMO_DAY:2']);
    try {
      const a = [];
      for (const ip of ['203.0.113.63', '203.0.113.64', '203.0.113.65']) a.push((await post(S.base, { kind: 'zero_amount' }, { ip, json: true })));
      assert.deepEqual(a.map((r) => r.status), [200, 200, 429]); assert.equal(a[2].json.code, 'global_hour');
      const n0 = await nonces();
      const wrong = await post(S.base, {}, { raw: 'kind=zero_amount', ip: '203.0.113.66', headers: { 'x-sandbox-demo': TOKEN.slice(0, -1) + 'x' }, json: true });
      assert.equal(wrong.status, 403, 'wrong demo token = normal path; no Turnstile token -> refused');
      assert.deepEqual(await nonces(), n0);
      const d = [];
      for (let i = 0; i < 3; i++) d.push(await post(S.base, {}, { raw: 'kind=zero_amount', ip: '203.0.113.67', headers: { 'x-sandbox-demo': TOKEN }, json: true }));
      assert.deepEqual(d.map((r) => r.status), [200, 200, 429], 'demo works while the public hour cap is hit, within its own budget');
      assert.equal(d[0].json.attempt.outcome, 'refused'); assert.equal(d[2].json.code, 'demo_day');
    } finally { S.stop(); }
  });

  // ---------------- phase 4: kill switch
  await t.test('phase 4: SANDBOX_OFF=1 refuses every attack, page and log stay up', phase(4), async () => {
    const S = dev(18794, ['SANDBOX_OFF:1', 'LIMIT_IP_INTERVAL_S:0']);
    try {
      const n0 = await nonces();
      for (const kind of ['zero_amount', 'hijack_after_staging', 'genuine']) {
        const r = await post(S.base, { kind }, { ip: '203.0.113.70' });
        assert.equal(r.status, 503); assert.match(r.text, /paused/);
      }
      assert.deepEqual(await nonces(), n0, 'nothing sent while off');
      const home = await (await fetch(S.base + '/')).text();
      assert.match(home, /The sandbox is paused/); assert.doesNotMatch(home, /<form/); assert.doesNotMatch(home, /<script/);
      assert.equal((await state(S.base)).off, true);
    } finally { S.stop(); }
  });

  // ---------------- phase 5: Turnstile failing secret (Cloudflare's always-fail TEST secret)
  await t.test('phase 5: a failed human check sends nothing', phase(5), async () => {
    const S = dev(18795, ['TURNSTILE_SECRET:2x0000000000000000000000000000000AA', 'LIMIT_IP_INTERVAL_S:0']);
    try {
      const n0 = await nonces();
      const r = await post(S.base, { kind: 'zero_amount' }, { ip: '203.0.113.80' });
      assert.equal(r.status, 403); assert.match(r.text, /human check did not pass/);
      assert.deepEqual(await nonces(), n0);
      assert.equal((await state(S.base)).attempts.length, 0);
    } finally { S.stop(); }
  });

  // ---------------- phase 6: a non-dev Worker refuses a local RPC (config gate)
  await t.test('phase 6: without SANDBOX_DEV the Worker refuses a non-testnet RPC', phase(6), async () => {
    const S = dev(18796, ['SANDBOX_DEV:0']);
    try {
      const h = await fetch(S.base + '/healthz');
      assert.equal(h.status, 503);
      const hj = await h.json();
      assert.equal(hj.config, false); assert.equal(hj.turnstileConfig, false, 'test Turnstile keys outside dev');
      for (const v of Object.values(hj)) assert.ok(typeof v === 'boolean' || /^\d{4}-/.test(v), 'healthz carries only booleans + time');
      const n0 = await nonces();
      const r = await post(S.base, { kind: 'zero_amount' }, { ip: '203.0.113.90', json: true });
      assert.equal(r.status, 503); assert.equal(r.json.code, 'tsconfig', 'F2: fails closed on the Turnstile TEST keys');
      assert.deepEqual(await nonces(), n0);
    } finally { S.stop(); }
  });

  await t.test('phase 6b: outside dev with real-looking Turnstile keys the next gate (RPC) still refuses', phase(6), async () => {
    const S = dev(18798, ['SANDBOX_DEV:0', 'TURNSTILE_SECRET:0x4AAAAAAAnot-a-test-key', 'TURNSTILE_SITEKEY:0x4AAAAAAAsite', 'TURNSTILE_HOSTNAME:clerk-sandbox.example.workers.dev']);
    try {
      const r = await post(S.base, { kind: 'zero_amount' }, { ip: '203.0.113.91', json: true });
      assert.equal(r.status, 503); assert.equal(r.json.code, 'config', 'POSITIVE CONTROL: the Turnstile gate passed, the RPC gate refused');
      assert.equal((await (await fetch(S.base + '/healthz')).json()).turnstileConfig, true);
    } finally { S.stop(); }
  });

  // ---------------- phase 7: an attempt cut off mid-way still leaves a public row (F8)
  await t.test('phase 7: a running row exists before the first send and is closed as a fault after a restart', phase(7), async () => {
    let S = dev(18799, ['LIMIT_IP_INTERVAL_S:0']);
    let id;
    try {
      const pending = post(S.base, { kind: 'hijack_after_staging' }, { ip: '203.0.113.95', json: true }).catch(() => null);
      for (let i = 0; i < 100 && !id; i++) {
        const s = await state(S.base);
        const r = s.attempts.find((a) => a.outcome === 'running');
        if (r) id = r.id; else await new Promise((res) => setTimeout(res, 100));
      }
      assert.ok(id, 'a running row was visible while the attempt was in flight');
      S.stop();
      await pending;
    } finally { S.stop(); }
    S = dev(18799, ['LIMIT_IP_INTERVAL_S:0'], { keep: true });
    try {
      const s = await state(S.base);
      const a = s.attempts.find((x) => x.id === id);
      assert.equal(a.outcome, 'fault'); assert.match(a.note, /interrupted/);
      assert.equal(s.counts.hijack_after_staging.faults, 1);
      assert.equal(s.attempts.filter((x) => x.outcome === 'running').length, 0);
    } finally { S.stop(); }
  });

  // ---------------- phase 8: /healthz goes 503 inside 3 days of the clerk session expiry (F5); fork time restored after
  await t.test('phase 8: healthz flags clerk sessions that expire within 3 days', phase(8), async () => {
    const snap = await pub.request({ method: 'evm_snapshot', params: [] });
    try {
      const S0 = dev(18800);
      try { assert.equal((await (await fetch(S0.base + '/healthz')).json()).sessionsValid, true, 'POSITIVE CONTROL: valid now'); } finally { S0.stop(); }
      await pub.request({ method: 'evm_increaseTime', params: [38 * 86400] }); await pub.request({ method: 'evm_mine', params: [] });
      const S = dev(18800);
      try {
        const h = await fetch(S.base + '/healthz');
        assert.equal(h.status, 503); const j = await h.json();
        assert.equal(j.sessionsValid, false); assert.equal(j.chain, true); assert.equal(j.keysAboveFloor, true);
      } finally { S.stop(); }
    } finally { await pub.request({ method: 'evm_revert', params: [snap] }); }
  });
});
