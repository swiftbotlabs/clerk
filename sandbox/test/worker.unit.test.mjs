// Unit checks for the Worker's pure parts: limits (defaults, prod clamps), config gate, HTML escaping. Plain `node --test`.
import test from 'node:test';
import assert from 'node:assert/strict';
import { limitsFrom, parseConfig, DEFAULT_LIMITS } from '../worker/src/limits.mjs';
import { esc, renderHome, renderAttempt } from '../worker/src/page.mjs';

const K = (c) => '0x' + c.repeat(64);
const keys = { owner: K('1'), clerk: K('2'), revoked: K('3'), expired: K('4'), stranger: K('5'), daycap: K('6'), vendor_hijack: K('7'), vendor_new: K('8') };
const A = (c) => '0x' + c.repeat(40);
const cfg = { chainId: 44005, rpc: 'https://rpc-test.qday.info', payrun: A('a'), registry: A('b'), token: A('c'), treasury: A('d'), paidInvoiceHash: K('e'),
  vendors: { acme: { id: '1', name: 'Acme Supplies Ltd' }, hijack: { id: '2', name: 'Hooli Freight' }, new: { id: '3', name: 'Initech Hosting' } },
  explorer: 'https://explorer-test.qday.info' };
const env = (o = {}) => ({ SANDBOX_CONFIG: JSON.stringify(cfg), SANDBOX_KEYS: JSON.stringify(keys), ...o });

test('limits: defaults are the plan (60 s, 30/IP/day, 300/day)', () => {
  assert.deepEqual(limitsFrom({}), { ipIntervalS: 60, ipDay: 30, globalDay: 300, maxQueue: 4 });
  assert.deepEqual(DEFAULT_LIMITS, { ipIntervalS: 60, ipDay: 30, globalDay: 300, maxQueue: 4 });
});
test('limits: outside dev, vars can only tighten', () => {
  const l = limitsFrom({ LIMIT_IP_DAY: '1000', LIMIT_GLOBAL_DAY: '99999', LIMIT_IP_INTERVAL_S: '0', LIMIT_QUEUE: '50' });
  assert.deepEqual(l, { ipIntervalS: 60, ipDay: 30, globalDay: 300, maxQueue: 4 });
  assert.deepEqual(limitsFrom({ LIMIT_IP_DAY: '5', LIMIT_GLOBAL_DAY: '50', LIMIT_IP_INTERVAL_S: '120' }), { ipIntervalS: 120, ipDay: 5, globalDay: 50, maxQueue: 4 });
});
test('limits: POSITIVE CONTROL: the same relaxing vars DO apply on a dev run', () => {
  assert.deepEqual(limitsFrom({ SANDBOX_DEV: '1', LIMIT_IP_DAY: '1000', LIMIT_GLOBAL_DAY: '1000', LIMIT_IP_INTERVAL_S: '0', LIMIT_QUEUE: '20' }),
    { ipIntervalS: 0, ipDay: 1000, globalDay: 1000, maxQueue: 20 });
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
