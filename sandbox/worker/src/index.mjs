// Clerk public sandbox Worker. Routes:
//   GET  /               page (server-rendered; readable with JS off)      GET /log        last 100 attempts
//   GET  /attempt/:id    one attempt                                        GET /api/state  same data as JSON (same-origin; no CORS)
//   GET  /healthz        config + chain + key gas floors (200 ok / 503)     POST /attack    {kind, text<=4KB, cf-turnstile-response}
// Order of checks on POST: kill switch -> origin -> content type + body size -> fields -> Turnstile -> Durable Object
// (kill switch again, rate limits, one-at-a-time queue, chain sends). No CORS headers are ever sent.
import { KINDS } from '../../lib/sandbox.mjs';
import { renderHome, renderAttempt, renderLog, renderMessage } from './page.mjs';
import { limitsFrom, MAX_BODY, MAX_TEXT, ipKey, net48Key, turnstileOk, turnstileConfigError, demoOk, publicConfigFrom } from './limits.mjs';
export { Sandbox } from './do.mjs';

const CSP = "default-src 'none'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data:; " +
  "script-src https://challenges.cloudflare.com; frame-src https://challenges.cloudflare.com; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'";
const BASE_HEADERS = { 'content-security-policy': CSP, 'x-content-type-options': 'nosniff', 'referrer-policy': 'strict-origin-when-cross-origin',
  'x-frame-options': 'DENY', 'cache-control': 'no-store', 'permissions-policy': 'camera=(), microphone=(), geolocation=()' };

const html = (body, status = 200, extra = {}) => new Response(body, { status, headers: { ...BASE_HEADERS, 'content-type': 'text/html; charset=utf-8', ...extra } });
const json = (obj, status = 200, extra = {}) => new Response(JSON.stringify(obj), { status, headers: { ...BASE_HEADERS, 'content-type': 'application/json', ...extra } });

const MESSAGES = {
  off: ['Paused', 'The sandbox is paused right now. The log and its transactions stay public.'],
  origin: ['Not allowed', 'Attacks can only be sent from the sandbox page itself.'],
  type: ['Not allowed', 'Send the form from the sandbox page.'],
  size: ['Too long', `The invoice text can be at most ${MAX_TEXT} characters.`],
  kind: ['Unknown attack', 'Pick one of the attacks on the sandbox page.'],
  turnstile: ['Human check failed', 'The human check did not pass (it needs JavaScript). Go back, wait for the check to finish, and try again.'],
  ip_interval: ['One a minute', 'One attempt a minute per visitor. Wait a moment and try again.'],
  ip_day: ['Daily limit reached', 'You have used today\'s attempts. The log stays open; come back tomorrow (UTC).'],
  global_day: ['Daily limit reached', 'The sandbox has run all of today\'s attempts for everyone. Come back tomorrow (UTC).'],
  busy: ['Busy', 'Several attacks are already queued. Try again in half a minute.'],
  ip: ['Not allowed', 'Your request could not be matched to a visitor.'],
  config: ['Not configured', 'The sandbox is not configured.'],
  tsconfig: ['Not configured', 'The human check is not configured, so attacks are off.'],
  global_hour: ['Busy hour', 'The sandbox has run this hour\'s attempts for everyone. Try again later this hour.'],
  demo_day: ['Demo budget used', 'The demo budget for today is used up.'],
  net_hour: ['Busy network', 'Your network block has used this hour\'s attempts. Try again later this hour.'],
  rate: ['Slow down', 'Too many requests from your network. Wait a minute.'],
  text: ['Too long', `The invoice text can be at most ${MAX_TEXT} characters.`],
};

function refuse(code, status, wantsJson, { retryAfter, cfg } = {}) {
  const extra = retryAfter ? { 'retry-after': String(retryAfter) } : {};
  if (wantsJson) return json({ ok: false, code, retryAfter: retryAfter ?? null }, status, extra);
  const [t, m] = MESSAGES[code] || ['Error', 'Something went wrong.'];
  return html(renderMessage(t, m, { cfg }), status, extra);
}

/** Read at most `max` bytes of the body; null if it is larger (whatever Content-Length claims). */
async function readCapped(req, max) {
  const cl = Number(req.headers.get('content-length') || '0');
  if (cl > max) return null;
  if (!req.body) return '';
  const reader = req.body.getReader();
  const chunks = []; let n = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    n += value.byteLength;
    if (n > max) { try { await reader.cancel(); } catch {} return null; }
    chunks.push(value);
  }
  const buf = new Uint8Array(n); let o = 0;
  for (const c of chunks) { buf.set(c, o); o += c.byteLength; }
  return new TextDecoder('utf-8', { fatal: false }).decode(buf);
}

