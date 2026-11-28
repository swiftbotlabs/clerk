#!/usr/bin/env node
// VendorRegistryV2 (48-hour timelock + verifier) and PayeeChecker on Aevum testnet, or a local anvil fork of it.
// A demonstrator NEXT TO the canonical set (PayRunV3 0x1447... + VendorRegistry 0x4289...), which stay unchanged.
//
//   --phase deploy  owner: deploy VendorRegistryV2(owner, verifier, 48 h) + PayeeChecker; register Acme with the same
//                   registration file and wallet as VendorRegistry #1 (pending for 48 h: reads as zero until applied)
//   --phase demo    (>= 48 h later) anyone: apply Acme's wallet; owner: propose a "new bank details" wallet (a burn address);
//                   PayeeChecker must say ChangePending; verifier: cancel; PayeeChecker must say Ok again for Acme's wallet
//   --phase check   read-only: every recorded tx succeeded, the registry state matches the recorded phase, PayeeChecker on the
//                   canonical VendorRegistry + PayRunV3 for Acme
// Keys are read in-process from key files ({keys: {role: 0x..}}, {role: 0x..} or {role: {address, private_key}}); only
// addresses, tx hashes and verdicts are printed. Idempotent: each step's result is written to --state before the next.
//   node deploy_registry_v2.mjs --phase deploy --keys ~/agent/secrets/aevum_testnet_keys.json --role owner \
//        --vkeys ~/agent/secrets/aevum_eval_keys_v3.json --vrole treasury --state ../e2e/testnet_regv2.json [--rpc http://127.0.0.1:PORT]
import { readFileSync, writeFileSync, lstatSync, existsSync, renameSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createPublicClient, createWalletClient, http, getAddress, formatEther } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const HERE = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const die = (m) => { console.error('FAIL: ' + m); process.exit(1); };
const TESTNET = 'https://rpc-test.qday.info';
const CANON_REG = '0x428981983c3aa672c27ea5a469e2d0e37dc646a1';
const CANON_PAYRUN = '0x1447B820a51bb83FC58fB13BF3b8c791361C682b';
const REDIRECT = '0x000000000000000000000000000000000000dEaD';   // the "new bank details" wallet: a burn address nobody holds
const DELAY = 48n * 3600n;
const VERDICT = ['Ok', 'Unregistered', 'Mismatch', 'ChangePending', 'Held'];

const rpc = opt('--rpc', TESTNET);
if (!(rpc === TESTNET || /^http:\/\/127\.0\.0\.1:\d{2,5}$/.test(rpc))) die('--rpc must be the Aevum testnet RPC or a local fork');
const phase = opt('--phase', '');
if (!['deploy', 'demo', 'check'].includes(phase)) die('--phase deploy|demo|check');
const statePath = String(opt('--state', '')).replace(/^~(?=\/)/, homedir());
if (!statePath || !/\.json$/.test(statePath)) die('--state <file.json> is required');
if (existsSync(statePath) && lstatSync(statePath).isSymbolicLink()) die('--state is a symlink');
const st = existsSync(statePath) ? JSON.parse(readFileSync(statePath, 'utf8')) : {};
const save = () => { writeFileSync(statePath + '.tmp', JSON.stringify(st, null, 1) + '\n'); renameSync(statePath + '.tmp', statePath); };

function loadKey(fileOpt, roleOpt) {
  const file = String(opt(fileOpt, '')).replace(/^~(?=\/)/, homedir()), role = opt(roleOpt, '');
  if (!file || !/^[a-z0-9_]{1,32}$/.test(role)) die(`${fileOpt} and ${roleOpt} are required`);
  const s = lstatSync(file);
  if (s.isSymbolicLink() || !s.isFile() || s.size > 65_536 || (s.mode & 0o004)) die(`${fileOpt}: not a regular, private, small file`);
  const raw = JSON.parse(readFileSync(file, 'utf8'));
  const ent = (raw.keys || raw)[role];
  const k = typeof ent === 'string' ? ent : (ent && (ent.private_key || ent.privateKey || ent.key)) || '';
  if (!/^0x[0-9a-fA-F]{64}$/.test(k)) die(`role ${role} not in ${fileOpt}`);
  return privateKeyToAccount(k);
}

