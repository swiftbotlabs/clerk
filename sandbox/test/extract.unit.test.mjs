// The extractor demo (/extract): model reply parsing, fallback, the model gets no tools/secrets, and the POST handler's gates.
// Plain `node --test`; no network (Turnstile siteverify and the model are fakes).
import test from 'node:test';
import assert from 'node:assert/strict';
import { parseModelLine, proposeLine, handleExtract, renderExtract, extractLimitsFrom, EXTRACT_LIMITS, sampleText, MODEL, vendorRegistry, _resetRegistryCache, pacedDayCap } from '../worker/src/extract.mjs';
import { checkLine } from '../lib/check.mjs';

const A = (c) => '0x' + c.repeat(40);
const ACME = '0x7a0fC255948b4300c92cBc1f77371819803E5B80';
const cfg = { network: 'Aevum testnet', registry: A('b'), explorer: 'https://explorer-test.qday.info',
  vendors: { acme: { id: '1820', name: 'Acme Supplies Ltd' }, hijack: { id: '1821', name: 'Hooli Freight' }, new: { id: '1822', name: 'Initech Hosting' } },
  addresses: { vendor_acme: ACME } };
const REG = [['Acme Supplies Ltd', ACME], ['Hooli Freight', A('1')], ['Initech Hosting', A('2')]];
const SECRETS = { TURNSTILE_SECRET: 'SECRET-turnstile-0123456789abcdef', DEMO_TOKEN: 'SECRET-demo-0123456789abcdef0123456789', SANDBOX_KEYS: '{"owner":"0x' + 'ab'.repeat(32) + '"}' };
const PROD = { TURNSTILE_SITEKEY: '0x4AAAAAAGSFvstMem96981N', TURNSTILE_HOSTNAME: 'clerk-sandbox.example.dev', ...SECRETS };
const atk = '0x5eA7fF0e3B2d1c4A8b9E6f7D0c1B2a3E4f5D6c7B';

function fakeAI(reply, seen = []) {
  return { run: async (model, input) => { seen.push({ model, input }); return typeof reply === 'function' ? reply(input) : { response: reply }; } };
}
function siteverify(action = 'extract', hostname = PROD.TURNSTILE_HOSTNAME) {
  return async (url) => { assert.equal(url, 'https://challenges.cloudflare.com/turnstile/v0/siteverify'); return new Response(JSON.stringify({ success: true, action, hostname })); };
}
const stubOk = { calls: 0, async extractReserve() { this.calls++; return { status: 200 }; } };
const html = (body, status = 200) => new Response(body, { status, headers: { 'content-type': 'text/html' } });
const refuse = (code, status) => new Response(JSON.stringify({ code }), { status });
function req(fields, { origin = 'https://sbx.test', ct = 'application/x-www-form-urlencoded', ip = '198.51.100.7', body, headers = {} } = {}) {
  return new Request('https://sbx.test/extract', { method: 'POST', body: body ?? new URLSearchParams({ 'cf-turnstile-response': 'tok', ...fields }).toString(),
    headers: { 'content-type': ct, 'cf-connecting-ip': ip, ...(origin ? { origin } : {}), ...headers } });
}
async function run(r, env, { stub = stubOk, registry = async () => REG, verify = siteverify() } = {}) {
  const f = globalThis.fetch; globalThis.fetch = verify;
  try { return await handleExtract(r, env, { stub, cfg, html, refuse, registry }); } finally { globalThis.fetch = f; }
}

