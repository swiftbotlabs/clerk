#!/usr/bin/env node
// Clerk sandbox: deploy a SEPARATE, capped PayRunV2 on Aevum testnet (or a local fork of it) for the public "try to make
// Clerk pay the wrong payee" page. Idempotent: every step records its tx in the state file and is skipped on a re-run.
//
//   node deploy.mjs --fork  --rpc http://127.0.0.1:18546 --keys work/fork-keys.json --state work/fork-state.json
//   node deploy.mjs --testnet --keys ~/agent/secrets/aevum_sandbox_keys.json --state sandbox-testnet.json   (local agent only)
//   node deploy.mjs --gen-keys <file>     (fresh TESTNET-ONLY keys, chmod 600; prints addresses only)
//
// What it sets up (same verified PayRunV2 bytecode as the main deployment; only constructor args differ):
//   funder (faucet target) -> gas to every sandbox key, 0.10 tUSD8 to the treasury
//   3 sandbox vendors registered in the REAL ERC-8004 registry by their own keys: Acme (confirmed), Hooli (confirmed;
//     its wallet gets hijacked by attack 11), Initech (re-registers a new wallet for attack 12)
//   PayRunV2(owner = sandbox owner EOA, treasury = sandbox treasury); treasury approves 0.10 tUSD8 ONLY: even a total
//     failure of everything can move at most 0.10 test tokens, and only to registered sandbox vendors
//   hold window 3 days; sessions: clerk (run cap 0.10), daycap (run 0.06 / day 0.10), revoked (granted then revoked),
//     expired (granted for 2 minutes); stranger has none
//   one invoice paid at setup (0.01 to Acme) so "re-send a paid invoice" has a real paid invoice to replay
// Keys never printed. Fork mode refuses a non-local RPC; testnet mode refuses anything but chain 44005 at the public RPC.
import { readFileSync, writeFileSync, existsSync, chmodSync } from 'node:fs';
import { createPublicClient, createWalletClient, http, parseAbi, parseEventLogs, keccak256, stringToHex, parseEther, formatEther, bytesToHex, encodeAbiParameters } from 'viem';
import { privateKeyToAccount, generatePrivateKey } from 'viem/accounts';
import { PAYRUN_ABI, REGISTRY_ABI, ERC20_ABI } from './lib/sandbox.mjs';

const REG = '0xF45E7f39Caba1d2055f613970575a7e7069636Be';
const TUSD = '0x456569838f1d43009A91ebA4263147Afd7233483';
const TESTNET_RPC = 'https://rpc-test.qday.info';
const ROLES = ['funder', 'owner', 'treasury', 'clerk', 'revoked', 'expired', 'stranger', 'daycap', 'vendor_acme', 'vendor_hijack', 'vendor_new'];
const GAS = { owner: '0.08', clerk: '0.20', daycap: '0.05', revoked: '0.02', expired: '0.02', stranger: '0.02',
  vendor_hijack: '0.05', vendor_new: '0.05', vendor_acme: '0.005', treasury: '0.005' };          // tQDAY; funder keeps the rest
const CAP_ALLOWANCE = 100_000n;   // 0.10 tUSD8 (6 decimals)
const VENDORS = { acme: ['vendor_acme', 'Acme Supplies Ltd'], hijack: ['vendor_hijack', 'Hooli Freight'], new: ['vendor_new', 'Initech Hosting'] };
const ADMIN_ABI = parseAbi(['function setHoldWindow(uint64)', 'function confirmPayee(uint256,address)', 'function grantSession(address,uint64,uint128,uint128)',
  'function revokeSession(address)', 'function sessions(address) view returns (uint64 expiry, uint64 day, uint128 perRunCap, uint128 perDayCap, uint128 stagedToday, bool revoked)',
  'function holdWindow() view returns (uint64)', 'function treasury() view returns (address)', 'function token() view returns (address)', 'function registry() view returns (address)']);

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const die = (m) => { console.error('FAIL: ' + m); process.exit(1); };