function artifact(file, name) {
  const p = join(HERE, '..', 'contracts', 'out', file, name + '.json');
  if (!existsSync(p)) die(`missing ${p}: run forge build in contracts/`);
  const a = JSON.parse(readFileSync(p, 'utf8'));
  return { abi: a.abi, bytecode: a.bytecode.object };
}
const REG = artifact('VendorRegistryV2.sol', 'VendorRegistryV2');
const CHK = artifact('PayeeCheck.sol', 'PayeeChecker');
const V1_ABI = [
  { type: 'function', name: 'getAgentWallet', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'tokenURI', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ type: 'string' }] },
];

const chain = { id: 44005, name: 'aevum', nativeCurrency: { name: 'tQDAY', symbol: 'tQDAY', decimals: 18 }, rpcUrls: { default: { http: [rpc] } } };
const pub = createPublicClient({ chain, transport: http(rpc, { timeout: 30_000, retryCount: 1 }) });
if ((await pub.getChainId()) !== 44005) die('chain id is not 44005');
const gp = await pub.getGasPrice();
if (gp > 5_000_000_000n) die('gas price above 5 gwei');

async function send(acct, label, req) {
  const w = createWalletClient({ chain, transport: http(rpc, { timeout: 30_000, retryCount: 0 }), account: acct });
  const hash = req.deploy ? await w.deployContract({ ...req.deploy, gasPrice: gp, type: 'legacy' })
    : await w.writeContract({ ...req, gasPrice: gp, type: 'legacy' });
  st[label + '_tx'] = hash; save();                         // recorded before the wait: a killed run can read it back
  const rc = await pub.waitForTransactionReceipt({ hash, timeout: 240_000 });
  if (rc.status !== 'success') die(`${label}: tx ${hash} ${rc.status}`);
  console.log(`${label}: ${hash} (block ${rc.blockNumber})`);
  return rc;
}
const reg = () => ({ address: st.registry_v2, abi: REG.abi });
const read = (fn, a = []) => pub.readContract({ ...reg(), functionName: fn, args: a });
async function verdict(registry, hold, agentId, payee) {
  const r = await pub.readContract({ address: st.payee_checker, abi: CHK.abi, functionName: 'check', args: [registry, hold, agentId, payee] });
  return { verdict: VERDICT[Number(r.verdict)], registered: r.registered, pendingWallet: r.pendingWallet, pendingEta: Number(r.pendingEta) };
}
const now = async () => (await pub.getBlock()).timestamp;

if (phase === 'deploy') {
  const owner = loadKey('--keys', '--role'), verifier = loadKey('--vkeys', '--vrole');
  if (owner.address === verifier.address) die('owner and verifier must be different keys');
  const acmeWallet = await pub.readContract({ address: CANON_REG, abi: V1_ABI, functionName: 'getAgentWallet', args: [1n] });
  const acmeURI = await pub.readContract({ address: CANON_REG, abi: V1_ABI, functionName: 'tokenURI', args: [1n] });
  if (/^0x0{40}$/i.test(acmeWallet) || acmeURI.length < 20) die('Acme #1 not found in the canonical VendorRegistry');
  const bal = await pub.getBalance({ address: owner.address });
  console.log(`owner ${owner.address} ${formatEther(bal)} tQDAY; verifier ${verifier.address}; Acme ${acmeWallet}`);
  if (bal < 3_000_000n * gp) die('owner has too little gas for 3 transactions');
  Object.assign(st, { owner: owner.address, verifier: verifier.address, acme_wallet: acmeWallet, delay_s: Number(DELAY) }); save();
  if (!st.registry_v2) {
    const rc = await send(owner, 'registry_v2_deploy', { deploy: { abi: REG.abi, bytecode: REG.bytecode, args: [owner.address, verifier.address, DELAY] } });
    st.registry_v2 = getAddress(rc.contractAddress); save();
  }
  if (!st.payee_checker) {
    const rc = await send(owner, 'payee_checker_deploy', { deploy: { abi: CHK.abi, bytecode: CHK.bytecode, args: [] } });
    st.payee_checker = getAddress(rc.contractAddress); save();
  }
  if ((await read('owner')) !== owner.address || (await read('verifier')) !== verifier.address || (await read('delay')) !== DELAY)
    die('registry roles or delay do not match');
  if (!st.acme_register_tx && (await read('count')) === 0n) {
    await send(owner, 'acme_register', { ...reg(), functionName: 'register', args: [acmeURI, acmeWallet] });
  }
  const [pw, eta] = await read('pendingWallet', [1n]);
  st.acme_eta = Number(eta); save();
  if (pw !== acmeWallet || (await read('getAgentWallet', [1n])) !== '0x0000000000000000000000000000000000000000') die('Acme is not pending');
  console.log(`REGV2 DEPLOY OK: registry ${st.registry_v2}, checker ${st.payee_checker}; Acme #1 pending until ${new Date(Number(eta) * 1000).toISOString()} (reads as zero until then)`);
}

