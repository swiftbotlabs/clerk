// Rate limits and config parsing, kept free of Worker/viem imports so node --test can check them directly.
export const DEFAULT_LIMITS = Object.freeze({ ipIntervalS: 60, ipDay: 30, globalDay: 300, globalHour: 30, net48Hour: 10, demoDay: 40, maxQueue: 4 });
export const MAX_TEXT = 4096;           // invoice text, characters
export const MAX_BODY = 8192;           // request body, bytes
export const MAX_TOKEN = 2048;          // Turnstile token, characters

const int = (v) => (v === undefined || v === null || v === '' ? null : /^\d{1,7}$/.test(String(v)) ? Number(v) : NaN);

/** Limits from env. Vars can only make the public limits TIGHTER than the plan; the per-IP interval may be shortened
 *  only on a dev run (SANDBOX_DEV=1, which also refuses to start against a public RPC). */
export function limitsFrom(env = {}) {
  const dev = env.SANDBOX_DEV === '1';
  const pick = (v, def, { max = def, devMin = 0 } = {}) => {
    const n = int(v);
    if (n === null) return def;
    if (Number.isNaN(n)) throw new Error('bad limit var');
    return dev ? Math.max(devMin, n) : Math.min(n, max);
  };
  const ipIntervalS = (() => {
    const n = int(env.LIMIT_IP_INTERVAL_S);
    if (n === null) return DEFAULT_LIMITS.ipIntervalS;
    if (Number.isNaN(n)) throw new Error('bad limit var');
    return dev ? n : Math.max(n, DEFAULT_LIMITS.ipIntervalS);
  })();
  return { ipIntervalS, ipDay: pick(env.LIMIT_IP_DAY, DEFAULT_LIMITS.ipDay), globalDay: pick(env.LIMIT_GLOBAL_DAY, DEFAULT_LIMITS.globalDay),
    globalHour: pick(env.LIMIT_GLOBAL_HOUR, DEFAULT_LIMITS.globalHour), net48Hour: pick(env.LIMIT_NET48_HOUR, DEFAULT_LIMITS.net48Hour), demoDay: pick(env.LIMIT_DEMO_DAY, DEFAULT_LIMITS.demoDay),
    maxQueue: pick(env.LIMIT_QUEUE, DEFAULT_LIMITS.maxQueue, { devMin: 1 }) || 1 };
}

const ADDR = /^0x[0-9a-fA-F]{40}$/, H32 = /^0x[0-9a-fA-F]{64}$/;
/** Validate SANDBOX_CONFIG + SANDBOX_KEYS. Throws (without echoing values) on anything unexpected. */
export function parseConfig(env) {
  let cfg, keys;
  try { cfg = JSON.parse(env.SANDBOX_CONFIG || ''); } catch { throw new Error('SANDBOX_CONFIG missing or not JSON'); }
  try { keys = JSON.parse(env.SANDBOX_KEYS || ''); } catch { throw new Error('SANDBOX_KEYS missing or not JSON'); }
  const need = ['owner', 'clerk', 'revoked', 'expired', 'stranger', 'daycap', 'vendor_hijack', 'vendor_new'];
  for (const r of need) if (!H32.test(keys?.[r] || '')) throw new Error(`SANDBOX_KEYS: role ${r} missing`);
  if (Object.keys(keys).some((k) => !need.includes(k))) throw new Error('SANDBOX_KEYS: unexpected role (funder/treasury keys must not be here)');
  if (cfg.chainId !== 44005) throw new Error('config: chainId must be 44005');
  const local = /^http:\/\/(127\.0\.0\.1|localhost):\d{2,5}$/.test(cfg.rpc || '');
  if (env.SANDBOX_DEV === '1' ? !local : cfg.rpc !== 'https://rpc-test.qday.info') throw new Error('config: rpc not allowed in this mode');
  for (const k of ['payrun', 'registry', 'token', 'treasury']) if (!ADDR.test(cfg[k] || '')) throw new Error(`config: ${k}`);
  if (!H32.test(cfg.paidInvoiceHash || '')) throw new Error('config: paidInvoiceHash');
  for (const v of ['acme', 'hijack', 'new']) if (!/^\d{1,9}$/.test(String(cfg.vendors?.[v]?.id ?? '')) || !cfg.vendors[v].name) throw new Error(`config: vendor ${v}`);
  if (cfg.explorer && !/^https:\/\/[a-z0-9.-]+$/.test(cfg.explorer)) throw new Error('config: explorer');
  return { cfg, keys };
}

export const dayStart = (ms) => ms - (ms % 86_400_000);