test('parseModelLine: keeps only the six string fields, trimmed and capped', () => {
  const l = parseModelLine('Sure! Here it is: {"vendor":"Acme Supplies Ltd","wallet":"' + atk + '","amount":"0.05","currency":"tUSD8","reference":"INV-1","due_date":"2026-12-18","tool":"pay","extra":{"a":1}} hope that helps');
  assert.deepEqual(Object.keys(l), ['vendor', 'wallet', 'amount', 'currency', 'reference', 'due_date']);
  assert.equal(l.wallet, atk);
  assert.equal(parseModelLine('{"vendor":"' + 'x'.repeat(500) + '"}').vendor.length, 120);
  assert.equal(parseModelLine('{"vendor":"Acme\\u202eLtd\\u0000"}').vendor, 'Acme Ltd');   // JSON-escaped bidi override + NUL
  assert.equal(parseModelLine('{"amount":12.5}').amount, '12.5');
  assert.equal(parseModelLine('{"amount":{"x":1},"vendor":["a"]}'), null);   // non-strings dropped -> nothing usable
  for (const bad of ['', 'no json here', '[1,2]', '{"vendor":', null, 42, '{}']) assert.equal(parseModelLine(bad), null, String(bad));
});

test('proposeLine: the model gets no tools and no secrets; its line is used as proposed', async () => {
  const seen = [];
  const reply = JSON.stringify({ vendor: 'Acme Supplies Ltd', wallet: atk, amount: '0.05', currency: 'tUSD8', reference: 'INV-4821', due_date: '2026-12-18' });
  const p = await proposeLine({ AI: fakeAI(reply, seen), ...SECRETS }, 'invoice text');
  assert.equal(p.source, 'model');
  assert.equal(p.line.wallet, atk);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].model, MODEL);
  assert.deepEqual(Object.keys(seen[0].input).sort(), ['max_tokens', 'messages', 'temperature']);
  const sent = JSON.stringify(seen[0].input);
  for (const v of Object.values(SECRETS)) assert.ok(!sent.includes(v), 'a secret reached the model');
  assert.doesNotMatch(sent, /"tools"|"functions"|tool_choice/);
});

test('proposeLine: falls back to the deterministic extractor (no binding, error, timeout, junk reply) and says so', async () => {
  const text = 'ACME\nFrom: Acme Supplies Ltd\nInvoice No: INV-9\nAmount due: 0.05 tUSD8\nPay to: ' + atk;
  const none = await proposeLine({}, text);
  assert.equal(none.source, 'rules'); assert.match(none.note, /not connected/); assert.equal(none.line.wallet, atk);
  const err = await proposeLine({ AI: { run: async () => { throw new Error('quota'); } } }, text);
  assert.equal(err.source, 'rules'); assert.match(err.note, /unavailable/);
  const slow = await proposeLine({ AI: { run: () => new Promise(() => {}) } }, text, { timeoutMs: 30 });
  assert.equal(slow.source, 'rules'); assert.match(slow.note, /too long/);
  const junk = await proposeLine({ AI: fakeAI('I cannot help with that.') }, text);
  assert.equal(junk.source, 'rules'); assert.match(junk.note, /not a usable line/); assert.equal(junk.reply, 'I cannot help with that.');
});

test('a fooled model is still held by the rules: injected wallet -> BLOCK, look-alike -> HOLD/BLOCK, genuine -> PAYABLE', async () => {
  const inj = sampleText('injection', cfg, ACME);
  const fooled = await proposeLine({ AI: fakeAI(JSON.stringify({ vendor: 'Acme Supplies Ltd', wallet: atk, amount: '0.05', currency: 'tUSD8', reference: 'INV-4821', due_date: '2026-12-18' })) }, inj);
  assert.equal(checkLine(inj, fooled.line, REG).decision, 'BLOCK');
  const gen = sampleText('genuine', cfg, ACME);
  const honest = await proposeLine({ AI: fakeAI(JSON.stringify({ vendor: 'Acme Supplies Ltd', wallet: ACME, amount: '0.02', currency: 'tUSD8', reference: 'INV-4821', due_date: '2026-12-18' })) }, gen);
  assert.equal(checkLine(gen, honest.line, REG).decision, 'PAYABLE');   // positive control: the rules do pass a correct line
  const look = sampleText('lookalike', cfg, ACME);
  const mapped = await proposeLine({ AI: fakeAI(JSON.stringify({ vendor: 'Acme Supplies Ltd', wallet: ACME, amount: '0.05', currency: 'tUSD8', reference: 'INV-4821', due_date: '2026-12-18' })) }, look);
  assert.notEqual(checkLine(look, mapped.line, REG).decision, 'PAYABLE');   // the model maps the impersonator onto the real vendor: still not payable
});

