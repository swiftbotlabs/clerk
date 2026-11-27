#!/usr/bin/env node
// Read-only watcher for the sandbox PayRunV2/V3 (review condition 5). Nothing here signs or sends; no keys are read.
// Every check: scan Paid events since the last scanned block + read the treasury's tUSD8 balance and allowance.
//   - Any Paid other than the setup's seed payment (and, V3 from r9, the one seeded genuine payment in state.genuine_paid) -> ALERT (the sandbox must never pay; "TO NON-CONTROL VENDOR" when the payee is
//     not Acme's registered wallet).
//   - Treasury balance below its setup value (0.09 tUSD8, minus the seeded genuine payment) -> ALERT.
//   - A failed read is a failure, never "nothing new"; 5 failures in a row -> exit 1 (so Restart=on-failure / the caller notices).
// One log line per check (time, rc, state) in --log; stdout gets only state changes and alerts (for a Monitor).
//
//   node watch_paid.mjs --state sandbox-testnet.json --log ~/agent/tmp/aevum-sandbox-paid.log            (loop, every 300 s)
//   node watch_paid.mjs --state work/fork-state.json --rpc http://127.0.0.1:18546 --log work/paid.log --once   (exit 0 OK, 2 ALERT, 1 error)
import { readFileSync, writeFileSync, appendFileSync, existsSync, renameSync } from 'node:fs';
import { createPublicClient, http, parseAbi, parseEventLogs } from 'viem';

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const die = (m) => { console.error('FAIL: ' + m); process.exit(1); };
const stateFile = opt('--state'), logFile = opt('--log');
if (!stateFile || !logFile) die('--state and --log are required');
const st = JSON.parse(readFileSync(stateFile, 'utf8'));
const rpc = opt('--rpc', 'https://rpc-test.qday.info');
if (!(rpc === 'https://rpc-test.qday.info' || /^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(rpc))) die('rpc must be the Aevum testnet RPC or a local fork');
const ONCE = args.includes('--once');
const INTERVAL = Math.max(30, Number(opt('--interval', '300')));
const MAX_FAILS = 5, CHUNK = 900n;   // QDay testnet RPC caps eth_getLogs at 1000 blocks (11-25)
const cursorFile = logFile + '.cursor';
const TUSD = '0x456569838f1d43009A91ebA4263147Afd7233483';
// the V3 sandbox's vendors live in its own VendorRegistry (state.registry); the V2 sandbox's in QDay's ERC-8004 registry
const REG = /^0x[0-9a-fA-F]{40}$/.test(st.registry || '') ? st.registry : '0xF45E7f39Caba1d2055f613970575a7e7069636Be';
// r9: the seeded genuine payment (seed_sandbox.mjs pay) is the one other allowed Paid: exactly its tx, run, Acme's wallet and amount.
const GP = st.genuine_paid && /^0x[0-9a-f]{64}$/.test(st.genuine_paid.paid_tx || '') && /^\d{1,9}$/.test(st.genuine_paid.run || '') && /^\d{1,7}$/.test(st.genuine_paid.amount || '')
  ? st.genuine_paid : null;
const START_TREASURY = 90_000n - (GP ? BigInt(GP.amount) : 0n);
for (const k of ['payrun', 'payrun_block', 'seed_run', 'acme_id']) if (!st[k]) die(`state file lacks ${k}`);

const ABI = parseAbi([
  'event Paid(uint256 indexed runId, uint256 line, bytes32 indexed invoiceHash, bytes32 invoiceRef, uint256 indexed agentId, address payee, uint256 amount)',
  'function balanceOf(address) view returns (uint256)', 'function allowance(address,address) view returns (uint256)',
  'function getAgentWallet(uint256) view returns (address)']);
const pub = createPublicClient({ transport: http(rpc, { timeout: 20_000, retryCount: 1 }) });
const now = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');
const log = (line) => appendFileSync(logFile, `${now()} ${line}\n`);

async function check() {
  if ((await pub.getChainId()) !== 44005) throw new Error('chain id is not 44005');
  const head = await pub.getBlockNumber();
  let from = existsSync(cursorFile) ? BigInt(readFileSync(cursorFile, 'utf8').trim()) + 1n : BigInt(st.payrun_block);
  const alerts = [];
  let scanned = 0n;
  const acme = (await pub.readContract({ address: REG, abi: ABI, functionName: 'getAgentWallet', args: [BigInt(st.acme_id)] })).toLowerCase();
  while (from <= head) {
    const to = from + CHUNK - 1n < head ? from + CHUNK - 1n : head;
    const logs = await pub.getLogs({ address: st.payrun, event: ABI[0], fromBlock: from, toBlock: to });
    for (const l of parseEventLogs({ abi: ABI, logs })) {
      if (l.args.runId === BigInt(st.seed_run)) continue;                  // the setup's own 0.01 payment to Acme
      if (GP && l.transactionHash === GP.paid_tx && l.args.runId === BigInt(GP.run) && l.args.amount === BigInt(GP.amount)
        && l.args.payee.toLowerCase() === acme) continue;                   // the seeded genuine payment (one tx, recorded in the state file)
      const who = l.args.payee.toLowerCase() === acme ? 'to the control vendor (Acme)' : 'TO NON-CONTROL VENDOR';
      alerts.push(`PAID ${who}: run ${l.args.runId} agent ${l.args.agentId} payee ${l.args.payee} amount ${l.args.amount} tx ${l.transactionHash}`);
    }
    scanned += to - from + 1n;
    writeFileSync(cursorFile + '.tmp', String(to)); renameSync(cursorFile + '.tmp', cursorFile);   // advance only after a clean read
    from = to + 1n;
  }
  const treasury = st.addresses?.treasury;
  let bal = null, allow = null;
  if (treasury) {
    bal = await pub.readContract({ address: TUSD, abi: ABI, functionName: 'balanceOf', args: [treasury] });
    allow = await pub.readContract({ address: TUSD, abi: ABI, functionName: 'allowance', args: [treasury, st.payrun] });
    if (bal < START_TREASURY) alerts.push(`TREASURY DROPPED: ${bal} < ${START_TREASURY} units`);
  }
  return { head, scanned, bal, allow, alerts };
}

let fails = 0, lastState = '';
for (;;) {
  let rc = 0, stateNow, line;
  try {
    const r = await check();
    stateNow = r.alerts.length ? 'ALERT' : 'OK';
    rc = r.alerts.length ? 2 : 0;
    line = `rc=${rc} state=${stateNow} head=${r.head} scanned=${r.scanned} treasury=${r.bal ?? 'n/a'} allowance=${r.allow ?? 'n/a'}`;
    log(line);
    for (const a of r.alerts) { log('ALERT ' + a); console.log(`${now()} ALERT ${a}`); }
    fails = 0;
  } catch (e) {
    rc = 1; stateNow = 'ERROR'; fails++;
    line = `rc=1 state=ERROR fails=${fails} ${String(e?.shortMessage || e?.message || e).replace(/\s+/g, ' ').slice(0, 160)}`;
    log(line);
  }
  if (stateNow !== lastState) { console.log(`${now()} ${line}`); lastState = stateNow; }
  if (ONCE) process.exit(rc);
  if (fails >= MAX_FAILS) { console.log(`${now()} EXIT: ${MAX_FAILS} failed checks in a row`); process.exit(1); }
  await new Promise((res) => setTimeout(res, INTERVAL * 1000));
}
