#!/usr/bin/env node
// Send test tQDAY from one of OUR testnet keys to another of our testnet addresses (e.g. the eval/sandbox funder before an eval run).
// Testnet (chain 44005, the public RPC) or a local anvil fork only; at most 0.5 tQDAY per call; the sender keeps >= --keep.
// The key is read in-process from a key file ({keys: {role: 0x..}} or {role: 0x..}); only addresses, amounts and the tx hash are printed.
//   node topup.mjs --keys ~/agent/secrets/aevum_testnet_keys.json --role owner --to 0x310aaBFbb6d29DC3ac864448E72c8cD63e3a25Bf --amount 0.30 --keep 0.20 [--rpc http://127.0.0.1:PORT] [--dry-run]
import { readFileSync, lstatSync } from 'node:fs';
import { homedir } from 'node:os';
import { createPublicClient, createWalletClient, http, parseEther, formatEther, getAddress } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const die = (m) => { console.error('FAIL: ' + m); process.exit(1); };
const TESTNET = 'https://rpc-test.qday.info';
const rpc = opt('--rpc', TESTNET);
if (!(rpc === TESTNET || /^http:\/\/127\.0\.0\.1:\d{2,5}$/.test(rpc))) die('--rpc must be the Aevum testnet RPC or a local fork');
const keysFile = String(opt('--keys', '')).replace(/^~(?=\/)/, homedir()), role = opt('--role', '');
if (!keysFile || !/^[a-z0-9_]{1,32}$/.test(role)) die('--keys and --role are required');
const stt = lstatSync(keysFile);
if (stt.isSymbolicLink() || !stt.isFile() || stt.size > 65_536 || (stt.mode & 0o004)) die('key file: not a regular, private, small file');
let to; try { to = getAddress(opt('--to', '')); } catch { die('--to is not an address'); }
if (!/^\d{1,2}(\.\d{1,6})?$/.test(opt('--amount', '')) || !/^\d{1,2}(\.\d{1,6})?$/.test(opt('--keep', '0.20'))) die('--amount/--keep: tQDAY decimals');
const amount = parseEther(opt('--amount')), keep = parseEther(opt('--keep', '0.20'));
if (amount <= 0n || amount > parseEther('0.5')) die('--amount must be in (0, 0.5] tQDAY');
const raw = JSON.parse(readFileSync(keysFile, 'utf8'));
const ent = (raw.keys || raw)[role];
const k = typeof ent === 'string' ? ent : (ent && (ent.private_key || ent.privateKey || ent.key)) || '';
if (!/^0x[0-9a-fA-F]{64}$/.test(k || '')) die(`role ${role} not in the key file`);
const acct = privateKeyToAccount(k);
const chain = { id: 44005, name: 'aevum', nativeCurrency: { name: 'tQDAY', symbol: 'tQDAY', decimals: 18 }, rpcUrls: { default: { http: [rpc] } } };
const pub = createPublicClient({ chain, transport: http(rpc, { timeout: 20_000, retryCount: 1 }) });
if ((await pub.getChainId()) !== 44005) die('chain id is not 44005');
if (acct.address.toLowerCase() === to.toLowerCase()) die('sender and receiver are the same');
const gp = await pub.getGasPrice();
if (gp > 5_000_000_000n) die('gas price above 5 gwei');
const [b0, t0] = await Promise.all([pub.getBalance({ address: acct.address }), pub.getBalance({ address: to })]);
console.log(`from ${acct.address} (${role}): ${formatEther(b0)} tQDAY; to ${to}: ${formatEther(t0)} tQDAY; amount ${formatEther(amount)}; sender keeps >= ${formatEther(keep)}`);
if (b0 < amount + keep + 21_000n * gp) die('the sender would drop below --keep: not sending');
if (args.includes('--dry-run')) { console.log('DRY RUN: nothing sent'); process.exit(0); }
const hash = await createWalletClient({ chain, transport: http(rpc, { timeout: 20_000, retryCount: 0 }), account: acct })
  .sendTransaction({ to, value: amount, gas: 21_000n, gasPrice: gp, type: 'legacy' });
console.log(`sent: ${hash}`);
const rc = await pub.waitForTransactionReceipt({ hash, timeout: 180_000 });
const t1 = await pub.getBalance({ address: to });
if (rc.status !== 'success' || t1 - t0 !== amount) die(`receipt ${rc.status}, receiver ${formatEther(t0)} -> ${formatEther(t1)}`);
console.log(`TOPUP OK: ${to} ${formatEther(t0)} -> ${formatEther(t1)} tQDAY (tx ${hash})`);
process.exit(0);