async function attack(req, env, stub, cfg) {
  const wantsJson = (req.headers.get('accept') || '').includes('application/json') && !(req.headers.get('accept') || '').includes('text/html');
  if (env.SANDBOX_OFF === '1') return refuse('off', 503, wantsJson, { cfg });
  if (turnstileConfigError(env)) return refuse('tsconfig', 503, wantsJson, { cfg });      // F2: fail closed on test keys / no hostname
  if (!cfg) return refuse('config', 503, wantsJson);
  const url = new URL(req.url);
  const origin = req.headers.get('origin');
  if (origin !== null && origin !== url.origin) return refuse('origin', 403, wantsJson, { cfg });
  const sfs = req.headers.get('sec-fetch-site');
  if (sfs && !['same-origin', 'none'].includes(sfs)) return refuse('origin', 403, wantsJson, { cfg });
  const ct = (req.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
  const raw = await readCapped(req, MAX_BODY);
  if (raw === null) return refuse('size', 413, wantsJson, { cfg });
  let fields;
  if (ct === 'application/x-www-form-urlencoded') {
    const p = new URLSearchParams(raw);
    fields = { kind: p.get('kind'), text: p.get('text'), token: p.get('cf-turnstile-response') };
  } else if (ct === 'application/json') {
    if (origin === null) return refuse('origin', 403, wantsJson, { cfg });     // JSON only from our own page's origin
    try { const j = JSON.parse(raw); fields = { kind: j.kind, text: j.text, token: j.turnstile }; } catch { return refuse('type', 400, wantsJson, { cfg }); }
  } else return refuse('type', 415, wantsJson, { cfg });
  const kind = typeof fields.kind === 'string' ? fields.kind : '';
  if (!Object.hasOwn(KINDS, kind)) return refuse('kind', 400, wantsJson, { cfg });
  let text = typeof fields.text === 'string' ? fields.text.replace(/\r\n?/g, '\n') : undefined;
  if (text !== undefined && text.length > MAX_TEXT) return refuse('size', 413, wantsJson, { cfg });
  if (!text || !text.trim() || !KINDS[kind].invoice) text = undefined;
  const ip = req.headers.get('cf-connecting-ip') || '';
  const key = ipKey(ip);
  if (!key) return refuse('ip', 400, wantsJson, { cfg });
  // F4/R2-3: a reserved demo budget behind `Authorization: Bearer <DEMO_TOKEN>` (constant-time check; invocation logs are off
  // in wrangler.toml so no request header is logged). It replaces the human check, not the kill switch or the queue.
  const auth = req.headers.get('authorization') || '';
  const demo = auth.startsWith('Bearer ') ? await demoOk(env, auth.slice(7)) : false;
  if (!demo && !(await turnstileOk(env, fields.token, ip))) return refuse('turnstile', 403, wantsJson, { cfg });
  const r = await stub.attack({ kind, text, ip: key, net: net48Key(ip), demo });
  if (r.status !== 200) return refuse(r.code, r.status, wantsJson, { retryAfter: r.retryAfter, cfg });
  pageCache.clear();     // this isolate's cached views now lag the log: drop them
  if (wantsJson) return json({ ok: true, id: r.id, attempt: r.rec, detail: r.detail });
  return html(renderAttempt({ rec: r.rec, detail: r.detail, cfg, fresh: true }));
}

// F3: / and /log are rendered at most once per 5 s per isolate (the Cache API is a no-op on workers.dev, isolate memory is not)
const PAGE_TTL_MS = 5_000;
const pageCache = new Map();
async function cachedPage(path, render, make = html) {
  const hit = pageCache.get(path);
  const now = Date.now();
  if (hit && now - hit.t < PAGE_TTL_MS) return make(hit.body, 200, { 'x-rendered-at': String(hit.t), 'cache-control': 'public, max-age=5' });
  const body = await render();
  pageCache.set(path, { t: now, body });
  return make(body, 200, { 'x-rendered-at': String(now), 'cache-control': 'public, max-age=5' });
}
const jsonRaw = (body, status, extra) => new Response(body, { status, headers: { ...BASE_HEADERS, 'content-type': 'application/json', ...extra } });

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const method = req.method;
    // F3: per-visitor request limit on EVERY route (Workers Rate Limiting binding; required outside dev)
    if (env.RL) {
      const { success } = await env.RL.limit({ key: ipKey(req.headers.get('cf-connecting-ip')) || 'none' });
      if (!success) return html(renderMessage('Slow down', 'Too many requests from your network. Wait a minute.'), 429, { 'retry-after': '60' });
    } else if (env.SANDBOX_DEV !== '1') return html(renderMessage('Not configured', 'The sandbox is not configured.'), 503);
    const stub = env.SANDBOX.get(env.SANDBOX.idFromName('main'));
    const cfg = publicConfigFrom(env);
    if (url.pathname === '/attack') {
      if (method !== 'POST') return html(renderMessage('Not allowed', 'Use the form on the sandbox page.'), 405, { allow: 'POST' });
      return attack(req, env, stub, cfg);
    }
    if (method !== 'GET' && method !== 'HEAD') return html(renderMessage('Not allowed', 'Only GET here.'), 405, { allow: 'GET, HEAD' });
    if (url.pathname === '/healthz') {
      const h = { ...(await stub.health()), turnstileConfig: !turnstileConfigError(env) };
      h.ok = h.ok && h.turnstileConfig;
      return json(h, h.ok ? 200 : 503);
    }
    if (!cfg) return html(renderMessage('Not configured', 'The sandbox is not configured.'), 503);
    let limits;
    try { limits = limitsFrom(env); } catch { return html(renderMessage('Not configured', 'Bad limit settings.'), 503); }
    if (url.pathname === '/') return cachedPage('/', async () => renderHome({ state: await stub.state({ limit: 25 }), cfg, sitekey: env.TURNSTILE_SITEKEY || '', limits }));
    if (url.pathname === '/log') return cachedPage('/log', async () => renderLog({ state: await stub.state({ limit: 100 }), cfg }));
    // R2-2: /api/state shares the 5 s cache (dropped by this isolate after each finished attack)
    if (url.pathname === '/api/state') return cachedPage('/api/state', async () => JSON.stringify({ ...(await stub.state({ limit: 100 })), config: cfg }), jsonRaw);
    const m = /^\/attempt\/(\d{1,9})$/.exec(url.pathname);
    if (m) {
      const rec = await stub.attempt(Number(m[1]));
      return rec ? html(renderAttempt({ rec, cfg })) : html(renderMessage('Not found', 'That attempt is not in the last 100.', { cfg }), 404);
    }
    return html(renderMessage('Not found', 'Nothing here.', { cfg }), 404);
  },
};