function v6groups(ip) {
  if (!/^[0-9a-f:.]{2,45}$/.test(ip) || ip.split('::').length > 2) return null;
  const [head, tail = ''] = ip.split('::');
  const h = head ? head.split(':') : [], t = tail ? tail.split(':') : [];
  const full = ip.includes('::') ? [...h, ...Array(Math.max(0, 8 - h.length - t.length)).fill('0'), ...t] : h;
  return full.length < 4 ? null : full.map((x) => (parseInt(x || '0', 16) || 0).toString(16));
}

/** F4: the rate-limit key of a client IP. IPv4 as is; IPv6 grouped by its /64 (one home or VPS block = one visitor). */
export function ipKey(ip) {
  ip = String(ip || '').trim().toLowerCase();
  if (!ip.includes(':')) return /^\d{1,3}(\.\d{1,3}){3}$/.test(ip) ? ip : '';
  const g = v6groups(ip);
  return g ? g.slice(0, 4).join(':') + '::/64' : '';
}

/** R2-1: the IPv6 /48 a client is in (a tunnel-broker allocation holds 65,536 /64s); '' for IPv4 / invalid. */
export function net48Key(ip) {
  ip = String(ip || '').trim().toLowerCase();
  if (!ip.includes(':')) return '';
  const g = v6groups(ip);
  return g ? g.slice(0, 3).join(':') + '::/48' : '';
}

const TEST_KEY = /^[123]x0{20,}[A-Za-z]{2}$/;
/** F2: outside dev, refuse to run with Cloudflare's TEST Turnstile keys or without the expected hostname. '' = fine. */
export function turnstileConfigError(env) {
  if (env.SANDBOX_DEV === '1') return '';
  if (!env.TURNSTILE_SECRET || TEST_KEY.test(env.TURNSTILE_SECRET)) return 'turnstile secret missing or a test key';
  if (!env.TURNSTILE_SITEKEY || TEST_KEY.test(env.TURNSTILE_SITEKEY)) return 'turnstile site key missing or a test key';
  if (!/^[a-z0-9.-]{4,253}$/.test(env.TURNSTILE_HOSTNAME || '')) return 'TURNSTILE_HOSTNAME not set';
  return '';
}

/** Turnstile siteverify. Fails closed on anything but success with action 'attack' and (outside dev) the expected hostname.
 *  In dev with Cloudflare's always-pass TEST secret the action/hostname are not echoed back, so only success is required there. */
export async function turnstileOk(env, token, ip, fetchImpl = fetch) {
  if (typeof token !== 'string' || token.length < 1 || token.length > MAX_TOKEN || !env.TURNSTILE_SECRET) return false;
  if (turnstileConfigError(env)) return false;
  const form = new FormData();
  form.append('secret', env.TURNSTILE_SECRET); form.append('response', token); form.append('remoteip', ip);
  try {
    // one retry on a network error or a 5xx (a token is single-use, so a retry after a lost answer fails closed)
    let r;
    for (let i = 0; i < 2; i++) {
      try { r = await fetchImpl('https://challenges.cloudflare.com/turnstile/v0/siteverify', { method: 'POST', body: form, signal: AbortSignal.timeout(8000) }); }
      catch { r = null; }
      if (r && r.status < 500) break;
    }
    if (!r || !r.ok) { console.log(JSON.stringify({ ev: 'siteverify_failed', status: r ? r.status : 'network' })); return false; }
    const d = await r.json();
    if (d.success !== true) return false;
    const devTest = env.SANDBOX_DEV === '1' && TEST_KEY.test(env.TURNSTILE_SECRET);
    if (!devTest && d.action !== 'attack') return false;
    if (!devTest && d.hostname !== env.TURNSTILE_HOSTNAME) return false;
    return true;
  } catch { return false; }
}

/** F4: constant-time check of the demo header against DEMO_TOKEN (>= 32 chars; unset = no demo budget). */
export async function demoOk(env, header) {
  const secret = env.DEMO_TOKEN || '';
  if (secret.length < 32 || typeof header !== 'string' || !header || header.length > 256) return false;
  const h = async (v) => new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(v)));
  const [a, b] = await Promise.all([h(secret), h(header)]);
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/** The public part of the config, parsed in the Worker (no DO round trip). null if the config is bad. */
export function publicConfigFrom(env) {
  try {
    const { cfg: c } = parseConfig(env);
    return { network: c.network, explorer: c.explorer, payrun: c.payrun, registry: c.registry, treasury: c.treasury, treasuryStart: c.treasuryStart || null,
      token: c.token, vendors: c.vendors, addresses: c.addresses, seed: c.seed || {} };
  } catch { return null; }
}
