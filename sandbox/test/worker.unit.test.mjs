// Unit checks for the Worker's pure parts: limits (defaults, prod clamps), config gate, HTML escaping. Plain `node --test`.
import test from 'node:test';
import assert from 'node:assert/strict';
import { limitsFrom, parseConfig, DEFAULT_LIMITS, ipKey, net48Key, turnstileConfigError, turnstileOk, demoOk, publicConfigFrom } from '../worker/src/limits.mjs';
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
  const plan = { ipIntervalS: 60, ipDay: 30, globalDay: 300, globalHour: 30, net48Hour: 10, demoDay: 40, maxQueue: 4 };
  assert.deepEqual(limitsFrom({}), plan);
  assert.deepEqual(DEFAULT_LIMITS, plan);
});
test('limits: outside dev, vars can only tighten', () => {
  const l = limitsFrom({ LIMIT_IP_DAY: '1000', LIMIT_GLOBAL_DAY: '99999', LIMIT_IP_INTERVAL_S: '0', LIMIT_QUEUE: '50', LIMIT_GLOBAL_HOUR: '999', LIMIT_DEMO_DAY: '999' });
  assert.deepEqual(l, { ipIntervalS: 60, ipDay: 30, globalDay: 300, globalHour: 30, net48Hour: 10, demoDay: 40, maxQueue: 4 });
  assert.deepEqual(limitsFrom({ LIMIT_IP_DAY: '5', LIMIT_GLOBAL_DAY: '50', LIMIT_IP_INTERVAL_S: '120', LIMIT_GLOBAL_HOUR: '10' }),
    { ipIntervalS: 120, ipDay: 5, globalDay: 50, globalHour: 10, net48Hour: 10, demoDay: 40, maxQueue: 4 });
});
test('limits: POSITIVE CONTROL: the same relaxing vars DO apply on a dev run', () => {
  assert.deepEqual(limitsFrom({ SANDBOX_DEV: '1', LIMIT_IP_DAY: '1000', LIMIT_GLOBAL_DAY: '1000', LIMIT_IP_INTERVAL_S: '0', LIMIT_QUEUE: '20', LIMIT_GLOBAL_HOUR: '1000' }),
    { ipIntervalS: 0, ipDay: 1000, globalDay: 1000, globalHour: 1000, net48Hour: 10, demoDay: 40, maxQueue: 20 });
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

test('R2-1: IPv6 /48 key (IPv4 has none)', () => {
  assert.equal(net48Key('2001:db8:1:2::1'), '2001:db8:1::/48');
  assert.equal(net48Key('2001:db8:1:ffff:1::9'), net48Key('2001:DB8:0001::5'));
  assert.notEqual(net48Key('2001:db8:1::1'), net48Key('2001:db8:2::1'));
  assert.equal(net48Key('203.0.113.7'), '');
  assert.equal(net48Key('junk::1::2'), '');
  assert.deepEqual(limitsFrom({ LIMIT_NET48_HOUR: '50' }).net48Hour, 10, 'cannot be raised outside dev');
});

// ---- r7: the PayRunV3 sandbox config (version 'v3': registrar + vendor_acme keys, our own registry, the V2 log kept as history)
import { WORKER_ROLES, versionOf } from '../worker/src/limits.mjs';
import { ROLES_FOR, SENDERS_FOR, kindsFor, KINDS } from '../lib/sandbox.mjs';
import { renderHistory } from '../worker/src/page.mjs';
const keys3 = { owner: K('1'), clerk: K('2'), revoked: K('3'), expired: K('4'), stranger: K('5'), daycap: K('6'), registrar: K('7'), vendor_acme: K('8') };
const cfg3 = { ...cfg, version: 'v3', history: { v2: { payrun: A('f') } } };
const env3 = (o = {}) => ({ SANDBOX_CONFIG: JSON.stringify(cfg3), SANDBOX_KEYS: JSON.stringify(keys3), ...o });

test('v3: the Worker role lists agree with lib/sandbox.mjs; vendor_acme signs but never sends', () => {
  assert.deepEqual([...WORKER_ROLES.v2], ROLES_FOR.v2); assert.deepEqual([...WORKER_ROLES.v3], ROLES_FOR.v3);
  assert.ok(!SENDERS_FOR.v3.includes('vendor_acme')); assert.equal(SENDERS_FOR.v3.length, 7); assert.equal(SENDERS_FOR.v2.length, 8);
});
test('v3: kinds 15-17 exist only in v3; every kind has a menu line', () => {
  assert.equal(Object.keys(kindsFor('v2')).length, 15); assert.equal(Object.keys(kindsFor('v3')).length, 18);
  assert.ok(!('unsigned_invoice' in kindsFor('v2'))); assert.ok('edited_after_signing' in kindsFor('v3'));
  assert.equal(Object.keys(kindsFor(undefined)).length, 15, 'no version = the V2 sandbox');
});
test('v3 config: parses with the v3 roles; refuses v2 roles, a funder key, QDay\'s registry, an unknown version, a bad history', () => {
  assert.equal(parseConfig(env3()).cfg.version, 'v3');
  assert.equal(versionOf(parseConfig(env()).cfg), 'v2', 'the 25 Nov config (no version) is v2');
  assert.throws(() => parseConfig(env3({ SANDBOX_KEYS: JSON.stringify(keys) })), /registrar|unexpected role/);
  assert.throws(() => parseConfig(env3({ SANDBOX_KEYS: JSON.stringify({ ...keys3, funder: K('9') }) })), /unexpected role/);
  assert.throws(() => parseConfig(env({ SANDBOX_KEYS: JSON.stringify(keys3) })), /vendor_hijack|unexpected role/, 'v2 config refuses v3 keys');
  assert.throws(() => parseConfig(env3({ SANDBOX_CONFIG: JSON.stringify({ ...cfg3, registry: '0xF45E7f39Caba1d2055f613970575a7e7069636Be' }) })), /v3 registry/);
  assert.throws(() => parseConfig(env3({ SANDBOX_CONFIG: JSON.stringify({ ...cfg3, version: 'v9' }) })), /version/);
  assert.throws(() => parseConfig(env3({ SANDBOX_CONFIG: JSON.stringify({ ...cfg3, history: { v2: { payrun: 'javascript:1' } } }) })), /history/);
  assert.throws(() => parseConfig(env3({ SANDBOX_CONFIG: JSON.stringify({ ...cfg3, history: { v1: { payrun: A('f') } } }) })), /history/);
  assert.throws(() => parseConfig(env({ SANDBOX_CONFIG: JSON.stringify({ ...cfg, history: { v2: { payrun: A('f') } } }) })), /history/, 'history only on v3');
});
test('v3 public config: version + history, no keys', () => {
  const p = publicConfigFrom(env3());
  assert.equal(p.version, 'v3'); assert.equal(p.history.v2.payrun, A('f'));
  assert.ok(!JSON.stringify(p).includes('1111111111111111'));
});
test('v3 pages: home shows the 18 kinds and the history link; history rows link under /history/v2 and escape values', () => {
  const state = { attempts: [], counts: {}, treasury: '90000', off: false };
  const h = renderHome({ state, cfg: publicConfigFrom(env3()), sitekey: 'x', limits: limitsFrom({}) });
  for (const k of Object.keys(kindsFor('v3'))) assert.match(h, new RegExp(`value="${k}"`));
  assert.match(h, /href="\/history\/v2"/); assert.match(h, /PayRunV3/);
  const h2 = renderHome({ state, cfg: publicConfigFrom(env()), sitekey: 'x', limits: limitsFrom({}) });
  assert.doesNotMatch(h2, /value="unsigned_invoice"|\/history\/v2/, 'v2 page unchanged');
  const rec = { id: 3, kind: 'payee_swap', title: '<script>x</script>', outcome: 'refused', at: '2026-11-25T10:00:00Z', steps: [{ sent: true, hash: '0x' + 'a'.repeat(64), status: 'reverted', error: 'PayeeNotRegistered' }] };
  const hist = renderHistory({ state: { attempts: [rec] }, cfg: { ...publicConfigFrom(env3()), payrun: A('f') } });
  assert.match(hist, /href="\/history\/v2\/attempt\/3"/); assert.doesNotMatch(hist, /<script>x/); assert.doesNotMatch(hist, /href="\/attempt\//);
});

// r9: the seeded genuine payment (seed_sandbox.mjs pay -> state.genuine_paid -> mkvars seed.genuine)
const GEN = { attempt: 20, run: '21', stageTx: '0x' + 'b'.repeat(64), paidTx: '0x' + 'c'.repeat(64), amount: '20000', paidAt: '2026-11-29T10:00:00.000Z' };
const cfg3g = { ...cfg3, seed: { deployTx: '0x' + 'd'.repeat(64), genuine: GEN } };
const env3g = (o = {}) => ({ SANDBOX_CONFIG: JSON.stringify(cfg3g), SANDBOX_KEYS: JSON.stringify(keys3), ...o });
test('r9 config: seed.genuine parses on v3, refuses bad shapes and v2', () => {
  assert.equal(parseConfig(env3g()).cfg.seed.genuine.run, '21');
  for (const bad of [{ ...GEN, paidTx: 'javascript:1' }, { ...GEN, attempt: '20' }, { ...GEN, attempt: 0 }, { ...GEN, run: '1e9' }, { ...GEN, amount: '-1' },
    { ...GEN, stageTx: '0x12' }, { ...GEN, paidAt: '<b>' }, null])
    assert.throws(() => parseConfig(env3g({ SANDBOX_CONFIG: JSON.stringify({ ...cfg3, seed: { genuine: bad } }) })), /seed\.genuine/);
  assert.throws(() => parseConfig(env({ SANDBOX_CONFIG: JSON.stringify({ ...cfg, seed: { genuine: GEN } }) })), /seed\.genuine/, 'v2 never carries it');
  assert.equal(publicConfigFrom(env3g()).seed.genuine.paidTx, GEN.paidTx, '/api/state config shows it');
});
test('r9 page: the one Paid block, the paid log row, the genuine row says 1 paid; without seed.genuine none of it (control)', () => {
  const rec = { id: 20, kind: 'genuine', title: 'Control', outcome: 'accepted', at: '2026-11-29T09:59:00Z', steps: [{ sent: true, hash: GEN.stageTx, status: 'success' }] };
  const other = { id: 19, kind: 'payee_swap', title: 'swap', outcome: 'refused', at: '2026-11-29T09:58:00Z', steps: [{ sent: true, hash: '0x' + 'e'.repeat(64), status: 'reverted', error: 'PayeeNotRegistered' }] };
  const state = { attempts: [rec, other], counts: { genuine: { attempts: 1, refused: 0, accepted: 1, faults: 0 } }, treasury: '70000', off: false };
  const cfgP = { ...publicConfigFrom(env3g()), explorer: 'https://explorer-test.qday.info' };
  const h = renderHome({ state, cfg: cfgP, sitekey: 'x', limits: limitsFrom({}) });
  assert.match(h, /The one payment: a genuine invoice/);
  assert.equal(h.split(`/tx/${GEN.paidTx}`).length - 1, 2, 'paid tx linked in the block and in the log row');
  assert.match(h, /1 accepted, 1 paid/); assert.match(h, /0\.02 paid to the one genuine invoice/);
  assert.equal((h.match(/Paid by the owner/g) || []).length, 1, 'only the genuine attempt #20 row carries the Paid note');
  const att = renderAttempt({ rec, cfg: cfgP });
  assert.match(att, new RegExp(`/tx/${GEN.paidTx}`));
  assert.doesNotMatch(renderAttempt({ rec: { ...rec, id: 21 }, cfg: cfgP }), /c{64}/, 'another genuine attempt is not marked paid');
  const h0 = renderHome({ state, cfg: { ...publicConfigFrom(env3()), explorer: 'https://explorer-test.qday.info' }, sitekey: 'x', limits: limitsFrom({}) });
  assert.doesNotMatch(h0, /The one payment|Paid by the owner|1 paid/, 'control: no seed.genuine -> nothing claims a payment');
  const hist = renderHistory({ state: { attempts: [rec] }, cfg: { ...cfgP, version: 'v2', payrun: A('f'), history: null } });
  assert.doesNotMatch(hist, /Paid by the owner/, 'the V2 history never shows the V3 payment');
});
