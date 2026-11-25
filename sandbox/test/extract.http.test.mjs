// /extract end to end over HTTP: wrangler dev (LOCAL ONLY, no Workers AI binding: dev.sh strips it) -> Durable Object rate limits
// -> registry reads on the anvil fork. Proves: the page renders, the deterministic fallback is labelled, the rules decide, NO chain
// transaction is ever sent, the limits hold and never touch the attack budget, and the kill switch works.
// Run: SANDBOX_WORKER=1 node --test --test-concurrency=1 test/extract.http.test.mjs   (needs what worker.http.test.mjs needs)
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createPublicClient, http } from 'viem';

const ROOT = new URL('..', import.meta.url).pathname;
const RPC = 'http://127.0.0.1:18546';
const skip = !process.env.SANDBOX_WORKER || !existsSync(ROOT + 'work/fork-state.json') || !existsSync(ROOT + 'work/dev.vars');
const st = skip ? {} : JSON.parse(readFileSync(ROOT + 'work/fork-state.json', 'utf8'));
const pub = createPublicClient({ transport: http(RPC) });
const ONLY = process.env.PHASES ? process.env.PHASES.split(',') : null;
const phase = (n) => ({ skip: ONLY !== null && !ONLY.includes(String(n)) });

function dev(port, vars = []) {
  const dir = `work/wr-xtest-${port}`;
  rmSync(ROOT + dir, { recursive: true, force: true });
  execFileSync(ROOT + 'worker/scripts/dev.sh', ['start', String(port), dir, ...vars.flatMap((v) => ['--var', v])], { cwd: ROOT, stdio: 'ignore', timeout: 120_000 });
  return { base: `http://127.0.0.1:${port}`, stop: () => execFileSync(ROOT + 'worker/scripts/dev.sh', ['stop', String(port)], { cwd: ROOT, stdio: 'ignore' }) };
}
async function post(base, text, { ip = '198.51.100.20', origin, headers = {} } = {}) {
  const r = await fetch(base + '/extract', { method: 'POST', signal: AbortSignal.timeout(60_000), body: new URLSearchParams({ 'cf-turnstile-response': 'XXXX.DUMMY.TOKEN.XXXX', text }).toString(),
    headers: { 'content-type': 'application/x-www-form-urlencoded', 'cf-connecting-ip': ip, ...(origin ? { origin } : {}), ...headers } });
  return { status: r.status, text: await r.text(), headers: r.headers };
}
const nonces = async () => Promise.all(Object.values(st.addresses).map((a) => pub.getTransactionCount({ address: a })));
const sample = async (base, k) => {
  const body = await (await fetch(`${base}/extract?sample=${k}`)).text();
  const m = /<textarea[^>]*>([\s\S]*?)<\/textarea>/.exec(body);
  return m[1].replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
};