test('POST /extract: happy path renders the proposal and the verdict, escaped; no secrets on the page', async () => {
  const env = { ...PROD, AI: fakeAI(JSON.stringify({ vendor: '<img src=x onerror=alert(1)>', wallet: atk, amount: '0.05', currency: 'tUSD8', reference: 'INV-1', due_date: '2026-12-18' })) };
  const stub = { calls: 0, async extractReserve(a) { this.calls++; this.args = a; return { status: 200 }; } };
  const r = await run(req({ text: sampleText('payee_swap', cfg, ACME) }), env, { stub });
  assert.equal(r.status, 200);
  const body = await r.text();
  assert.match(body, /What the model proposed/);
  assert.match(body, /Stopped/);
  assert.doesNotMatch(body, /<img src=x/);
  assert.match(body, /&lt;img src=x onerror=alert\(1\)&gt;/);
  for (const v of Object.values(SECRETS)) assert.ok(!body.includes(v));
  const scripts = [...body.matchAll(/<script[^>]*>/g)].map((m) => m[0]);
  assert.deepEqual(scripts, ['<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer>']);
  assert.equal(stub.calls, 1);
  assert.equal(stub.args.ip, '198.51.100.7'); assert.equal(stub.args.demo, false);
});

test('POST /extract: gates (origin, type, size, empty, kill switches, Turnstile action, rate limit, registry)', async () => {
  const env = { ...PROD, AI: fakeAI('{}') };
  const code = async (r) => (await r.json()).code;
  let r = await run(req({ text: 'x' }, { origin: 'https://evil.test' }), env); assert.equal(r.status, 403); assert.equal(await code(r), 'origin');
  r = await run(req({ text: 'x' }, { headers: { 'sec-fetch-site': 'cross-site' } }), env); assert.equal(r.status, 403);
  r = await run(req({}, { ct: 'application/json', body: '{"text":"x"}' }), env); assert.equal(r.status, 415);
  r = await run(req({ text: 'y'.repeat(4097) }), env); assert.equal(r.status, 413);
  r = await run(req({}, { body: 'text=' + 'z'.repeat(9000) }), env); assert.equal(r.status, 413);
  r = await run(req({}, { body: 'text=x&cf-turnstile-response=tok&' + 'p=1&'.repeat(2500) }), env); assert.equal(r.status, 413);   // 10 KB body, no long field
  r = await run(req({ text: '   ' }), env); assert.equal(r.status, 400); assert.equal(await code(r), 'empty');
  r = await run(req({ text: 'x' }), { ...env, EXTRACT_OFF: '1' }); assert.equal(r.status, 503); assert.equal(await code(r), 'xoff');
  r = await run(req({ text: 'x' }), { ...env, SANDBOX_OFF: '1' }); assert.equal(r.status, 503);
  r = await run(req({ text: 'x' }, { ip: '' }), env); assert.equal(r.status, 400); assert.equal(await code(r), 'ip');
  // Turnstile: a token minted for the ATTACK widget must not unlock the extractor (and the other way round is covered in limits)
  r = await run(req({ text: 'x' }), env, { verify: siteverify('attack') }); assert.equal(r.status, 403); assert.equal(await code(r), 'turnstile');
  r = await run(req({ text: 'x' }), env, { verify: siteverify('extract', 'evil.test') }); assert.equal(r.status, 403);
  r = await run(req({ text: 'x' }), env, { verify: async () => new Response(JSON.stringify({ success: false })) }); assert.equal(r.status, 403);
  r = await run(req({ text: 'x' }), { ...env, TURNSTILE_SECRET: '1x0000000000000000000000000000000AA' }); assert.equal(r.status, 503); assert.equal(await code(r), 'tsconfig');
  // POSITIVE CONTROL: the same request with the right action passes every gate
  r = await run(req({ text: 'From: Acme Supplies Ltd\nAmount due: 0.05 tUSD8' }), env); assert.equal(r.status, 200);
  const limited = { async extractReserve() { return { status: 429, code: 'x_day', retryAfter: 100 }; } };
  r = await run(req({ text: 'x' }), env, { stub: limited }); assert.equal(r.status, 429); assert.equal(await code(r), 'x_day');
  r = await run(req({ text: 'x' }), env, { registry: async () => { throw new Error('rpc down'); } }); assert.equal(r.status, 503); assert.equal(await code(r), 'chain');
});

