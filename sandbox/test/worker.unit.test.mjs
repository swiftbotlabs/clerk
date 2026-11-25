// Unit checks for the Worker's pure parts: limits (defaults, prod clamps), config gate, HTML escaping. Plain `node --test`.
import test from 'node:test';
import assert from 'node:assert/strict';
import { limitsFrom, parseConfig, DEFAULT_LIMITS, ipKey, turnstileConfigError, turnstileOk, demoOk, publicConfigFrom } from '../worker/src/limits.mjs';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, symlinkSync, writeFileSync, readFileSync, lstatSync, statSync, rmSync } from 'node:fs';
import { esc, renderHome, renderAttempt } from '../worker/src/page.mjs';

const K = (c) => '0x' + c.repeat(64);
const keys = { owner: K('1'), clerk: K('2'), revoked: K('3'), expired: K('4'), stranger: K('5'), daycap: K('6'), vendor_hijack: K('7'), vendor_new: K('8') };
const A = (c) => '0x' + c.repeat(40);
const cfg = { chainId: 44005, rpc: 'https://rpc-test.qday.info', payrun: A('a'), registry: A('b'), token: A('c'), treasury: A('d'), paidInvoiceHash: K('e'),
  vendors: { acme: { id: '1', name: 'Acme Supplies Ltd' }, hijack: { id: '2', name: 'Hooli Freight' }, new: { id: '3', name: 'Initech Hosting' } },
  explorer: 'https://explorer-test.qday.info' };
const env = (o = {}) => ({ SANDBOX_CONFIG: JSON.stringify(cfg), SANDBOX_KEYS: JSON.stringify(keys), ...o });

test('limits: defaults are the plan (60 s, 30/IP/day, 300/day)', () => {
  const plan = { ipIntervalS: 60, ipDay: 30, globalDay: 300, globalHour: 30, demoDay: 40, maxQueue: 4 };
  assert.deepEqual(limitsFrom({}), plan);
  assert.deepEqual(DEFAULT_LIMITS, plan);
});
test('limits: outside dev, vars can only tighten', () => {
  const l = limitsFrom({ LIMIT_IP_DAY: '1000', LIMIT_GLOBAL_DAY: '99999', LIMIT_IP_INTERVAL_S: '0', LIMIT_QUEUE: '50', LIMIT_GLOBAL_HOUR: '999', LIMIT_DEMO_DAY: '999' });
  assert.deepEqual(l, { ipIntervalS: 60, ipDay: 30, globalDay: 300, globalHour: 30, demoDay: 40, maxQueue: 4 });
  assert.deepEqual(limitsFrom({ LIMIT_IP_DAY: '5', LIMIT_GLOBAL_DAY: '50', LIMIT_IP_INTERVAL_S: '120', LIMIT_GLOBAL_HOUR: '10' }),
    { ipIntervalS: 120, ipDay: 5, globalDay: 50, globalHour: 10, demoDay: 40, maxQueue: 4 });
});
test('limits: POSITIVE CONTROL: the same relaxing vars DO apply on a dev run', () => {
  assert.deepEqual(limitsFrom({ SANDBOX_DEV: '1', LIMIT_IP_DAY: '1000', LIMIT_GLOBAL_DAY: '1000', LIMIT_IP_INTERVAL_S: '0', LIMIT_QUEUE: '20', LIMIT_GLOBAL_HOUR: '1000' }),
    { ipIntervalS: 0, ipDay: 1000, globalDay: 1000, globalHour: 1000, demoDay: 40, maxQueue: 20 });
});
test('limits: garbage values throw', () => {
  for (const v of ['-1', '1e3', 'abc', '12345678']) assert.throws(() => limitsFrom({ LIMIT_IP_DAY: v }));
});

