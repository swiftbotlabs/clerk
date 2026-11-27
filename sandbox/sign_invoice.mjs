#!/usr/bin/env node
// The VENDOR's side of a PayRunV3 invoice: sign one invoice document with the vendor's registered wallet (EIP-712, domain
// "Clerk PayRun" / "3" / chain / that PayRunV3) and write <invoice>.sig.json next to it, which agent/stage.py --signed reads.
// The signed values are exactly the line the clerk's pipeline extracts from the same document (agent/stage.py extract_rules,
// to_units, invoice_key, due_yyyymmdd), so a genuine invoice verifies and an edited one does not.
//
//   node sandbox/sign_invoice.mjs --keys K --role vendor1 --payrun 0x... --agent 1 --invoice path/INV.txt [--rpc URL]
//
// Fails closed: the key's address must be the vendor's registered wallet in the PayRun's registry right now, and the
// contract's own checkInvoice (read-only eth_call) must say the signature is valid before the sidecar is written.
// The key is read in-process and never printed; only the signer's public address is.
import { readFileSync, writeFileSync, lstatSync, realpathSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createPublicClient, http, parseAbi } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { INVOICE_TYPES, invoiceDomain } from './lib/sandbox.mjs';

const args = process.argv.slice(2);
const opt = (k) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : undefined; };
const die = (m) => { console.error('FAIL: ' + m); process.exit(1); };
const keysFile = opt('--keys'), role = opt('--role'), payrun = opt('--payrun'), agent = opt('--agent'), invoice = opt('--invoice');
const rpc = opt('--rpc') || 'https://rpc-test.qday.info';
if (!keysFile || !role || !payrun || !agent || !invoice) die('usage: --keys K --role R --payrun 0x.. --agent N --invoice FILE [--rpc URL]');
if (!/^0x[0-9a-fA-F]{40}$/.test(payrun) || !/^\d{1,9}$/.test(agent) || !/^[a-z0-9_]{1,32}$/.test(role)) die('bad --payrun / --agent / --role');
if (!/^(https:\/\/rpc-test\.qday\.info|http:\/\/127\.0\.0\.1:\d{2,5})$/.test(rpc)) die('rpc must be the public testnet RPC or a local fork');
for (const f of [keysFile, invoice]) if (lstatSync(f).isSymbolicLink()) die(`${f} is a symlink`);
if (lstatSync(invoice).size > 65_536) die('invoice larger than 64 KB');
const raw = JSON.parse(readFileSync(realpathSync(keysFile), 'utf8'));
const pk = raw.keys?.[role] ?? raw[role]?.private_key;
if (!/^0x[0-9a-fA-F]{64}$/.test(pk || '')) die(`key '${role}' missing or malformed`);
const signer = privateKeyToAccount(pk);

// the line, extracted by the clerk's own code from the same document
const py = `import json,sys; sys.path.insert(0, sys.argv[1]); import stage
t = open(sys.argv[2], encoding='utf-8').read(); d = stage.extract_rules(t); a = int(sys.argv[3])
print(json.dumps({"amount": stage.to_units(d["amount"]), "invoiceHash": stage.invoice_key(a, d["reference"]), "dueDate": stage.due_yyyymmdd(d.get("due_date")), "reference": d["reference"]}))`;
const app = new URL('..', import.meta.url).pathname;
const L = JSON.parse(execFileSync('python3', ['-I', '-c', py, app + 'agent', invoice, agent], { encoding: 'utf8' }));
if (!L.dueDate) die('no due date in the invoice');

const pub = createPublicClient({ transport: http(rpc, { timeout: 20_000, retryCount: 2 }) });
const ABI = parseAbi(['function registry() view returns (address)', 'function getAgentWallet(uint256) view returns (address)',
  'struct Line { uint256 payeeAgentId; address payee; uint128 amount; bytes32 invoiceHash; bytes32 invoiceRef; }',
  'struct Proof { uint32 dueDate; bytes signature; }',
  'function checkInvoice(Line l, Proof p) view returns (bool required, bool valid)']);
const chainId = await pub.getChainId();
const registry = await pub.readContract({ address: payrun, abi: ABI, functionName: 'registry' });
const wallet = await pub.readContract({ address: registry, abi: ABI, functionName: 'getAgentWallet', args: [BigInt(agent)] });
if (wallet.toLowerCase() !== signer.address.toLowerCase()) die(`key '${role}' (${signer.address}) is not vendor #${agent}'s registered wallet (${wallet})`);
const line = { payeeAgentId: BigInt(agent), payee: wallet, amount: BigInt(L.amount), invoiceHash: L.invoiceHash, invoiceRef: '0x' + '00'.repeat(32) };
const signature = await signer.signTypedData({ domain: invoiceDomain(chainId, payrun), types: INVOICE_TYPES, primaryType: 'Invoice',
  message: { payeeAgentId: line.payeeAgentId, payee: line.payee, amount: line.amount, invoiceHash: line.invoiceHash, dueDate: L.dueDate } });
const [required, valid] = await pub.readContract({ address: payrun, abi: ABI, functionName: 'checkInvoice', args: [line, { dueDate: L.dueDate, signature }] });
if (!valid) die('the contract says this signature is not valid for the line (checkInvoice)');
try { if (lstatSync(invoice + '.sig.json').isSymbolicLink()) die('the .sig.json path is a symlink'); } catch (e) { if (e.code !== 'ENOENT') throw e; }
writeFileSync(invoice + '.sig.json', JSON.stringify({ signature, signer: signer.address, agentId: agent, amount: String(L.amount), reference: L.reference,
  dueDate: L.dueDate, payrun, chainId }, null, 1) + '\n');
console.log(`signed ${invoice} as vendor #${agent} (${signer.address}): ${L.reference} ${Number(L.amount) / 1e6} tUSD8 due ${L.dueDate}; checkInvoice valid=${valid} required=${required}`);