test('POST /extract: a failed registry read does not use up the visitor\'s try (read before extractReserve)', async () => {
  const env = { ...PROD, AI: fakeAI('{}') };
  const stub = { calls: 0, async extractReserve() { this.calls++; return { status: 200 }; } };
  const r = await run(req({ text: 'From: Acme Supplies Ltd' }), env, { stub, registry: async () => { throw new Error('rpc down'); } });
  assert.equal(r.status, 503);
  assert.equal(stub.calls, 0, 'the try was counted although the chain read failed');
  const ok = await run(req({ text: 'From: Acme Supplies Ltd' }), env, { stub });   // positive control: a good read does count
  assert.equal(ok.status, 200); assert.equal(stub.calls, 1);
});

test('POST /extract: the demo token skips Turnstile only (never the kill switch or the limits)', async () => {
  const env = { ...PROD, AI: fakeAI('{}') };
  const stub = { async extractReserve(a) { this.args = a; return { status: 200 }; } };
  const never = async () => { throw new Error('siteverify must not be called with a valid demo token'); };
  let r = await run(req({ text: 'x' }, { headers: { authorization: 'Bearer ' + SECRETS.DEMO_TOKEN } }), env, { stub, verify: never });
  assert.equal(r.status, 200); assert.equal(stub.args.demo, true);
  r = await run(req({ text: 'x' }, { headers: { authorization: 'Bearer wrong-token-wrong-token-wrong-token' } }), env, { stub, verify: siteverify('attack') });
  assert.equal(r.status, 403);
  r = await run(req({ text: 'x' }, { headers: { authorization: 'Bearer ' + SECRETS.DEMO_TOKEN } }), { ...env, EXTRACT_OFF: '1' }, { stub, verify: never });
  assert.equal(r.status, 503);
});

test('extract limits: plan defaults; outside dev vars only tighten; dev may relax (positive control)', () => {
  assert.deepEqual(extractLimitsFrom({}), { ...EXTRACT_LIMITS });
  assert.deepEqual(extractLimitsFrom({ EXTRACT_IP_DAY: '999', EXTRACT_GLOBAL_DAY: '99999', EXTRACT_IP_INTERVAL_S: '0' }), { ...EXTRACT_LIMITS });
  assert.equal(extractLimitsFrom({ EXTRACT_IP_DAY: '5' }).ipDay, 5);
  assert.equal(extractLimitsFrom({ SANDBOX_DEV: '1', EXTRACT_IP_DAY: '999', EXTRACT_IP_INTERVAL_S: '0' }).ipDay, 999);
  assert.equal(extractLimitsFrom({ SANDBOX_DEV: '1', EXTRACT_IP_INTERVAL_S: '0' }).ipIntervalS, 0);
  assert.throws(() => extractLimitsFrom({ EXTRACT_IP_DAY: '-1' }));
  assert.equal(EXTRACT_LIMITS.ipDay, 5); assert.equal(EXTRACT_LIMITS.globalHour, 40); assert.ok(EXTRACT_LIMITS.pacePct >= 25);
  assert.equal(extractLimitsFrom({ EXTRACT_GLOBAL_HOUR: '999' }).globalHour, 40);
  assert.equal(extractLimitsFrom({ EXTRACT_PACE_PCT: '0' }).pacePct, EXTRACT_LIMITS.pacePct);   // outside dev pacing cannot be relaxed
  assert.equal(extractLimitsFrom({ EXTRACT_PACE_PCT: '80' }).pacePct, 80);
  assert.equal(extractLimitsFrom({ SANDBOX_DEV: '1', EXTRACT_PACE_PCT: '0' }).pacePct, 0);
  assert.throws(() => extractLimitsFrom({ EXTRACT_PACE_PCT: '101' }));
});