if (phase === 'demo') {
  if (!st.registry_v2 || !st.payee_checker) die('run --phase deploy first');
  const owner = loadKey('--keys', '--role'), verifier = loadKey('--vkeys', '--vrole');
  if (owner.address !== st.owner || verifier.address !== st.verifier) die('keys do not match the recorded owner/verifier');
  const t = await now();
  if (!st.acme_apply_tx) {
    if (t < BigInt(st.acme_eta)) die(`Acme's wallet applies at ${new Date(st.acme_eta * 1000).toISOString()} (chain time ${new Date(Number(t) * 1000).toISOString()})`);
    await send(owner, 'acme_apply', { ...reg(), functionName: 'applyAgentWallet', args: [1n] });
  }
  if ((await read('getAgentWallet', [1n])) !== st.acme_wallet) die('Acme wallet not active after apply');
  let v = await verdict(st.registry_v2, '0x0000000000000000000000000000000000000000', 1n, st.acme_wallet);
  console.log(`PayeeChecker Acme after apply: ${v.verdict}`); if (v.verdict !== 'Ok') die('expected Ok');
  if (!st.redirect_propose_tx) await send(owner, 'redirect_propose', { ...reg(), functionName: 'proposeAgentWallet', args: [1n, REDIRECT] });
  if (!st.redirect_cancel_tx) {
    if ((await read('getAgentWallet', [1n])) !== st.acme_wallet) die('the registry must still answer Acme during the window');
    v = await verdict(st.registry_v2, '0x0000000000000000000000000000000000000000', 1n, st.acme_wallet);
    console.log(`PayeeChecker Acme with the redirect pending: ${v.verdict} (pending ${v.pendingWallet})`);
    if (v.verdict !== 'ChangePending' || v.pendingWallet !== getAddress(REDIRECT)) die('expected ChangePending to the redirect wallet');
    const r = await verdict(st.registry_v2, '0x0000000000000000000000000000000000000000', 1n, REDIRECT);
    console.log(`PayeeChecker redirect wallet: ${r.verdict}`); if (r.verdict !== 'Mismatch') die('expected Mismatch');
    st.pending_verdict = v.verdict; save();
    await send(verifier, 'redirect_cancel', { ...reg(), functionName: 'cancelAgentWallet', args: [1n] });
  }
  v = await verdict(st.registry_v2, '0x0000000000000000000000000000000000000000', 1n, st.acme_wallet);
  if (v.verdict !== 'Ok' || (await read('pendingWallet', [1n]))[1] !== 0n) die('expected Ok and nothing pending after the cancel');
  console.log('REGV2 DEMO OK: applied after 48 h, redirect proposed (ChangePending, Mismatch for the new wallet), cancelled by the verifier, Acme Ok');
}

if (phase === 'check') {
  if (!st.registry_v2) die('nothing deployed in this state file');
  let n = 0;
  for (const k of Object.keys(st).filter((k) => k.endsWith('_tx'))) {
    const rc = await pub.getTransactionReceipt({ hash: st[k] });
    if (rc.status !== 'success') die(`${k} ${st[k]} ${rc.status}`);
    n++;
  }
  if (n === 0) die('0 transactions checked');
  if ((await read('delay')) !== DELAY || (await read('verifier')) !== st.verifier) die('registry config changed');
  const w = await read('getAgentWallet', [1n]); const [pw, eta] = await read('pendingWallet', [1n]);
  console.log(`registry ${st.registry_v2}: Acme wallet ${w}, pending ${pw} eta ${eta}`);
  if (st.redirect_cancel_tx ? (w !== st.acme_wallet || eta !== 0n) : (w !== '0x0000000000000000000000000000000000000000' || pw !== st.acme_wallet)) die('registry state does not match the recorded phase');
  const c = await verdict(CANON_REG, CANON_PAYRUN, 1n, st.acme_wallet);
  console.log(`PayeeChecker on the canonical VendorRegistry + PayRunV3 for Acme: ${c.verdict}`);
  const bad = await verdict(CANON_REG, CANON_PAYRUN, 1n, REDIRECT);
  if (bad.verdict !== 'Mismatch') die('canonical: a wrong wallet must be Mismatch');
  console.log(`REGV2 CHECK OK: ${n} transactions succeeded; state matches; canonical wrong-wallet check = Mismatch`);
}
process.exit(0);