test('config: valid testnet config parses', () => { assert.equal(parseConfig(env()).cfg.payrun, A('a')); });
test('config: refuses funder/treasury keys, missing roles, wrong chain, wrong RPC, bad addresses', () => {
  assert.throws(() => parseConfig(env({ SANDBOX_KEYS: JSON.stringify({ ...keys, funder: K('9') }) })), /unexpected role/);
  assert.throws(() => parseConfig(env({ SANDBOX_KEYS: JSON.stringify({ ...keys, owner: undefined }) })), /owner/);
  assert.throws(() => parseConfig(env({ SANDBOX_CONFIG: JSON.stringify({ ...cfg, chainId: 1 }) })), /chainId/);
  assert.throws(() => parseConfig(env({ SANDBOX_CONFIG: JSON.stringify({ ...cfg, rpc: 'https://mainnet.example' }) })), /rpc/);
  assert.throws(() => parseConfig(env({ SANDBOX_CONFIG: JSON.stringify({ ...cfg, rpc: 'http://127.0.0.1:18546' }) })), /rpc/);
  assert.throws(() => parseConfig(env({ SANDBOX_CONFIG: JSON.stringify({ ...cfg, payrun: '0x1234' }) })), /payrun/);
  assert.throws(() => parseConfig(env({ SANDBOX_CONFIG: JSON.stringify({ ...cfg, explorer: 'javascript:alert(1)' }) })), /explorer/);
  assert.throws(() => parseConfig({}), /SANDBOX_CONFIG/);
});
test('config: a local RPC is allowed only with SANDBOX_DEV=1, and then a public one is refused', () => {
  const local = { ...cfg, rpc: 'http://127.0.0.1:18546', explorer: '' };
  assert.equal(parseConfig(env({ SANDBOX_DEV: '1', SANDBOX_CONFIG: JSON.stringify(local) })).cfg.rpc, local.rpc);
  assert.throws(() => parseConfig(env({ SANDBOX_DEV: '1' })), /rpc/);
});
test('config errors never echo key material', () => {
  try { parseConfig(env({ SANDBOX_KEYS: JSON.stringify({ ...keys, funder: K('9') }) })); } catch (e) { assert.ok(!e.message.includes('1111')); }
});

test('esc escapes every HTML-significant character', () => {
  assert.equal(esc(`<a href="x" onclick='y'>&`), '&lt;a href=&quot;x&quot; onclick=&#39;y&#39;&gt;&amp;');
});
test('rendered pages escape hostile values and carry no visitor text in the stored record', () => {
  const evil = '<img src=x onerror=alert(1)>';
  const rec = { id: 7, kind: 'payee_swap', title: evil, outcome: 'refused', at: '2026-11-25T00:00:00Z',
    steps: [{ step: evil, from: 'clerk', sent: true, hash: K('f'), status: 'reverted', error: 'PayeeNotRegistered' }], offchain: { decision: 'BLOCK', cop: 'MATCH', replacedAddress: true } };
  const page = renderAttempt({ rec, detail: { reasons: [evil], warnings: [], proposed: { vendor: evil } }, cfg: { explorer: 'https://explorer-test.qday.info' }, fresh: true });
  assert.ok(!page.includes(evil)); assert.ok(page.includes('&lt;img src=x onerror=alert(1)&gt;'));
  const home = renderHome({ state: { attempts: [rec], counts: {}, treasury: '90000', off: false }, cfg: { explorer: '', network: evil }, sitekey: '"><script>', limits: limitsFrom({}) });
  assert.ok(!home.includes(evil)); assert.ok(!home.includes('"><script>'));
});

