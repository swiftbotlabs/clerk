// The one Durable Object that owns every chain send. All attacks run one at a time through `this.tail` (a promise chain), so two
// sends from the same key can never race for a nonce. SQLite holds the public attempt log (last 100), per-kind counters, and the
// rate-limit hits (salted hashes of the visitor key: IPv4 address or IPv6 /64; never raw IPs; pruned after 2 days).
import { DurableObject } from 'cloudflare:workers';
import { parseAbi } from 'viem';
import { makeSandbox, KINDS, SandboxError, ERC20_ABI, jsonSafe } from '../../lib/sandbox.mjs';
import { limitsFrom, parseConfig, dayStart } from './limits.mjs';
import { extractLimitsFrom } from './extract.mjs';

const KEEP = 100;
const HEALTH_TTL_MS = 30_000;
const SESSION_MARGIN_S = 3n * 86_400n;     // /healthz goes 503 inside 3 days of a clerk session expiry (F5)
const SESSIONS_ABI = parseAbi(['function sessions(address) view returns (uint64 expiry, uint64 day, uint128 perRunCap, uint128 perDayCap, uint128 stagedToday, bool revoked)']);
const DEMO = 'demo';

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
    // R2-1: hits carry the salted hash of the visitor's IPv6 /48 ('' for IPv4)
    if (!this.sql.exec('PRAGMA table_info(hits)').toArray().some((c) => c.name === 'net')) this.sql.exec("ALTER TABLE hits ADD COLUMN net TEXT NOT NULL DEFAULT ''");
    this.sql.exec('CREATE INDEX IF NOT EXISTS hits_net ON hits(net, ts)');
    // extractor demo (/extract): its own hits table, so it can never use up or unlock the attack budget
    this.sql.exec(`CREATE TABLE IF NOT EXISTS xhits (ip TEXT NOT NULL, ts INTEGER NOT NULL, net TEXT NOT NULL DEFAULT '');
      CREATE INDEX IF NOT EXISTS xhits_ip ON xhits(ip, ts); CREATE INDEX IF NOT EXISTS xhits_ts ON xhits(ts);`);
    this.tail = Promise.resolve();
    this.queued = 0;
    this.sb = null;
    this.treasuryCache = null;
    this.healthCache = null;
    this.recoverInterrupted();
  }

  /** F8: an attempt still 'running' when the object starts was cut off (CPU kill, redeploy, eviction): close it as a fault. */
  recoverInterrupted() {
    for (const r of this.sql.exec("SELECT id, kind, rec FROM attempts WHERE outcome = 'running'").toArray()) {
      const rec = JSON.parse(r.rec);
      rec.outcome = 'fault';
      rec.note = 'interrupted before it finished; any transaction it sent is on the explorer under the sandbox keys';
      this.sql.exec("UPDATE attempts SET outcome = 'fault', rec = ? WHERE id = ?", JSON.stringify(rec), r.id);
      this.count(r.kind, 'fault', 0);
    }
  }

  count(kind, outcome, txs) {
    this.sql.exec(`INSERT INTO counts (kind, attempts, refused, accepted, faults, resting, txs) VALUES (?, 1, ?, ?, ?, ?, ?)
      ON CONFLICT(kind) DO UPDATE SET attempts = attempts + 1, refused = refused + excluded.refused, accepted = accepted + excluded.accepted,
      faults = faults + excluded.faults, resting = resting + excluded.resting, txs = txs + excluded.txs`,
      kind, +(outcome === 'refused'), +(outcome === 'accepted'), +(outcome === 'fault'), +(outcome === 'resting'), txs);
  }

  salt() {
    const row = this.sql.exec("SELECT v FROM meta WHERE k='salt'").toArray()[0];
    if (row) return row.v;
    const s = [...crypto.getRandomValues(new Uint8Array(32))].map((b) => b.toString(16).padStart(2, '0')).join('');
    this.sql.exec("INSERT INTO meta (k, v) VALUES ('salt', ?)", s);
    return s;
  }

  async ipHash(key) {
    const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(this.salt() + '|' + key));
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

  /** Synchronous check-and-reserve: SQLite calls are synchronous inside a DO, so two requests cannot both take the last slot.
   *  Demo requests (secret header, checked in the Worker) use their own daily budget and are left out of the public caps. */
  reserve(ipH, netH, now, L, demo) {
    const ds = dayStart(now);
    if (this.queued >= L.maxQueue) return { ok: false, code: 'busy', retryAfter: 30 };
    if (demo) {
      const d = this.sql.exec('SELECT COUNT(*) AS n FROM hits WHERE ip = ? AND ts >= ?', DEMO, ds).one().n;
      if (d >= L.demoDay) return { ok: false, code: 'demo_day', retryAfter: Math.ceil((ds + 86_400_000 - now) / 1000) };
      this.sql.exec('INSERT INTO hits (ip, ts) VALUES (?, ?)', DEMO, now);
      return { ok: true };
    }
    const g = this.sql.exec('SELECT COUNT(*) AS n FROM hits WHERE ts >= ? AND ip != ?', ds, DEMO).one().n;
    if (g >= L.globalDay) return { ok: false, code: 'global_day', retryAfter: Math.ceil((ds + 86_400_000 - now) / 1000) };
    const hr = this.sql.exec('SELECT COUNT(*) AS n, MIN(ts) AS first FROM hits WHERE ts >= ? AND ip != ?', now - 3_600_000, DEMO).one();
    if (hr.n >= L.globalHour) return { ok: false, code: 'global_hour', retryAfter: Math.max(1, Math.ceil((hr.first + 3_600_000 - now) / 1000)) };
    if (netH) {
      const nh = this.sql.exec('SELECT COUNT(*) AS n, MIN(ts) AS first FROM hits WHERE net = ? AND ts >= ?', netH, now - 3_600_000).one();
      if (nh.n >= L.net48Hour) return { ok: false, code: 'net_hour', retryAfter: Math.max(1, Math.ceil((nh.first + 3_600_000 - now) / 1000)) };
    }
    const mine = this.sql.exec('SELECT MAX(ts) AS last FROM hits WHERE ip = ? AND ts >= ?', ipH, now - 86_400_000 * 2).one();
    const today = this.sql.exec('SELECT COUNT(*) AS n FROM hits WHERE ip = ? AND ts >= ?', ipH, ds).one().n;
    if (today >= L.ipDay) return { ok: false, code: 'ip_day', retryAfter: Math.ceil((ds + 86_400_000 - now) / 1000) };
    if (mine.last !== null && now - mine.last < L.ipIntervalS * 1000) return { ok: false, code: 'ip_interval', retryAfter: Math.ceil((mine.last + L.ipIntervalS * 1000 - now) / 1000) };
    this.sql.exec('INSERT INTO hits (ip, ts, net) VALUES (?, ?, ?)', ipH, now, netH);
    this.sql.exec('DELETE FROM hits WHERE ts < ?', now - 86_400_000 * 2);
    return { ok: true };
  }

  /** /extract rate limits (no chain sends, no queue). Synchronous check-and-reserve, like reserve(). */
  async extractReserve({ ip, net = '', demo = false }) {
    if (this.env.SANDBOX_OFF === '1' || this.env.EXTRACT_OFF === '1') return { status: 503, code: 'xoff' };
    if (typeof ip !== 'string' || !ip || ip.length > 64 || typeof net !== 'string' || net.length > 64) return { status: 400, code: 'ip' };
    const L = extractLimitsFrom(this.env);
    const now = Date.now(), ds = dayStart(now);
    const day = (s) => Math.ceil((ds + 86_400_000 - now) / 1000);
    if (demo === true) {
      const d = this.sql.exec('SELECT COUNT(*) AS n FROM xhits WHERE ip = ? AND ts >= ?', DEMO, ds).one().n;
      if (d >= L.demoDay) return { status: 429, code: 'x_demo_day', retryAfter: day() };
      this.sql.exec('INSERT INTO xhits (ip, ts) VALUES (?, ?)', DEMO, now);
      return { status: 200 };
    }
    const ipH = await this.ipHash('x|' + ip), netH = net ? await this.ipHash('x|' + net) : '';
    const g = this.sql.exec('SELECT COUNT(*) AS n FROM xhits WHERE ts >= ? AND ip != ?', ds, DEMO).one().n;
    if (g >= L.globalDay) return { status: 429, code: 'x_global_day', retryAfter: day() };
    if (netH) {
      const nh = this.sql.exec('SELECT COUNT(*) AS n, MIN(ts) AS first FROM xhits WHERE net = ? AND ts >= ?', netH, now - 3_600_000).one();
      if (nh.n >= L.net48Hour) return { status: 429, code: 'x_net_hour', retryAfter: Math.max(1, Math.ceil((nh.first + 3_600_000 - now) / 1000)) };
    }
    const today = this.sql.exec('SELECT COUNT(*) AS n FROM xhits WHERE ip = ? AND ts >= ?', ipH, ds).one().n;
    if (today >= L.ipDay) return { status: 429, code: 'x_day', retryAfter: day() };
    const last = this.sql.exec('SELECT MAX(ts) AS last FROM xhits WHERE ip = ? AND ts >= ?', ipH, now - 86_400_000).one().last;
    if (last !== null && now - last < L.ipIntervalS * 1000) return { status: 429, code: 'x_interval', retryAfter: Math.ceil((last + L.ipIntervalS * 1000 - now) / 1000) };
    this.sql.exec('INSERT INTO xhits (ip, ts, net) VALUES (?, ?, ?)', ipH, now, netH);
    this.sql.exec('DELETE FROM xhits WHERE ts < ?', now - 86_400_000 * 2);
    return { status: 200 };
  }

  /** RPC from the Worker. Input already validated there (kind whitelist, text size, Turnstile or demo); validated again here.
   *  `ip` is the visitor KEY (IPv4 or IPv6 /64), already grouped by the Worker. */
  async attack({ kind, text, ip, net = '', demo = false }) {
    if (this.env.SANDBOX_OFF === '1') return { status: 503, code: 'off' };
    if (!Object.hasOwn(KINDS, kind)) return { status: 400, code: 'kind' };
    if (typeof ip !== 'string' || !ip || ip.length > 64 || typeof net !== 'string' || net.length > 64) return { status: 400, code: 'ip' };
    if (text !== undefined && (typeof text !== 'string' || text.length > 4096)) return { status: 413, code: 'text' };
    if (!KINDS[kind].invoice) text = undefined;
    const L = limitsFrom(this.env);
    const r = this.reserve(await this.ipHash(ip), net ? await this.ipHash(net) : '', Date.now(), L, demo === true);
    if (!r.ok) return { status: r.code === 'busy' ? 503 : 429, code: r.code, retryAfter: r.retryAfter };
    this.queued++;
    const job = this.tail.then(() => this.run(kind, text));
    this.tail = job.catch(() => {});
    try { return await job; } finally { this.queued--; }
  }

  async run(kind, text) {
    const at = Date.now();
    const K = KINDS[kind];
    // F8: the row exists BEFORE the first send, so a cut-off attempt still leaves a public record
    const id = this.sql.exec('INSERT INTO attempts (at, kind, outcome, rec) VALUES (?, ?, ?, ?) RETURNING id', at, kind, 'running',
      JSON.stringify({ kind, n: K.n, title: K.title, expect: K.expect, outcome: 'running', at: new Date(at).toISOString(), note: null, steps: [], offchain: null })).one().id;
    let res, outcome, detail = null;
    try {
      const S = this.sandbox();
      if (!this.chainChecked) {
        if ((await S.pub.getChainId()) !== this.cfg.chainId) throw new Error('RPC chain id mismatch');
        this.chainChecked = true;
      }
      res = jsonSafe(await S.attack(kind, { text }));
      outcome = res.fault ? 'fault' : K.control ? (res.accepted ? 'accepted' : 'fault') : res.refused ? 'refused' : res.accepted ? 'accepted'
        : res.notCounted ? 'not_counted' : 'fault';
    } catch (e) {
      const resting = e instanceof SandboxError;
      outcome = resting ? 'resting' : 'fault';
      // no key material can be in these messages; keep them short anyway
      const msg = String(e?.shortMessage || e?.message || e).replace(/0x[0-9a-fA-F]{64,}/g, '0x…').slice(0, 160);
      console.log(JSON.stringify({ ev: 'attack_error', kind, resting, name: e?.name, msg }));
      res = { kind, n: K.n, title: K.title, expect: K.expect, steps: [], note: resting ? msg : 'the sandbox hit an error; nothing was paid' };
    }
    try {
      // PUBLIC record: no visitor text, no reasons quoting it; only our step data (role names, tx hashes, decoded errors).
      const rec = {
        kind, n: res.n, title: res.title, expect: res.expect, outcome, at: new Date(at).toISOString(), note: res.note || null,
        steps: (res.steps || []).map((s) => ({ step: s.step, from: s.from, sent: !!s.sent, hash: s.hash || null, status: s.status || null,
          error: s.error || null, errorArgs: (s.errorArgs || []).slice(0, 6).map((a) => String(a).slice(0, 80)), simulated: s.simulated || null,
          block: s.block || null, gasUsed: s.gasUsed || null, note: s.note || null })),
        offchain: res.offchain ? { decision: res.offchain.decision, cop: res.offchain.cop, replacedAddress: !!res.offchain.replacedAddress } : null,
      };
      const txs = rec.steps.filter((s) => s.sent).length;
      this.sql.exec('UPDATE attempts SET outcome = ?, rec = ? WHERE id = ?', outcome, JSON.stringify(rec), id);
      this.sql.exec('DELETE FROM attempts WHERE id <= ?', id - KEEP);
      this.count(kind, outcome, txs);
      console.log(JSON.stringify({ ev: 'attempt', id, kind, outcome, txs }));
      // PRIVATE detail for the visitor who asked (returned once, never stored): off-chain verdict with reasons.
      if (res.offchain) detail = { reasons: res.offchain.reasons || [], warnings: res.offchain.warnings || [], proposed: res.offchain.proposed || {} };
      return { status: 200, id, rec: { id, ...rec }, detail };
    } catch (e) {
      // R2 (F8 gap): if building or saving the record fails, the row must not stay 'running'
      console.log(JSON.stringify({ ev: 'record_failed', kind, name: e?.name }));
      const rec = { kind, n: K.n, title: K.title, expect: K.expect, outcome: 'fault', at: new Date(at).toISOString(), note: 'the sandbox could not save this attempt', steps: [], offchain: null };
      if (this.sql.exec('SELECT outcome FROM attempts WHERE id = ?', id).toArray()[0]?.outcome === 'running') {
        this.sql.exec("UPDATE attempts SET outcome = 'fault', rec = ? WHERE id = ?", JSON.stringify(rec), id);
        this.count(kind, 'fault', 0);
      }
      return { status: 200, id, rec: { id, ...rec }, detail: null };
    }
  }

  async state({ limit = 25 } = {}) {
    const n = Math.max(1, Math.min(KEEP, Number(limit) || 25));
    const attempts = this.sql.exec('SELECT id, rec FROM attempts ORDER BY id DESC LIMIT ?', n).toArray().map((r) => ({ id: r.id, ...JSON.parse(r.rec) }));
    const counts = Object.fromEntries(this.sql.exec('SELECT * FROM counts').toArray().map((r) => [r.kind, r]));
    const ds = dayStart(Date.now());
    const today = this.sql.exec('SELECT COUNT(*) AS n FROM hits WHERE ts >= ? AND ip != ?', ds, DEMO).one().n;
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

  /** Health (F3: cached 30 s, booleans only): config parses, RPC answers with the right chain, every key above its gas floor,
   *  clerk + daycap sessions valid for more than 3 more days (F5). */
  async health() {
    const now = Date.now();
    if (this.healthCache && now - this.healthCache.t < HEALTH_TTL_MS) return this.healthCache.v;
    const out = { config: false, chain: false, keysAboveFloor: false, sessionsValid: false, off: this.env.SANDBOX_OFF === '1' };
    try {
      const S = this.sandbox(); out.config = true;
      out.chain = (await S.pub.getChainId()) === this.cfg.chainId;
      const floor = BigInt(this.cfg.minBalanceWei);
      const bals = await Promise.all(Object.values(this.cfg.addresses).map((a) => S.pub.getBalance({ address: a })));
      out.keysAboveFloor = bals.length === 8 && bals.every((b) => b >= floor);
      const ts = (await S.pub.getBlock()).timestamp;
      const exp = await Promise.all(['clerk', 'daycap'].map((r) => S.pub.readContract({ address: this.cfg.payrun, abi: SESSIONS_ABI, functionName: 'sessions', args: [this.cfg.addresses[r]] })));
      out.sessionsValid = exp.every((s) => s[0] > ts + SESSION_MARGIN_S && s[5] === false);
    } catch (e) { console.log(JSON.stringify({ ev: 'health_failed', name: e?.name })); }
    out.ok = out.config && out.chain && out.keysAboveFloor && out.sessionsValid;
    out.checkedAt = new Date(now).toISOString();
    this.healthCache = { t: now, v: out };
    return out;
  }
}
