#!/usr/bin/env node
// Seed the PayRunV3 public sandbox so a visitor sees a full log at once: every attack kind (1-17) refused on chain through the
// live Worker's own public flow, the genuine control staged through the same flow, and that one genuine run then PAID by the
// sandbox owner (the only payment the sandbox makes besides the deploy seed). Testnet or a local anvil fork only.
//
//   1. attacks (through the Worker, demo budget; nothing here holds a key):
//      node seed_sandbox.mjs attacks --base https://clerk-sandbox.swiftbotlab.workers.dev --token-file ~/agent/secrets/aevum_sandbox_demo_token \
//           --out seed-r9.json
//      POST /attack with `Authorization: Bearer <demo token>` (the Worker's reserved demo budget, 40/day: it replaces the human check,
//      not the kill switch, the queue or the contract). One attempt at a time, kinds 1..17 then the genuine control. Each answer
//      must be the expected outcome (refused with the expected error / genuine accepted) or the run stops (exit 1). Progress is
//      written to --out after every attempt; a re-run skips the kinds already recorded there (resume after a kill).
//   2. pay the genuine run (owner key, read in-process from --keys; never printed):
//      node seed_sandbox.mjs pay --state sandbox-testnet-v3.json --keys ~/agent/secrets/aevum_sandbox_v3_keys.json --out seed-r9.json
//      Reads the genuine attempt's stage tx from --out, finds its run on chain and pays it ONLY if every check holds: staged by the
//      sandbox clerk key in that tx, one line, Acme (signedOnly) at Acme's REGISTERED wallet, 0.02 tUSD8, Acme's InvoiceSigned
//      event in the same tx, status Staged, canExecute ok, simulation of execute ok. After the send: exactly one Paid event (that
//      run, Acme's wallet, 0.02), treasury down by exactly 0.02. Records `genuine_paid` in the state file (mkvars puts it in the
//      Worker config: the page and /api/state show it). Refuses if the state file already has a genuine_paid (one payment, ever).
//   3. read-backs (read-only): node seed_sandbox.mjs check --base <url> --state sandbox-testnet-v3.json [--out seed-r9.json]
//      /api/state: every kind 1-17 refused >= 1, genuine accepted >= 1, 0 new faults, config.seed.genuine = the state's genuine_paid,
//      treasury = 0.09 - 0.02; on chain: the Paid event of that tx (run, Acme, 0.02). Exit 0 only if all hold.
// --rpc http://127.0.0.1:<port> for a fork (any other RPC than the Aevum testnet one is refused); --base http://127.0.0.1:<port>
// for wrangler dev (then --ip sets the cf-connecting-ip header wrangler dev needs).
import { readFileSync, writeFileSync, renameSync, lstatSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { createPublicClient, createWalletClient, http, parseEventLogs, decodeFunctionData } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { KINDS, kindsFor, PAYRUN_ABI, REGISTRY_ABI, ERC20_ABI } from './lib/sandbox.mjs';

const TESTNET_RPC = 'https://rpc-test.qday.info', LIVE_BASE = 'https://clerk-sandbox.swiftbotlab.workers.dev';
const TUSD = '0x456569838f1d43009A91ebA4263147Afd7233483';
const GENUINE_UNITS = 20_000n;           // the genuine sample invoice: 0.02 tUSD8 (6 decimals)
const SETUP_TREASURY = 90_000n;          // 0.09 after the deploy seed payment (deploy.mjs check)
const args = process.argv.slice(2);
const cmd = args[0];
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const die = (m) => { console.error('FAIL: ' + m); process.exit(1); };
const say = (m) => console.log(`${new Date().toISOString().replace(/\.\d+Z$/, 'Z')} ${m}`);
if (!['attacks', 'pay', 'check'].includes(cmd)) die('usage: seed_sandbox.mjs attacks|pay|check ... (see the header)');

const base = opt('--base', LIVE_BASE);
if (!(base === LIVE_BASE || /^http:\/\/127\.0\.0\.1:\d{2,5}$/.test(base))) die('--base must be the live sandbox or a local wrangler dev');
const rpc = opt('--rpc', TESTNET_RPC);
if (!(rpc === TESTNET_RPC || /^http:\/\/127\.0\.0\.1:\d{2,5}$/.test(rpc))) die('--rpc must be the Aevum testnet RPC or a local fork');
if (cmd !== 'pay' && (base === LIVE_BASE) !== (rpc === TESTNET_RPC)) die('live Worker goes with the testnet RPC, wrangler dev with a fork');
const ip = opt('--ip', '');              // only for wrangler dev (Cloudflare sets cf-connecting-ip itself)
if (ip && base === LIVE_BASE) die('--ip is for wrangler dev only');
const outFile = opt('--out');

/** Read a secret file in-process: a regular file (not a symlink), not world-readable, small. Its value is never printed. */
function secretFile(p) {
  if (!p) die('secret file path missing');
  p = p.replace(/^~(?=\/)/, homedir());
  const st = lstatSync(p);
  if (st.isSymbolicLink() || !st.isFile()) die('secret file is a symlink or not a file');
  if (st.mode & 0o004) die('secret file is world-readable');
  if (st.size > 16_384) die('secret file too large');
  return readFileSync(p, 'utf8');
}
const loadOut = () => (outFile && existsSync(outFile) ? JSON.parse(readFileSync(outFile, 'utf8')) : { attempts: {} });
function saveJson(file, obj) { const tmp = `${file}.tmp-${process.pid}`; writeFileSync(tmp, JSON.stringify(obj, null, 1) + '\n'); renameSync(tmp, file); }
const chain = { id: 44005, name: 'aevum', nativeCurrency: { name: 'tQDAY', symbol: 'tQDAY', decimals: 18 }, rpcUrls: { default: { http: [rpc] } } };
const pub = createPublicClient({ chain, transport: http(rpc, { timeout: 20_000, retryCount: 1 }) });
const hdr = () => (ip ? { 'cf-connecting-ip': ip } : {});

// the expected answer of each kind (the last sent step's error; 11/12 are executes that emit PaymentBlocked)
const ORDER = Object.entries(kindsFor('v3')).filter(([, K]) => !K.control).sort((a, b) => a[1].n - b[1].n).map(([k]) => k).concat(['genuine']);

async function attacks() {
  if (!outFile) die('--out is required');
  const token = secretFile(opt('--token-file')).trim();
  if (!/^[A-Za-z0-9_-]{32,256}$/.test(token)) die('demo token file is not a token');
  const out = loadOut();
  out.base = base; out.started ||= new Date().toISOString();
  const only = opt('--kinds') ? opt('--kinds').split(',') : null;
  for (const k of only || []) if (!ORDER.includes(k)) die(`unknown kind ${k}`);
  // the Worker must be the V3 sandbox and healthy before the first send
  const h = await (await fetch(base + '/healthz', { headers: hdr(), signal: AbortSignal.timeout(30_000) })).json();
  if (h.ok !== true) die(`/healthz is not ok: ${JSON.stringify(h)}`);
  const s0 = await (await fetch(base + '/api/state', { headers: hdr(), signal: AbortSignal.timeout(30_000) })).json();
  if (s0.config?.version !== 'v3') die('the Worker is not the PayRunV3 sandbox');
  if (s0.off) die('the sandbox is paused (SANDBOX_OFF)');
  out.payrun = s0.config.payrun;
  let sent = 0;
  for (const kind of ORDER) {
    if (only && !only.includes(kind)) continue;
    if (out.attempts[kind]?.ok) { say(`skip ${kind}: done before (attempt #${out.attempts[kind].id})`); continue; }
    const K = KINDS[kind];
    const r = await fetch(base + '/attack', { method: 'POST', signal: AbortSignal.timeout(300_000),
      headers: { ...hdr(), 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json', authorization: `Bearer ${token}` },
      body: new URLSearchParams({ kind }).toString() });
    const t = await r.text();
    let j = null; try { j = JSON.parse(t); } catch {}
    sent++;
    if (r.status !== 200 || !j?.ok) {
      // a refusal BEFORE the chain (demo budget, busy, paused): nothing was recorded; stop and let the operator read the code
      out.attempts[kind] = { ok: false, http: r.status, code: j?.code ?? null, retryAfter: j?.retryAfter ?? null };
      saveJson(outFile, out);
      die(`${kind}: HTTP ${r.status} ${j?.code ?? t.slice(0, 80)} (nothing sent for this kind; resume later with the same --out)`);
    }
    const a = j.attempt, steps = a.steps || [];
    const last = steps.filter((s) => s.sent).at(-1);
    const want = K.control ? 'accepted' : 'refused';
    const errOk = K.control ? true : String(last?.error || '').startsWith(K.expect.split(':')[0]);
    const ok = a.outcome === want && errOk && !!last?.hash;
    out.attempts[kind] = { ok, id: a.id, n: K.n, outcome: a.outcome, expect: K.expect, error: last?.error ?? null,
      txs: steps.filter((s) => s.sent).map((s) => ({ step: s.step, from: s.from, hash: s.hash, status: s.status, error: s.error })) };
    saveJson(outFile, out);
    say(`${String(K.n || 'C').padStart(2)} ${kind}: #${a.id} ${a.outcome} ${last?.error ?? ''} ${last?.hash ?? ''}`);
    if (!ok) die(`${kind}: expected ${want} (${K.expect}), got ${a.outcome} ${last?.error ?? ''}: stopping (see ${base}/attempt/${a.id})`);
  }
  out.finished = new Date().toISOString();
  saveJson(outFile, out);
  const done = ORDER.filter((k) => out.attempts[k]?.ok).length;
  say(`ATTACKS ${done === ORDER.length ? 'DONE' : 'PARTIAL'}: ${done}/${ORDER.length} kinds recorded (${sent} sent now)`);
  if (done !== ORDER.length && !only) process.exit(1);
}

async function pay() {
  if (!outFile) die('--out is required');
  const stateFile = opt('--state'); if (!stateFile) die('--state is required');
  const st = JSON.parse(readFileSync(stateFile, 'utf8'));
  if (st.version !== 'v3') die('state file is not the PayRunV3 sandbox');
  if ((st.mode === 'testnet') !== (rpc === TESTNET_RPC)) die(`state file is mode ${st.mode}; RPC does not match`);
  if (st.genuine_paid) die(`the state file already records a genuine payment (run ${st.genuine_paid.run}): one payment only`);
  const g = loadOut().attempts?.genuine;
  if (!g?.ok || g.outcome !== 'accepted') die('no accepted genuine attempt in --out (run `attacks` first)');
  const stageTx = g.txs.at(-1)?.hash;
  if (!/^0x[0-9a-f]{64}$/.test(stageTx || '')) die('genuine stage tx missing');
  const keysAll = JSON.parse(secretFile(opt('--keys'))).keys;
  if (!/^0x[0-9a-fA-F]{64}$/.test(keysAll?.owner || '')) die('owner key missing');
  const owner = privateKeyToAccount(keysAll.owner);                  // only the owner key is kept; the rest is dropped here
  if (owner.address !== st.addresses.owner) die('owner key does not match the state file');
  if ((await pub.getChainId()) !== 44005) die('chain id is not 44005');
  const read = (fn, a = []) => pub.readContract({ address: st.payrun, abi: PAYRUN_ABI, functionName: fn, args: a });
  if ((await read('owner')).toLowerCase() !== owner.address.toLowerCase()) die('PayRunV3 owner is not the sandbox owner');

  // ---- the run behind the genuine attempt, every check before any send
  const rc = await pub.getTransactionReceipt({ hash: stageTx });
  const tx = await pub.getTransaction({ hash: stageTx });
  const fails = [];
  const need = (c, m) => { if (!c) fails.push(m); };
  need(rc.status === 'success', 'stage tx did not succeed');
  need(tx.to?.toLowerCase() === st.payrun.toLowerCase(), 'stage tx is not to the sandbox PayRunV3');
  need(tx.from.toLowerCase() === st.addresses.clerk.toLowerCase(), 'stage tx is not from the sandbox clerk key');
  const ev = parseEventLogs({ abi: PAYRUN_ABI, logs: rc.logs.filter((l) => l.address.toLowerCase() === st.payrun.toLowerCase()) });
  const staged = ev.filter((e) => e.eventName === 'Staged');
  need(staged.length === 1, 'not exactly one Staged event');
  const runId = staged[0]?.args.runId;
  const call = decodeFunctionData({ abi: PAYRUN_ABI, data: tx.input });
  need(call.functionName === 'stageSigned', 'not a stageSigned call');
  const lines = call.args?.[0] || [];
  need(lines.length === 1, 'not exactly one line');
  const L = lines[0] || {};
  const acmeWallet = await pub.readContract({ address: st.registry, abi: REGISTRY_ABI, functionName: 'getAgentWallet', args: [BigInt(st.acme_id)] });
  need(String(L.payeeAgentId) === String(st.acme_id), 'line is not Acme');
  need(L.payee?.toLowerCase() === acmeWallet.toLowerCase() && acmeWallet.toLowerCase() === st.addresses.vendor_acme.toLowerCase(), "payee is not Acme's registered wallet");
  need(L.amount === GENUINE_UNITS, 'amount is not 0.02 tUSD8');
  need(await read('signedOnly', [BigInt(st.acme_id)]), 'Acme is not signedOnly');
  const signed = ev.filter((e) => e.eventName === 'InvoiceSigned' && e.args.runId === runId);
  need(signed.length === 1 && signed[0].args.signer.toLowerCase() === acmeWallet.toLowerCase(), "no InvoiceSigned by Acme's wallet in the stage tx");
  const run = runId !== undefined ? await read('runs', [runId]) : null;
  need(run && Number(run[0]) === 1, 'run is not in status Staged');
  need(run && run[1].toLowerCase() === st.addresses.clerk.toLowerCase() && run[3] === GENUINE_UNITS && Number(run[4]) === 1, 'run record differs');
  const [canOk, , reason] = runId !== undefined ? await read('canExecute', [runId]) : [false, 0, 0];
  need(canOk === true, `canExecute says no (reason ${reason})`);
  const bal0 = await pub.readContract({ address: TUSD, abi: ERC20_ABI, functionName: 'balanceOf', args: [st.addresses.treasury] });
  const acme0 = await pub.readContract({ address: TUSD, abi: ERC20_ABI, functionName: 'balanceOf', args: [acmeWallet] });
  need(bal0 >= GENUINE_UNITS, 'treasury cannot cover 0.02');
  if (fails.length) die('NOT PAID, checks failed: ' + fails.join('; '));
  say(`genuine run ${runId}: staged by the clerk in ${stageTx}, 1 line, Acme #${st.acme_id} -> ${acmeWallet}, 0.02 tUSD8, signed by Acme, canExecute ok`);
  const sim = await pub.simulateContract({ address: st.payrun, abi: PAYRUN_ABI, functionName: 'execute', args: [runId], account: owner });
  if (sim.result !== true) die('simulated execute does not pay');
  if (args.includes('--dry-run')) { say('DRY RUN: all checks pass; nothing sent'); return; }

  // ---- the one send
  const gasPrice = await pub.getGasPrice();
  if (gasPrice > 5_000_000_000n) die('gas price above 5 gwei');
  const wallet = createWalletClient({ chain, transport: http(rpc, { timeout: 20_000, retryCount: 0 }), account: owner });
  const hash = await wallet.writeContract({ address: st.payrun, abi: PAYRUN_ABI, functionName: 'execute', args: [runId], gas: 400_000n, gasPrice, type: 'legacy' });
  say(`execute(${runId}) sent: ${hash}`);
  // record the hash at once (a kill after this line must not lead to a second send: genuine_paid blocks the re-run)
  st.genuine_paid = { attempt: g.id, run: String(runId), stage_tx: stageTx, paid_tx: hash, amount: String(GENUINE_UNITS), payee: acmeWallet, confirmed: false };
  saveJson(stateFile, st);
  const r2 = await pub.waitForTransactionReceipt({ hash, timeout: 180_000 });
  const pe = parseEventLogs({ abi: PAYRUN_ABI, logs: r2.logs.filter((l) => l.address.toLowerCase() === st.payrun.toLowerCase()) }).filter((e) => e.eventName === 'Paid');
  const bal1 = await pub.readContract({ address: TUSD, abi: ERC20_ABI, functionName: 'balanceOf', args: [st.addresses.treasury] });
  const acme1 = await pub.readContract({ address: TUSD, abi: ERC20_ABI, functionName: 'balanceOf', args: [acmeWallet] });
  const ok = r2.status === 'success' && pe.length === 1 && pe[0].args.runId === runId && pe[0].args.payee.toLowerCase() === acmeWallet.toLowerCase()
    && pe[0].args.amount === GENUINE_UNITS && bal0 - bal1 === GENUINE_UNITS && acme1 - acme0 === GENUINE_UNITS;
  st.genuine_paid = { ...st.genuine_paid, block: r2.blockNumber.toString(), paid_at: new Date(Number((await pub.getBlock({ blockNumber: r2.blockNumber })).timestamp) * 1000).toISOString(), confirmed: ok };
  saveJson(stateFile, st);
  if (!ok) die(`PAID TX CHECK FAILED: status ${r2.status}, Paid events ${pe.length}, treasury ${bal0} -> ${bal1}`);
  say(`GENUINE PAID: run ${runId}, 0.02 tUSD8 to Acme ${acmeWallet}, tx ${hash}; treasury ${bal0} -> ${bal1}; recorded in ${stateFile}`);
}

async function check() {
  const stateFile = opt('--state'); if (!stateFile) die('--state is required');
  const st = JSON.parse(readFileSync(stateFile, 'utf8'));
  const gp = st.genuine_paid;
  const fails = [], need = (c, m) => { if (!c) fails.push(m); };
  const s = await (await fetch(base + '/api/state', { headers: hdr(), signal: AbortSignal.timeout(30_000) })).json();
  const c = s.counts || {};
  need(s.config?.version === 'v3' && s.config.payrun.toLowerCase() === st.payrun.toLowerCase(), '/api/state is not this PayRunV3 sandbox');
  const refusedKinds = ORDER.filter((k) => k !== 'genuine' && (c[k]?.refused || 0) >= 1);
  need(refusedKinds.length === 17, `refused kinds ${refusedKinds.length}/17 (missing: ${ORDER.filter((k) => k !== 'genuine' && !refusedKinds.includes(k)).join(',')})`);
  need((c.genuine?.accepted || 0) >= 1, 'no accepted genuine control');
  const faults = Object.values(c).reduce((a, r) => a + (r.faults || 0), 0);
  need(faults === 0, `${faults} faults in the counts`);
  // every logged refusal links a tx (the page renders explorer links from these hashes)
  const recent = (s.attempts || []).filter((a) => a.outcome === 'refused');
  need(recent.length > 0 && recent.every((a) => (a.steps || []).some((x) => x.sent && /^0x[0-9a-f]{64}$/.test(x.hash || ''))), 'a refused attempt without a tx hash');
  need(!!gp?.confirmed, 'state file has no confirmed genuine_paid');
  const sg = s.config?.seed?.genuine;
  need(sg && gp && sg.paidTx === gp.paid_tx && String(sg.run) === gp.run && String(sg.attempt) === String(gp.attempt), 'Worker config seed.genuine does not match the state file (mkvars --put-secrets after `pay`?)');
  need(s.treasury === String(SETUP_TREASURY - GENUINE_UNITS), `treasury ${s.treasury}, expected ${SETUP_TREASURY - GENUINE_UNITS}`);
  if (gp?.paid_tx) {
    const rc = await pub.getTransactionReceipt({ hash: gp.paid_tx });
    const pe = parseEventLogs({ abi: PAYRUN_ABI, logs: rc.logs.filter((l) => l.address.toLowerCase() === st.payrun.toLowerCase()) }).filter((e) => e.eventName === 'Paid');
    need(rc.status === 'success' && pe.length === 1 && String(pe[0].args.runId) === gp.run && pe[0].args.amount === GENUINE_UNITS
      && pe[0].args.payee.toLowerCase() === st.addresses.vendor_acme.toLowerCase(), 'the genuine Paid event on chain does not match');
  }
  const home = await (await fetch(base + '/', { headers: hdr(), signal: AbortSignal.timeout(30_000) })).text();
  need(gp && home.includes(gp.paid_tx), 'the home page does not link the genuine payment tx');
  if (fails.length) { console.log('SEED CHECK FAIL:\n - ' + fails.join('\n - ')); process.exit(1); }
  console.log(`SEED CHECK OK: 17/17 attack kinds refused on chain, genuine accepted ${c.genuine.accepted}, faults 0, genuine run ${gp.run} Paid (tx ${gp.paid_tx}), treasury ${s.treasury}`);
}

await ({ attacks, pay, check })[cmd]();
process.exit(0);   // viem's receipt poller can keep the event loop alive after the last await