if (args[0] === '--gen-keys') {
  const f = args[1]; if (!f) die('file?'); if (existsSync(f)) die(`${f} exists: not overwriting keys`);
  const keys = Object.fromEntries(ROLES.map((r) => [r, generatePrivateKey()]));
  writeFileSync(f, JSON.stringify({ note: 'Aevum TESTNET-ONLY sandbox keys (chain 44005). Never reuse anywhere else.', keys }, null, 1), { mode: 0o600 });
  chmodSync(f, 0o600);
  for (const r of ROLES) console.log(r.padEnd(14), privateKeyToAccount(keys[r]).address);
  process.exit(0);
}

const FORK = args.includes('--fork'), TESTNET = args.includes('--testnet');
if (FORK === TESTNET) die('pass exactly one of --fork / --testnet');
const rpc = opt('--rpc', TESTNET ? TESTNET_RPC : 'http://127.0.0.1:18546');
if (FORK && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(rpc)) die('fork mode needs a local anvil RPC');
if (TESTNET && rpc !== TESTNET_RPC) die('testnet mode only talks to ' + TESTNET_RPC);
const keysFile = opt('--keys'), stateFile = opt('--state');
if (!keysFile || !stateFile) die('--keys and --state are required');
const K = JSON.parse(readFileSync(keysFile, 'utf8')).keys;
for (const r of ROLES) if (!K[r]) die(`key '${r}' missing`);
const A = Object.fromEntries(ROLES.map((r) => [r, privateKeyToAccount(K[r])]));
const st = existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, 'utf8')) : {};
const save = () => writeFileSync(stateFile, JSON.stringify(st, null, 1));
const put = (k, v) => { st[k] = typeof v === 'bigint' ? v.toString() : v; save(); };

const chain = { id: 44005, name: 'aevum-testnet', nativeCurrency: { name: 'tQDAY', symbol: 'tQDAY', decimals: 18 }, rpcUrls: { default: { http: [rpc] } } };
const pub = createPublicClient({ chain, transport: http(rpc, { timeout: 30_000, retryCount: 3 }) });
const W = (r) => createWalletClient({ chain, transport: http(rpc, { timeout: 30_000, retryCount: 2 }), account: A[r] });
if ((await pub.getChainId()) !== 44005) die('chain id is not 44005');
if (FORK) { try { await pub.request({ method: 'anvil_nodeInfo', params: [] }); } catch { die('--fork but the RPC is not anvil'); } }

async function tx(role, step, p) {          // success-path send: estimate, legacy, wait, require status 1
  if (st[step]) { console.log(`skip ${step} (${st[step]})`); return null; }
  const hash = await (p.abi ? W(role).writeContract({ ...p, type: 'legacy' }) : W(role).sendTransaction({ ...p, type: 'legacy' }));
  const r = await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
  if (r.status !== 'success') die(`${step} reverted (${hash})`);
  put(step, hash); console.log(`ok   ${step} ${hash}`);
  return r;
}

// ---- 0. funds (fork: anvil cheats on the funder only; testnet: the faucet funded the funder)
if (FORK && !st.fork_funded) {
  await pub.request({ method: 'anvil_setBalance', params: [A.funder.address, '0x1BC16D674EC80000'] });   // 2 tQDAY (fork only)
  let slot = null;
  for (let s = 0; s <= 20 && slot === null; s++) {
    const key = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [A.funder.address, BigInt(s)]));
    await pub.request({ method: 'anvil_setStorageAt', params: [TUSD, key, '0x' + (5_000_000n).toString(16).padStart(64, '0')] });
    if ((await pub.readContract({ address: TUSD, abi: ERC20_ABI, functionName: 'balanceOf', args: [A.funder.address] })) === 5_000_000n) slot = s;
    else await pub.request({ method: 'anvil_setStorageAt', params: [TUSD, key, '0x' + '0'.repeat(64)] });
  }
  if (slot === null) die('tUSD8 balance slot not found on the fork');
  put('fork_funded', `5 tUSD8 via slot ${slot}`);
}

