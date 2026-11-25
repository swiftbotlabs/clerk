// Clerk public sandbox Worker. Routes:
//   GET  /               page (server-rendered; readable with JS off)      GET /log        last 100 attempts
//   GET  /attempt/:id    one attempt                                        GET /api/state  same data as JSON (same-origin; no CORS)
//   GET  /healthz        config + chain + key gas floors (200 ok / 503)     POST /attack    {kind, text<=4KB, cf-turnstile-response}
// Order of checks on POST: kill switch -> origin -> content type + body size -> fields -> Turnstile -> Durable Object
// (kill switch again, rate limits, one-at-a-time queue, chain sends). No CORS headers are ever sent.
import { KINDS } from '../../lib/sandbox.mjs';
import { renderHome, renderAttempt, renderLog, renderMessage } from './page.mjs';
import { limitsFrom, MAX_BODY, MAX_TEXT, MAX_TOKEN } from './limits.mjs';
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

async function turnstileOk(env, token, ip) {
  if (typeof token !== 'string' || token.length < 1 || token.length > MAX_TOKEN || !env.TURNSTILE_SECRET) return false;
  const form = new FormData();
  form.append('secret', env.TURNSTILE_SECRET); form.append('response', token); form.append('remoteip', ip);
  try {
    const r = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', { method: 'POST', body: form, signal: AbortSignal.timeout(8000) });
    if (!r.ok) return false;
    const d = await r.json();
    if (d.success !== true) return false;
    if (env.TURNSTILE_HOSTNAME && d.hostname !== env.TURNSTILE_HOSTNAME) return false;
    return true;
  } catch { return false; }
}

async function attack(req, env, stub, cfg) {
  const wantsJson = (req.headers.get('accept') || '').includes('application/json') && !(req.headers.get('accept') || '').includes('text/html');
  if (env.SANDBOX_OFF === '1') return refuse('off', 503, wantsJson, { cfg });
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
  if (!ip) return refuse('ip', 400, wantsJson, { cfg });
  if (!(await turnstileOk(env, fields.token, ip))) return refuse('turnstile', 403, wantsJson, { cfg });
  const r = await stub.attack({ kind, text, ip });
  if (r.status !== 200) return refuse(r.code, r.status, wantsJson, { retryAfter: r.retryAfter, cfg });
  if (wantsJson) return json({ ok: true, id: r.id, attempt: r.rec, detail: r.detail });
  return html(renderAttempt({ rec: r.rec, detail: r.detail, cfg, fresh: true }));
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const stub = env.SANDBOX.get(env.SANDBOX.idFromName('main'));
    const method = req.method;
    if (url.pathname === '/attack') {
      if (method !== 'POST') return html(renderMessage('Not allowed', 'Use the form on the sandbox page.'), 405, { allow: 'POST' });
      const cfg = await stub.publicConfig();
      if (!cfg) return refuse('config', 503, false);
      return attack(req, env, stub, cfg);
    }
    if (method !== 'GET' && method !== 'HEAD') return html(renderMessage('Not allowed', 'Only GET here.'), 405, { allow: 'GET, HEAD' });
    if (url.pathname === '/healthz') { const h = await stub.health(); return json(h, h.ok ? 200 : 503); }
    const cfg = await stub.publicConfig();
    if (!cfg) return html(renderMessage('Not configured', 'The sandbox is not configured.'), 503);
    let limits;
    try { limits = limitsFrom(env); } catch { return html(renderMessage('Not configured', 'Bad limit settings.'), 503); }
    if (url.pathname === '/') {
      const state = await stub.state({ limit: 25 });
      return html(renderHome({ state, cfg, sitekey: env.TURNSTILE_SITEKEY || '', limits }));
    }
    if (url.pathname === '/log') return html(renderLog({ state: await stub.state({ limit: 100 }), cfg }));
    if (url.pathname === '/api/state') return json({ ...(await stub.state({ limit: 100 })), config: cfg });
    const m = /^\/attempt\/(\d{1,9})$/.exec(url.pathname);
    if (m) {
      const rec = await stub.attempt(Number(m[1]));
      return rec ? html(renderAttempt({ rec, cfg })) : html(renderMessage('Not found', 'That attempt is not in the last 100.', { cfg }), 404);
    }
    return html(renderMessage('Not found', 'Nothing here.', { cfg }), 404);
  },
};