// ---- r1 fixes
const REAL = { TURNSTILE_SECRET: '0x4AAAAAAAreal-looking-secret-value', TURNSTILE_SITEKEY: '0x4AAAAAAAreal-site-key', TURNSTILE_HOSTNAME: 'clerk-sandbox.example.workers.dev' };
test('F2: outside dev, Turnstile test keys or an empty hostname are refused', () => {
  assert.match(turnstileConfigError({ ...REAL, TURNSTILE_SECRET: '1x0000000000000000000000000000000AA' }), /secret/);
  assert.match(turnstileConfigError({ ...REAL, TURNSTILE_SECRET: '2x0000000000000000000000000000000AA' }), /secret/);
  assert.match(turnstileConfigError({ ...REAL, TURNSTILE_SITEKEY: '1x00000000000000000000AA' }), /site key/);
  assert.match(turnstileConfigError({ ...REAL, TURNSTILE_SITEKEY: '3x00000000000000000000FF' }), /site key/);
  assert.match(turnstileConfigError({ ...REAL, TURNSTILE_HOSTNAME: '' }), /HOSTNAME/);
  assert.match(turnstileConfigError({ ...REAL, TURNSTILE_SECRET: '' }), /secret/);
  assert.equal(turnstileConfigError(REAL), '');
  assert.equal(turnstileConfigError({ SANDBOX_DEV: '1', TURNSTILE_SECRET: '1x0000000000000000000000000000000AA' }), '', 'dev may use test keys');
});
const fakeFetch = (body, ok = true) => async () => ({ ok, json: async () => body });
test('F2: siteverify must say success + action attack + our hostname', async () => {
  const good = { success: true, action: 'attack', hostname: REAL.TURNSTILE_HOSTNAME };
  assert.equal(await turnstileOk(REAL, 'tok', '1.2.3.4', fakeFetch(good)), true, 'POSITIVE CONTROL: a good answer passes');
  assert.equal(await turnstileOk(REAL, 'tok', '1.2.3.4', fakeFetch({ ...good, action: 'login' })), false, 'wrong action');
  assert.equal(await turnstileOk(REAL, 'tok', '1.2.3.4', fakeFetch({ ...good, action: undefined })), false, 'no action');
  assert.equal(await turnstileOk(REAL, 'tok', '1.2.3.4', fakeFetch({ ...good, hostname: 'evil.example' })), false, 'wrong hostname');
  assert.equal(await turnstileOk(REAL, 'tok', '1.2.3.4', fakeFetch({ ...good, success: false })), false);
  assert.equal(await turnstileOk(REAL, 'tok', '1.2.3.4', fakeFetch(good, false)), false, 'HTTP error');
  assert.equal(await turnstileOk(REAL, 'tok', '1.2.3.4', async () => { throw new Error('net'); }), false, 'network error');
  assert.equal(await turnstileOk(REAL, '', '1.2.3.4', fakeFetch(good)), false, 'empty token');
  assert.equal(await turnstileOk({ ...REAL, TURNSTILE_SECRET: '1x0000000000000000000000000000000AA' }, 'tok', '1.2.3.4', fakeFetch(good)), false, 'test secret outside dev');
});
test('F4: IPv6 is grouped by /64, IPv4 kept, junk refused', () => {
  assert.equal(ipKey('203.0.113.7'), '203.0.113.7');
  assert.equal(ipKey('2001:db8:1:2:aaaa:bbbb:cccc:dddd'), '2001:db8:1:2::/64');
  assert.equal(ipKey('2001:DB8:1:2::1'), ipKey('2001:db8:1:2:ffff::9'));
  assert.notEqual(ipKey('2001:db8:1:2::1'), ipKey('2001:db8:1:3::1'));
  assert.equal(ipKey('2001:0db8:0001:0002::1'), '2001:db8:1:2::/64');
  for (const bad of ['', 'junk', '1.2.3', 'fe80::1%eth0', '1::2::3']) assert.equal(ipKey(bad), '', bad);
});
test('F4: demo header is checked against DEMO_TOKEN (>= 32 chars)', async () => {
  const tok = 'd'.repeat(40);
  assert.equal(await demoOk({ DEMO_TOKEN: tok }, tok), true, 'POSITIVE CONTROL');
  assert.equal(await demoOk({ DEMO_TOKEN: tok }, tok + 'x'), false);
  assert.equal(await demoOk({ DEMO_TOKEN: tok }, 'd'.repeat(39) + 'e'), false);
  assert.equal(await demoOk({ DEMO_TOKEN: tok }, ''), false);
  assert.equal(await demoOk({ DEMO_TOKEN: tok }, null), false);
  assert.equal(await demoOk({ DEMO_TOKEN: 'short' }, 'short'), false, 'short secret disables the demo budget');
  assert.equal(await demoOk({}, 'anything'), false);
});
test('F3: public config is parsed in the Worker and carries no keys', () => {
  const c = publicConfigFrom(env());
  assert.equal(c.payrun, A('a'));
  assert.ok(!JSON.stringify(c).includes('1111111111'));
  assert.equal(publicConfigFrom({}), null);
});
const ROOT = new URL('..', import.meta.url).pathname;
const haveFork = existsSync(ROOT + 'work/fork-state.json') && existsSync(ROOT + 'work/fork-keys.json');
test('F7: mkvars refuses a symlinked --out and writes a fresh 0600 file', { skip: !haveFork }, () => {
  const d = mkdtempSync(ROOT + 'work/mkvars-t-');
  try {
    const target = d + '/target.txt'; writeFileSync(target, 'untouched');
    symlinkSync(target, d + '/link');
    const r = spawnSync('node', [ROOT + 'worker/mkvars.mjs', '--mode', 'fork', '--state', ROOT + 'work/fork-state.json', '--keys', ROOT + 'work/fork-keys.json', '--out', d + '/link'], { encoding: 'utf8' });
    assert.notEqual(r.status, 0); assert.match(r.stderr, /symlink/);
    assert.equal(readFileSync(target, 'utf8'), 'untouched'); assert.ok(lstatSync(d + '/link').isSymbolicLink());
    const ok = spawnSync('node', [ROOT + 'worker/mkvars.mjs', '--mode', 'fork', '--state', ROOT + 'work/fork-state.json', '--keys', ROOT + 'work/fork-keys.json', '--out', d + '/vars'], { encoding: 'utf8' });
    assert.equal(ok.status, 0, 'POSITIVE CONTROL: a normal path works');
    assert.equal(statSync(d + '/vars').mode & 0o777, 0o600);
    assert.ok(!ok.stdout.match(/0x[0-9a-f]{64}/i), 'no key printed');
  } finally { rmSync(d, { recursive: true, force: true }); }
});