const fb = await pub.getBalance({ address: A.funder.address });
const need = Object.values(GAS).reduce((a, v) => a + parseEther(v), 0n) + parseEther('0.05');
console.log(`funder ${A.funder.address} has ${formatEther(fb)} tQDAY (setup needs ~${formatEther(need)})`);
for (const [role, amt] of Object.entries(GAS)) await tx('funder', `gas_${role}`, { to: A[role].address, value: parseEther(amt) });
await tx('funder', 'tusd_treasury', { address: TUSD, abi: ERC20_ABI, functionName: 'transfer', args: [A.treasury.address, CAP_ALLOWANCE] });

// ---- 1. vendors in the real ERC-8004 registry (registered by their own keys; wallet = the key's address)
for (const [v, [role, name]] of Object.entries(VENDORS)) {
  if (st[`${v}_id`]) continue;
  const doc = { type: 'https://eips.ethereum.org/EIPS/eip-8004#registration-v1', name, description: 'Clerk public sandbox vendor (testnet only)' };
  const uri = 'data:application/json;base64,' + Buffer.from(JSON.stringify(doc)).toString('base64');
  const r = await tx(role, `${v}_register`, { address: REG, abi: REGISTRY_ABI, functionName: 'register', args: [uri] });
  const t = parseEventLogs({ abi: REGISTRY_ABI, logs: r.logs }).find((l) => l.eventName === 'Transfer' && l.args.to === A[role].address);
  put(`${v}_id`, t.args.tokenId); put(`${v}_name`, name);
}

// ---- 2. PayRunV2 (same artifact as the main deployment)
if (!st.payrun) {
  const art = JSON.parse(readFileSync(new URL('../contracts/out/PayRunV2.sol/PayRunV2.json', import.meta.url), 'utf8'));
  const hash = await W('funder').deployContract({ abi: art.abi, bytecode: art.bytecode.object, args: [TUSD, REG, A.owner.address, A.treasury.address], type: 'legacy' });
  const r = await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
  if (r.status !== 'success' || !r.contractAddress) die('deploy failed');
  put('payrun_deploy_tx', hash); put('payrun', r.contractAddress); put('payrun_block', r.blockNumber);
  console.log(`ok   PayRunV2 ${r.contractAddress}`);
}
const P = st.payrun;

// ---- 3. caps and sessions
await tx('treasury', 'approve_cap', { address: TUSD, abi: ERC20_ABI, functionName: 'approve', args: [P, CAP_ALLOWANCE] });
await tx('owner', 'hold_window', { address: P, abi: ADMIN_ABI, functionName: 'setHoldWindow', args: [3n * 86400n] });
for (const v of ['acme', 'hijack']) await tx('owner', `confirm_${v}`, { address: P, abi: ADMIN_ABI, functionName: 'confirmPayee', args: [BigInt(st[`${v}_id`]), A[VENDORS[v][0]].address] });
const now = (await pub.getBlock()).timestamp;
const DAYS40 = now + 40n * 86400n;
await tx('owner', 'grant_clerk', { address: P, abi: ADMIN_ABI, functionName: 'grantSession', args: [A.clerk.address, DAYS40, 100_000n, 2n ** 120n] });
await tx('owner', 'grant_daycap', { address: P, abi: ADMIN_ABI, functionName: 'grantSession', args: [A.daycap.address, DAYS40, 60_000n, 100_000n] });
await tx('owner', 'grant_revoked', { address: P, abi: ADMIN_ABI, functionName: 'grantSession', args: [A.revoked.address, DAYS40, 10_000n, 10_000n] });
await tx('owner', 'revoke_revoked', { address: P, abi: ADMIN_ABI, functionName: 'revokeSession', args: [A.revoked.address] });
await tx('owner', 'grant_expired', { address: P, abi: ADMIN_ABI, functionName: 'grantSession', args: [A.expired.address, now + 120n, 10_000n, 10_000n] });