test('pacedDayCap: part of the daily budget is released hour by hour (UTC)', () => {
  const at = (h) => Date.UTC(2026, 10, 26, h, 30);
  assert.equal(pacedDayCap(300, 50, at(0)), 157);     // 150 at once + 1/24 of the held 150
  assert.equal(pacedDayCap(300, 50, at(11)), 225);
  assert.equal(pacedDayCap(300, 50, at(23)), 300);    // the whole budget by the last hour
  assert.equal(pacedDayCap(300, 0, at(0)), 300);      // positive control: no pacing = the whole budget at once
  assert.equal(pacedDayCap(24, 100, at(5)), 6);
  for (let h = 0; h < 23; h++) assert.ok(pacedDayCap(300, 50, at(h)) < 300, 'hour ' + h + ' must keep some budget back');
});

test('renderExtract: visitor text is escaped in the textarea; samples carry no live attacker address', () => {
  const body = renderExtract({ cfg, sitekey: 'k', text: '</textarea><script>alert(1)</script>' });
  assert.doesNotMatch(body, /<\/textarea><script>/);
  assert.match(body, /&lt;\/textarea&gt;&lt;script&gt;/);
  assert.match(body, /data-action="extract"/);
  for (const k of ['genuine', 'payee_swap', 'injection', 'lookalike']) assert.ok(sampleText(k, cfg, ACME).length > 40);
  assert.equal(sampleText('nope', cfg, ACME), '');
  assert.match(renderExtract({ cfg, sitekey: 'k', off: true }), /paused/);
  assert.match(body, /processed by Cloudflare Workers AI/);   // privacy wording: the text leaves this site for the model
  assert.equal(sampleText('genuine', { ...cfg, addresses: {}, vendors: { ...cfg.vendors, acme: { ...cfg.vendors.acme, wallet: ACME } } }).includes(ACME), true);   // GET fills the sample from the config (no chain read)
});

test('vendorRegistry: reads each vendor wallet, drops zero wallets, caches 60 s, fails when none', async () => {
  _resetRegistryCache();
  let n = 0;
  const read = async (id) => { n++; return id === '1822' ? '0x' + '0'.repeat(40) : id === '1820' ? ACME : A('1'); };
  const e = await vendorRegistry(cfg, 'http://unused', { readImpl: read });
  assert.deepEqual(e, [['Acme Supplies Ltd', ACME], ['Hooli Freight', A('1')]]);
  await vendorRegistry(cfg, 'http://unused', { readImpl: read });
  assert.equal(n, 3);
  _resetRegistryCache();
  await assert.rejects(vendorRegistry(cfg, 'http://unused', { readImpl: async () => '0x' + '0'.repeat(40) }));
  _resetRegistryCache();
});

test('vendorRegistry: a failed read is cached ~30 s (one RPC attempt, not one per request), then retried', async () => {
  _resetRegistryCache();
  let n = 0;
  const down = async () => { n++; throw new Error('rpc down'); };
  await assert.rejects(vendorRegistry(cfg, 'http://unused', { readImpl: down }));
  await assert.rejects(vendorRegistry(cfg, 'http://unused', { readImpl: down }));
  await assert.rejects(vendorRegistry(cfg, 'http://unused', { readImpl: down }));
  assert.equal(n, 1, 'each request hit the RPC again');
  const realNow = Date.now;
  try {
    Date.now = () => realNow() + 31_000;   // after the failure TTL the next request reads again (positive control)
    const e = await vendorRegistry(cfg, 'http://unused', { readImpl: async (id) => (id === '1820' ? ACME : A('1')) });
    assert.equal(e.length, 3);
  } finally { Date.now = realNow; _resetRegistryCache(); }
});
