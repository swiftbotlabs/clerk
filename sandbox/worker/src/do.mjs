// The one Durable Object that owns every chain send. All attacks run one at a time through `this.tail` (a promise chain), so two
// sends from the same key can never race for a nonce. SQLite holds the public attempt log (last 100), per-kind counters, and the
// rate-limit hits (salted IP hashes, never raw IPs; pruned after 2 days).
import { DurableObject } from 'cloudflare:workers';
import { makeSandbox, KINDS, SandboxError, ERC20_ABI, jsonSafe } from '../../lib/sandbox.mjs';
import { limitsFrom, parseConfig, dayStart } from './limits.mjs';

const KEEP = 100;

export class Sandbox extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS attempts (id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, kind TEXT NOT NULL,
        outcome TEXT NOT NULL, rec TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS counts (kind TEXT PRIMARY KEY, attempts INTEGER NOT NULL DEFAULT 0, refused INTEGER NOT NULL DEFAULT 0,
        accepted INTEGER NOT NULL DEFAULT 0, faults INTEGER NOT NULL DEFAULT 0, resting INTEGER NOT NULL DEFAULT 0, txs INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS hits (ip TEXT NOT NULL, ts INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS hits_ip ON hits(ip, ts);
      CREATE INDEX IF NOT EXISTS hits_ts ON hits(ts);
      CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);`);
    this.tail = Promise.resolve();
    this.queued = 0;
    this.sb = null;
    this.treasuryCache = null;
  }

  salt() {
    const row = this.sql.exec("SELECT v FROM meta WHERE k='salt'").toArray()[0];
    if (row) return row.v;
    const s = [...crypto.getRandomValues(new Uint8Array(32))].map((b) => b.toString(16).padStart(2, '0')).join('');
    this.sql.exec("INSERT INTO meta (k, v) VALUES ('salt', ?)", s);
    return s;
  }

  async ipHash(ip) {
    const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(this.salt() + '|' + ip));
    return [...new Uint8Array(d)].slice(0, 16).map((b) => b.toString(16).padStart(2, '0')).join('');
  }

  sandbox() {
    if (!this.sb) {
      const { cfg, keys } = parseConfig(this.env);
      this.cfg = cfg;
      this.sb = makeSandbox({ ...cfg, keys, minBalanceWei: BigInt(cfg.minBalanceWei), maxGasPriceWei: BigInt(cfg.maxGasPriceWei), receiptTimeoutMs: 90_000 });
      this.chainChecked = false;
    }
    return this.sb;
  }

  /** Synchronous check-and-reserve: SQLite calls are synchronous inside a DO, so two requests cannot both take the last slot. */
  reserve(ipH, now, L) {
    const ds = dayStart(now);
    const g = this.sql.exec('SELECT COUNT(*) AS n FROM hits WHERE ts >= ?', ds).one().n;
    if (g >= L.globalDay) return { ok: false, code: 'global_day', retryAfter: Math.ceil((ds + 86_400_000 - now) / 1000) };
    const mine = this.sql.exec('SELECT COUNT(*) AS n, MAX(ts) AS last FROM hits WHERE ip = ? AND ts >= ?', ipH, now - 86_400_000 * 2).one();
    const today = this.sql.exec('SELECT COUNT(*) AS n FROM hits WHERE ip = ? AND ts >= ?', ipH, ds).one().n;
    if (today >= L.ipDay) return { ok: false, code: 'ip_day', retryAfter: Math.ceil((ds + 86_400_000 - now) / 1000) };
    if (mine.last !== null && now - mine.last < L.ipIntervalS * 1000) return { ok: false, code: 'ip_interval', retryAfter: Math.ceil((mine.last + L.ipIntervalS * 1000 - now) / 1000) };
    if (this.queued >= L.maxQueue) return { ok: false, code: 'busy', retryAfter: 30 };
    this.sql.exec('INSERT INTO hits (ip, ts) VALUES (?, ?)', ipH, now);
    this.sql.exec('DELETE FROM hits WHERE ts < ?', now - 86_400_000 * 2);
    return { ok: true };
  }

  /** RPC from the Worker. Input already validated there (kind whitelist, text size, Turnstile); validated again here. */
  async attack({ kind, text, ip }) {
    if (this.env.SANDBOX_OFF === '1') return { status: 503, code: 'off' };
    if (!Object.hasOwn(KINDS, kind)) return { status: 400, code: 'kind' };
    if (typeof ip !== 'string' || !ip || ip.length > 64) return { status: 400, code: 'ip' };
    if (text !== undefined && (typeof text !== 'string' || text.length > 4096)) return { status: 413, code: 'text' };
    if (!KINDS[kind].invoice) text = undefined;
    const L = limitsFrom(this.env);
    const r = this.reserve(await this.ipHash(ip), Date.now(), L);
    if (!r.ok) return { status: r.code === 'busy' ? 503 : 429, code: r.code, retryAfter: r.retryAfter };
    this.queued++;
    const job = this.tail.then(() => this.run(kind, text));
    this.tail = job.catch(() => {});
    try { return await job; } finally { this.queued--; }
  }

  async run(kind, text) {
    const at = Date.now();
    let res, outcome, detail = null;
    try {
      const S = this.sandbox();
      if (!this.chainChecked) {
        if ((await S.pub.getChainId()) !== this.cfg.chainId) throw new Error('RPC chain id mismatch');
        this.chainChecked = true;
      }
      res = jsonSafe(await S.attack(kind, { text }));
      outcome = res.fault ? 'fault' : KINDS[kind].control ? (res.accepted ? 'accepted' : 'fault') : res.refused ? 'refused' : res.accepted ? 'accepted' : 'fault';
    } catch (e) {
      const resting = e instanceof SandboxError;
      outcome = resting ? 'resting' : 'fault';
      // no key material can be in these messages; keep them short anyway
      const msg = String(e?.shortMessage || e?.message || e).replace(/0x[0-9a-fA-F]{64,}/g, '0x…').slice(0, 160);
      console.log(JSON.stringify({ ev: 'attack_error', kind, resting, name: e?.name, msg }));
      res = { kind, n: KINDS[kind].n, title: KINDS[kind].title, expect: KINDS[kind].expect, steps: [], note: resting ? msg : 'the sandbox hit an error; nothing was paid' };
    }
    // PUBLIC record: no visitor text, no reasons quoting it; only our step data (role names, tx hashes, decoded errors).
    const rec = {
      kind, n: res.n, title: res.title, expect: res.expect, outcome, at: new Date(at).toISOString(), note: res.note || null,
      steps: (res.steps || []).map((s) => ({ step: s.step, from: s.from, sent: !!s.sent, hash: s.hash || null, status: s.status || null,
        error: s.error || null, errorArgs: (s.errorArgs || []).slice(0, 6).map((a) => String(a).slice(0, 80)), simulated: s.simulated || null,
        block: s.block || null, gasUsed: s.gasUsed || null, note: s.note || null })),
      offchain: res.offchain ? { decision: res.offchain.decision, cop: res.offchain.cop, replacedAddress: !!res.offchain.replacedAddress } : null,
    };
    const txs = rec.steps.filter((s) => s.sent).length;
    const id = this.sql.exec('INSERT INTO attempts (at, kind, outcome, rec) VALUES (?, ?, ?, ?) RETURNING id', at, kind, outcome, JSON.stringify(rec)).one().id;
    this.sql.exec('DELETE FROM attempts WHERE id <= ?', id - KEEP);
    this.sql.exec(`INSERT INTO counts (kind, attempts, refused, accepted, faults, resting, txs) VALUES (?, 1, ?, ?, ?, ?, ?)
      ON CONFLICT(kind) DO UPDATE SET attempts = attempts + 1, refused = refused + excluded.refused, accepted = accepted + excluded.accepted,
      faults = faults + excluded.faults, resting = resting + excluded.resting, txs = txs + excluded.txs`,
      kind, +(outcome === 'refused'), +(outcome === 'accepted'), +(outcome === 'fault'), +(outcome === 'resting'), txs);
    console.log(JSON.stringify({ ev: 'attempt', id, kind, outcome, txs }));
    // PRIVATE detail for the visitor who asked (returned once, never stored): off-chain verdict with reasons.
    if (res.offchain) detail = { reasons: res.offchain.reasons || [], warnings: res.offchain.warnings || [], proposed: res.offchain.proposed || {} };
    return { status: 200, id, rec: { id, ...rec }, detail };
  }

  async state({ limit = 25 } = {}) {
    const n = Math.max(1, Math.min(KEEP, Number(limit) || 25));
    const attempts = this.sql.exec('SELECT id, rec FROM attempts ORDER BY id DESC LIMIT ?', n).toArray().map((r) => ({ id: r.id, ...JSON.parse(r.rec) }));
    const counts = Object.fromEntries(this.sql.exec('SELECT * FROM counts').toArray().map((r) => [r.kind, r]));
    const ds = dayStart(Date.now());
    const today = this.sql.exec('SELECT COUNT(*) AS n FROM hits WHERE ts >= ?', ds).one().n;
    return { attempts, counts, today, limits: limitsFrom(this.env), treasury: await this.treasury(), off: this.env.SANDBOX_OFF === '1' };
  }

  attempt(id) {
    if (!Number.isSafeInteger(id) || id < 1) return null;
    const r = this.sql.exec('SELECT id, rec FROM attempts WHERE id = ?', id).toArray()[0];
    return r ? { id: r.id, ...JSON.parse(r.rec) } : null;
  }

  /** Live treasury balance (cached 60 s) so the page can show that attacks moved nothing. */
  async treasury() {
    const now = Date.now();
    if (this.treasuryCache && now - this.treasuryCache.t < 60_000) return this.treasuryCache.v;
    let v = null;
    try {
      const S = this.sandbox();
      const units = await S.pub.readContract({ address: this.cfg.token, abi: ERC20_ABI, functionName: 'balanceOf', args: [this.cfg.treasury] });
      v = units.toString();
    } catch (e) { console.log(JSON.stringify({ ev: 'treasury_read_failed', name: e?.name })); }
    this.treasuryCache = { t: now, v };
    return v;
  }

  /** Health: config parses, RPC answers with the right chain, every key above its gas floor. */
  async health() {
    const out = { config: false, chain: false, keysAboveFloor: 0, keysTotal: 0, off: this.env.SANDBOX_OFF === '1' };
    try {
      const S = this.sandbox(); out.config = true;
      out.chain = (await S.pub.getChainId()) === this.cfg.chainId;
      const floor = BigInt(this.cfg.minBalanceWei);
      const bals = await Promise.all(Object.values(this.cfg.addresses).map((a) => S.pub.getBalance({ address: a })));
      out.keysTotal = bals.length; out.keysAboveFloor = bals.filter((b) => b >= floor).length;
    } catch (e) { out.error = String(e?.shortMessage || e?.message || 'error').replace(/0x[0-9a-fA-F]{40,}/g, '0x…').slice(0, 120); }
    out.ok = out.config && out.chain && out.keysTotal > 0 && out.keysAboveFloor === out.keysTotal;
    return out;
  }

  publicConfig() {
    try { this.sandbox(); } catch { return null; }
    const c = this.cfg;
    return { network: c.network, explorer: c.explorer, payrun: c.payrun, registry: c.registry, treasury: c.treasury, treasuryStart: c.treasuryStart || null, token: c.token,
      vendors: c.vendors, addresses: c.addresses, seed: c.seed || {} };
  }
}
