// Rate limits and config parsing, kept free of Worker/viem imports so node --test can check them directly.
export const DEFAULT_LIMITS = Object.freeze({ ipIntervalS: 60, ipDay: 30, globalDay: 300, maxQueue: 4 });
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