test('extractor demo over HTTP', { skip, timeout: 900_000 }, async (t) => {
  await t.test('phase 1: page, fallback label, rules verdicts, no chain tx, attack budget untouched', phase(1), async () => {
    const S = dev(18801, ['EXTRACT_IP_INTERVAL_S:0']);
    try {
      const g = await fetch(S.base + '/extract');
      const page = await g.text();
      assert.equal(g.status, 200);
      assert.match(g.headers.get('content-security-policy'), /default-src 'none'.*frame-ancestors 'none'/);
      assert.equal(g.headers.get('access-control-allow-origin'), null);
      assert.deepEqual([...page.matchAll(/<script[^>]*>/g)].map((m) => m[0]), ['<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer>']);
      assert.match(page, /data-action="extract"/);
      const genuine = await sample(S.base, 'genuine');
      assert.ok(genuine.includes(st.addresses.vendor_acme), 'the genuine sample names the registered wallet read from the chain');
      const block0 = await pub.getBlockNumber(), n0 = await nonces();
      const before = await (await fetch(S.base + '/api/state')).json();
      const a = await post(S.base, await sample(S.base, 'payee_swap'));
      assert.equal(a.status, 200, a.text.slice(0, 300));
      assert.match(a.text, /What the deterministic extractor proposed/);
      assert.match(a.text, /model is not connected/);
      assert.match(a.text, /Stopped/);
      const b = await post(S.base, genuine);
      assert.equal(b.status, 200);
      assert.match(b.text, /Would be staged/);         // positive control: the rules pass a genuine invoice
      const c = await post(S.base, await sample(S.base, 'lookalike'));
      assert.doesNotMatch(c.text, /Would be staged/);
      assert.equal(await pub.getBlockNumber(), block0, 'no block was mined: nothing was sent');
      assert.deepEqual(await nonces(), n0, 'no sandbox key sent a transaction');
      await new Promise((r) => setTimeout(r, 6_000));   // /api/state is cached 5 s per isolate: read a fresh copy
      const after = await (await fetch(S.base + '/api/state')).json();
      assert.deepEqual(after.counts, before.counts, 'the attack counters did not move');
      assert.equal(after.attempts.length, before.attempts.length);
      const x = await post(S.base, '<script>alert(1)</script>\nFrom: Acme Supplies Ltd');
      assert.equal(x.status, 200);
      assert.doesNotMatch(x.text, /<script>alert/);
    } finally { S.stop(); }
  });

  await t.test('phase 2: limits (interval, per-visitor day, global day) and gates', phase(2), async () => {
    const S = dev(18802, ['EXTRACT_IP_DAY:2', 'EXTRACT_GLOBAL_DAY:3', 'EXTRACT_PACE_PCT:0']);
    try {
      const txt = 'From: Acme Supplies Ltd\nInvoice No: INV-1\nAmount due: 0.05 tUSD8';
      assert.equal((await post(S.base, txt, { ip: '203.0.113.1' })).status, 200);
      const iv = await post(S.base, txt, { ip: '203.0.113.1' });
      assert.equal(iv.status, 429); assert.match(iv.text, /few seconds/); assert.ok(Number(iv.headers.get('retry-after')) > 0);
      assert.equal((await post(S.base, txt, { ip: '203.0.113.2' })).status, 200);
      assert.equal((await post(S.base, txt, { ip: '203.0.113.3' })).status, 200);
      const gd = await post(S.base, txt, { ip: '203.0.113.4' });
      assert.equal(gd.status, 429); assert.match(gd.text, /model allocation for everyone/);
      assert.equal((await post(S.base, txt, { ip: '203.0.113.5', origin: 'https://evil.test' })).status, 403);
      assert.equal((await post(S.base, '', { ip: '203.0.113.6' })).status, 400);
      assert.equal((await post(S.base, 'q'.repeat(4097), { ip: '203.0.113.7' })).status, 413);
    } finally { S.stop(); }
    const D = dev(18803, ['EXTRACT_IP_INTERVAL_S:0', 'EXTRACT_IP_DAY:2']);
    try {
      const txt = 'From: Acme Supplies Ltd';
      assert.equal((await post(D.base, txt, { ip: '2001:db8:1:2::1' })).status, 200);
      assert.equal((await post(D.base, txt, { ip: '2001:db8:1:2::99' })).status, 200);     // same /64 = same visitor
      const dd = await post(D.base, txt, { ip: '2001:db8:1:2:ffff::1' });
      assert.equal(dd.status, 429); assert.match(dd.text, /today/);
    } finally { D.stop(); }
  });

  await t.test('phase 3: kill switch (EXTRACT_OFF) stops /extract only', phase(3), async () => {
    const S = dev(18804, ['EXTRACT_OFF:1']);
    try {
      const r = await post(S.base, 'From: Acme Supplies Ltd');
      assert.equal(r.status, 503); assert.match(r.text, /paused/);
      assert.match(await (await fetch(S.base + '/extract')).text(), /extractor demo is paused/);
      assert.equal((await fetch(S.base + '/')).status, 200);
    } finally { S.stop(); }
  });

  await t.test('phase 4: per-/48 hour cap, demo budget (Bearer), global hourly cap', phase(4), async () => {
    const TOKEN = 'xtest-' + 'd'.repeat(40);
    const S = dev(18805, ['EXTRACT_IP_INTERVAL_S:0', 'EXTRACT_NET48_HOUR:2', 'EXTRACT_DEMO_DAY:1', `DEMO_TOKEN:${TOKEN}`, 'EXTRACT_GLOBAL_HOUR:4', 'EXTRACT_PACE_PCT:0']);
    try {
      const txt = 'From: Acme Supplies Ltd';
      assert.equal((await post(S.base, txt, { ip: '2001:db8:aa:1::1' })).status, 200);
      assert.equal((await post(S.base, txt, { ip: '2001:db8:aa:2::1' })).status, 200);       // another /64, same /48
      const nh = await post(S.base, txt, { ip: '2001:db8:aa:3::1' });
      assert.equal(nh.status, 429, 'the third /64 in the same /48 within the hour must be refused'); assert.match(nh.text, /network block/);
      const d1 = await post(S.base, txt, { ip: '198.51.100.40', headers: { authorization: 'Bearer ' + TOKEN } });
      assert.equal(d1.status, 200, d1.text.slice(0, 200));
      const d2 = await post(S.base, txt, { ip: '198.51.100.41', headers: { authorization: 'Bearer ' + TOKEN } });
      assert.equal(d2.status, 429, 'the demo budget (1/day here) must hold'); assert.match(d2.text, /Demo budget used/);
      assert.equal((await post(S.base, txt, { ip: '198.51.100.42' })).status, 200);         // 3rd visitor try this hour (demo not counted)
      assert.equal((await post(S.base, txt, { ip: '198.51.100.43' })).status, 200);         // 4th
      const gh = await post(S.base, txt, { ip: '198.51.100.44' });
      assert.equal(gh.status, 429, 'the global hourly cap (4 here) must hold'); assert.match(gh.text, /this hour/);
      assert.ok(Number(gh.headers.get('retry-after')) > 0);
    } finally { S.stop(); }
  });

  await t.test('phase 5: pacing keeps part of the daily budget for later hours', phase(5), async () => {
    const S = dev(18806, ['EXTRACT_IP_INTERVAL_S:0', 'EXTRACT_GLOBAL_DAY:24', 'EXTRACT_PACE_PCT:100']);
    try {
      const h0 = new Date().getUTCHours();
      let ok = 0, last = null;
      for (let i = 0; i < 25; i++) {
        last = await post(S.base, 'From: Acme Supplies Ltd', { ip: `198.51.100.${100 + i}` });
        if (last.status !== 200) break;
        ok++;
      }
      const h1 = new Date().getUTCHours();
      assert.equal(last.status, 429, 'pacing never refused');
      assert.match(last.text, h0 === 23 ? /this hour|for everyone/ : /this hour/);
      assert.ok(ok === h0 + 1 || ok === h1 + 1, `paced cap: ${ok} tries at UTC hour ${h0}..${h1} (expected hour + 1)`);
    } finally { S.stop(); }
  });
});
