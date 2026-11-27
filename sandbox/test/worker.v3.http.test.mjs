// The PayRunV3 sandbox Worker over HTTP: wrangler dev (LOCAL ONLY) -> Durable Object 'v3' -> anvil fork with deploy.mjs --v3 done.
// Run: SANDBOX_WORKER_V3=1 SANDBOX_DEV_VARS=<dev vars from mkvars --mode fork on the v3 state> SANDBOX_FORK_STATE=<v3 state> \
//      SANDBOX_FORK_RPC=http://127.0.0.1:18551 node --test --test-concurrency=1 test/worker.v3.http.test.mjs
// Optional control: SANDBOX_DEV_VARS_V2=work/dev.vars (a PayRunV2 config): the v3-only kinds and /history/v2 must be refused there.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createPublicClient, http } from 'viem';
import { kindsFor } from '../lib/sandbox.mjs';

const ROOT = new URL('..', import.meta.url).pathname;
const VARS = process.env.SANDBOX_DEV_VARS || '', STATE = process.env.SANDBOX_FORK_STATE || '';
const RPC = process.env.SANDBOX_FORK_RPC || 'http://127.0.0.1:18551';
const skip = !process.env.SANDBOX_WORKER_V3 || !existsSync(VARS) || !existsSync(STATE);
const st = skip ? {} : JSON.parse(readFileSync(STATE, 'utf8'));
const pub = createPublicClient({ transport: http(RPC) });
const DUMMY = 'XXXX.DUMMY.TOKEN.XXXX';

function dev(port, vars) {
  const dir = `work/wr-v3-test-${port}`;
  rmSync(ROOT + dir, { recursive: true, force: true });
  execFileSync(ROOT + 'worker/scripts/dev.sh', ['start', String(port), dir], { cwd: ROOT, stdio: 'ignore', timeout: 120_000, env: { ...process.env, SANDBOX_DEV_VARS: vars } });
  return { base: `http://127.0.0.1:${port}`, stop: () => execFileSync(ROOT + 'worker/scripts/dev.sh', ['stop', String(port)], { cwd: ROOT, stdio: 'ignore' }) };
}
async function post(base, kind, { ip = '198.51.100.7', text } = {}) {
  const body = new URLSearchParams({ 'cf-turnstile-response': DUMMY, kind, ...(text ? { text } : {}) }).toString();
  const r = await fetch(base + '/attack', { method: 'POST', body, signal: AbortSignal.timeout(120_000),
    headers: { 'content-type': 'application/x-www-form-urlencoded', 'cf-connecting-ip': ip, accept: 'application/json' } });
  const t = await r.text();
  return { status: r.status, json: (() => { try { return JSON.parse(t); } catch { return null; } })(), headers: r.headers };
}