// ---- 4. one paid invoice (0.01 tUSD8 to Acme) for the "re-send a paid invoice" attack
const paidHash = keccak256(stringToHex(`clerk-sandbox:${P}:SBX-PAID-1`));
put('paid_invoice_hash', paidHash);
if (!st.seed_stage) {
  const r = await tx('clerk', 'seed_stage', { address: P, abi: PAYRUN_ABI, functionName: 'stage',
    args: [[{ payeeAgentId: BigInt(st.acme_id), payee: A.vendor_acme.address, amount: 10_000n, invoiceHash: paidHash, invoiceRef: bytesToHex(new TextEncoder().encode('SBX-PAID-1'), { size: 32 }) }]] });
  put('seed_run', parseEventLogs({ abi: PAYRUN_ABI, logs: r.logs }).find((l) => l.eventName === 'Staged').args.runId);
}
await tx('owner', 'seed_execute', { address: P, abi: PAYRUN_ABI, functionName: 'execute', args: [BigInt(st.seed_run)] });

// ---- 5. read back every invariant the sandbox relies on (fails closed)
const rd = (functionName, a = [], abi = ADMIN_ABI, address = P) => pub.readContract({ address, abi, functionName, args: a });
const checks = [];
const chk = (name, ok, got) => { checks.push({ name, ok, got: String(got) }); if (!ok) console.log(`BAD  ${name}: ${got}`); };
chk('owner is the sandbox owner', (await rd('owner', [], PAYRUN_ABI)) === A.owner.address, await rd('owner', [], PAYRUN_ABI));
chk('treasury is the sandbox treasury', (await rd('treasury')) === A.treasury.address, await rd('treasury'));
chk('token/registry are tUSD8/ERC-8004', (await rd('token')) === TUSD && (await rd('registry')) === REG, 'addresses');
const allowance = await rd('allowance', [A.treasury.address, P], ERC20_ABI, TUSD);
chk('allowance <= 0.10 tUSD8 (0.09 after the seed payment)', allowance <= CAP_ALLOWANCE && allowance === 90_000n, allowance);
const tb = await rd('balanceOf', [A.treasury.address], ERC20_ABI, TUSD);
chk('treasury holds <= 0.10 tUSD8', tb <= CAP_ALLOWANCE, tb);
chk('hold window 3 days', (await rd('holdWindow')) === 259200n, await rd('holdWindow'));
chk('seed invoice paid', (await rd('paidInRun', [paidHash], PAYRUN_ABI)) === BigInt(st.seed_run), await rd('paidInRun', [paidHash], PAYRUN_ABI));
const s = async (r) => rd('sessions', [A[r].address]);
chk('clerk session: run cap 0.10', (await s('clerk'))[2] === 100_000n, (await s('clerk'))[2]);
chk('daycap session: 0.06 / 0.10', (await s('daycap'))[2] === 60_000n && (await s('daycap'))[3] === 100_000n, 'caps');
chk('revoked session revoked', (await s('revoked'))[5] === true, (await s('revoked'))[5]);
chk('stranger has no session', (await s('stranger'))[0] === 0n, (await s('stranger'))[0]);
for (const v of ['acme', 'hijack']) chk(`${v} trusted`, Number((await rd('payeeStatus', [BigInt(st[`${v}_id`])], PAYRUN_ABI))[0]) === 1, 'state');
put('expired_at', (await s('expired'))[0]);
put('checks', checks); put('chain_id', 44005); put('rpc', rpc); put('mode', FORK ? 'fork' : 'testnet');
put('addresses', Object.fromEntries(ROLES.map((r) => [r, A[r].address])));
const bad = checks.filter((c) => !c.ok).length;
console.log(bad ? `SETUP INCOMPLETE: ${bad} check(s) failed` : `SANDBOX READY: PayRunV2 ${P} (${checks.length} checks OK)`);
process.exit(bad ? 1 : 0);