test('PayRunV3 sandbox Worker over HTTP', { skip, timeout: 900_000 }, async (t) => {
  // fork housekeeping: past the 120 s 'expired' session; empty blocks keep anvil's gas oracle near 1 gwei
  await pub.request({ method: 'evm_increaseTime', params: [200] }); await pub.request({ method: 'anvil_mine', params: ['0x20'] });
  const W = dev(8791, VARS);
  try {
    await t.test('home lists the 18 v3 kinds, says PayRunV3 + its own vendor registry, links the V2 history; strict CSP', async () => {
      const r = await fetch(W.base + '/', { headers: { 'cf-connecting-ip': '198.51.100.7' } });
      const body = await r.text();
      assert.equal(r.status, 200);
      for (const k of Object.keys(kindsFor('v3'))) assert.match(body, new RegExp(`value="${k}"`));
      assert.match(body, /A separate PayRunV3 contract/);
      assert.match(body, /href="\/history\/v2"/);
      assert.doesNotMatch(body, /0x[0-9a-fA-F]{64}(?![0-9a-fA-F])[^<]*private/i);
      assert.match(r.headers.get('content-security-policy') || '', /default-src 'none'/);
    });
    await t.test('/api/state: version v3, our registry, no keys in the public config', async () => {
      const j = await (await fetch(W.base + '/api/state', { headers: { 'cf-connecting-ip': '198.51.100.7' } })).json();
      assert.equal(j.config.version, 'v3');
      assert.equal(j.config.registry.toLowerCase(), st.registry.toLowerCase());
      const raw = JSON.stringify(j);
      // the SANDBOX_KEYS line only (the config line also holds public tx hashes, which /api/state may show)
      const line = readFileSync(VARS, 'utf8').split('\n').find((l) => l.startsWith('SANDBOX_KEYS='));
      const keys = Object.values(JSON.parse(line.slice('SANDBOX_KEYS='.length).replace(/^'|'$/g, '')));
      assert.equal(keys.length, 8, 'the dev vars hold the 8 keys (positive control for the next check)');
      assert.ok(JSON.stringify({ k: keys[0] }).includes(keys[0].slice(2)), 'the check can see a key when it is there');
      for (const k of keys) assert.ok(!raw.toLowerCase().includes(k.slice(2).toLowerCase()), 'no key material in /api/state');
    });
    await t.test('/healthz: config + chain + every SENDING key above its floor', async () => {
      const j = await (await fetch(W.base + '/healthz', { headers: { 'cf-connecting-ip': '198.51.100.7' } })).json();
      assert.equal(j.config, true); assert.equal(j.chain, true); assert.equal(j.keysAboveFloor, true); assert.equal(j.sessionsValid, true);
    });
    const ips = ['198.51.100.21', '198.51.100.22', '198.51.100.23', '198.51.100.24', '198.51.100.25'];
    for (const [i, [kind, expect]] of [['unsigned_invoice', 'VendorSignatureRequired'], ['forged_signature', 'BadVendorSignature'],
      ['edited_after_signing', 'BadVendorSignature'], ['payee_swap', 'PayeeNotRegistered'], ['hijack_after_staging', 'PaymentBlocked']].entries()) {
      await t.test(`POST /attack ${kind}: refused on chain (${expect}), recorded in the v3 log`, async () => {
        const r = await post(W.base, kind, { ip: ips[i] });
        assert.equal(r.status, 200, JSON.stringify(r.json));
        assert.equal(r.json.attempt.outcome, 'refused', JSON.stringify(r.json.attempt));
        const last = r.json.attempt.steps.at(-1);
        assert.ok(last.sent && /^0x[0-9a-f]{64}$/.test(last.hash));
        assert.ok(String(last.error).startsWith(expect), last.error);
        const rc = await pub.getTransactionReceipt({ hash: last.hash });
        assert.equal(rc.to.toLowerCase(), expect === 'PaymentBlocked' ? st.payrun.toLowerCase() : st.payrun.toLowerCase());
      });
    }
    await t.test('a visitor invoice naming Acme\'s REGISTERED wallet is refused (no Acme signature), not accepted', async () => {
      const txt = `ACME SUPPLIES LTD\nFrom: Acme Supplies Ltd\nInvoice No: INV-V3-${Date.now()}\nDue date: 2026-12-18\nAmount due: 0.03 tUSD8\nPay to: ${st.addresses.vendor_acme}`;
      const r = await post(W.base, 'payee_swap', { ip: '198.51.100.30', text: txt });
      assert.equal(r.json.attempt.outcome, 'refused');
      assert.equal(r.json.attempt.steps.at(-1).error, 'VendorSignatureRequired');
    });
    await t.test('the genuine (vendor-signed) control is accepted', async () => {
      const r = await post(W.base, 'genuine', { ip: '198.51.100.31' });
      assert.equal(r.json.attempt.outcome, 'accepted', JSON.stringify(r.json.attempt));
    });
    await t.test('unknown kind -> 400; attempt page renders the V3 error text', async () => {
      assert.equal((await post(W.base, 'drain_treasury', { ip: '198.51.100.32' })).status, 400);
      const j = await (await fetch(W.base + '/api/state', { headers: { 'cf-connecting-ip': '198.51.100.7' } })).json();
      const id = j.attempts.find((a) => a.kind === 'unsigned_invoice').id;
      const page = await (await fetch(`${W.base}/attempt/${id}`, { headers: { 'cf-connecting-ip': '198.51.100.7' } })).text();
      assert.match(page, /This vendor signs its invoices, and the line carries no signature/);
    });
    await t.test('/history/v2 is served read-only from the old instance (separate from the v3 log)', async () => {
      const r = await fetch(W.base + '/history/v2', { headers: { 'cf-connecting-ip': '198.51.100.7' } });
      const body = await r.text();
      assert.equal(r.status, 200);
      assert.match(body, /The PayRunV2 sandbox, kept as it was/);
      assert.doesNotMatch(body, /unsigned_invoice|Unsigned invoice/, 'v3 attempts are not in the v2 history');
      assert.equal((await fetch(W.base + '/history/v2/attempt/999999', { headers: { 'cf-connecting-ip': '198.51.100.7' } })).status, 404);
      const p = await fetch(W.base + '/history/v2', { method: 'POST', headers: { 'cf-connecting-ip': '198.51.100.7' } });
      assert.equal(p.status, 405, 'history is GET only');
    });
    await t.test('nothing left the sandbox treasury', async () => {
      const j = await (await fetch(W.base + '/api/state', { headers: { 'cf-connecting-ip': '198.51.100.7' } })).json();
      assert.equal(j.treasury, '90000');
    });
  } finally { W.stop(); }

  const V2VARS = process.env.SANDBOX_DEV_VARS_V2;
  await t.test('CONTROL (v2 config): the v3-only kinds are refused and there is no /history/v2', { skip: !V2VARS || !existsSync(V2VARS) }, async () => {
    const W2 = dev(8792, V2VARS);
    try {
      const r = await post(W2.base, 'unsigned_invoice', { ip: '198.51.100.40' });
      assert.equal(r.status, 400);
      assert.equal((await fetch(W2.base + '/history/v2', { headers: { 'cf-connecting-ip': '198.51.100.7' } })).status, 404);
      const home = await (await fetch(W2.base + '/', { headers: { 'cf-connecting-ip': '198.51.100.7' } })).text();
      assert.doesNotMatch(home, /value="unsigned_invoice"/);
      assert.match(home, /A separate PayRunV2 contract/);
    } finally { W2.stop(); }
  });
});
