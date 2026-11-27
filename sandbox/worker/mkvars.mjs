#!/usr/bin/env node
// Build the Worker's runtime config from a deploy.mjs state file + its keys file. Keys are read in-process and never printed.
//
//   node worker/mkvars.mjs --mode fork --state work/fork-state.json --keys work/fork-keys.json --out work/dev.vars
//       -> a dotenv file (mode 600) for `wrangler dev --env-file work/dev.vars` (keys + config + Turnstile TEST secret)
//   node worker/mkvars.mjs --mode testnet --state sandbox-testnet.json --keys ~/agent/secrets/aevum_sandbox_keys.json --put-secrets
//       -> pipes SANDBOX_KEYS and SANDBOX_CONFIG into `wrangler secret put` (stdin, never argv). LOCAL AGENT ONLY, after review.
//
// Only the 8 keys the attacks need go to the Worker. NOT included: funder, treasury, vendor_acme (the Worker cannot move the
// treasury's tUSD8 itself; the most any leak can do is what the sandbox owner key can do on a 0.09 tUSD8 allowance).
// The state file's `version` picks the roles: v3 (PayRunV3 + our VendorRegistry) sends registrar + vendor_acme instead of
// vendor_hijack + vendor_new. vendor_acme only SIGNS Acme's invoices (Acme is signedOnly); its wallet holds the 0.01 seed payment.
// The registrar can re-point any sandbox vendor's wallet; a re-pointed wallet is still held 3 days by PayRunV3, and the owner key
// that could release it early is in the Worker either way (V2 had the same exposure through vendor_hijack): worst case is still
// the 0.09 tUSD8 test-token allowance.
import { readFileSync, writeFileSync, chmodSync, realpathSync, lstatSync, renameSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { privateKeyToAccount } from 'viem/accounts';
import { ROLES_FOR } from '../lib/sandbox.mjs';

const args = process.argv.slice(2);
const opt = (k) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : undefined; };
const die = (m) => { console.error('FAIL: ' + m); process.exit(1); };
const mode = opt('--mode');
if (!['fork', 'testnet'].includes(mode)) die('--mode fork|testnet');
const stateFile = opt('--state'), keysFile = opt('--keys');
if (!stateFile || !keysFile) die('--state and --keys are required');
if (lstatSync(keysFile).isSymbolicLink()) die('keys file is a symlink');
const st = JSON.parse(readFileSync(stateFile, 'utf8'));
const all = JSON.parse(readFileSync(realpathSync(keysFile), 'utf8')).keys;
const version = st.version || 'v2';
if (!Object.hasOwn(ROLES_FOR, version)) die('state file has an unknown version');
const ROLES = ROLES_FOR[version];
const keys = {};
for (const r of ROLES) { if (!/^0x[0-9a-fA-F]{64}$/.test(all[r] || '')) die(`key ${r} missing or malformed`); keys[r] = all[r]; }
if (st.mode !== mode) die(`state file is mode '${st.mode}', not '${mode}'`);
const bad = (st.checks || []).filter((c) => !c.ok).length;
if (!st.checks?.length || bad) die('state file has no passing read-back checks (run deploy.mjs first)');
for (const r of ROLES) if (privateKeyToAccount(keys[r]).address !== st.addresses[r]) die(`key ${r} does not match the deployed address`);

const config = {
  version,
  network: mode === 'fork' ? 'Local fork of Aevum testnet' : 'Aevum testnet',
  rpc: mode === 'fork' ? st.rpc : 'https://rpc-test.qday.info',
  chainId: 44005,
  explorer: mode === 'fork' ? '' : 'https://explorer-test.qday.info',
  payrun: st.payrun, registry: version === 'v3' ? st.registry : '0xF45E7f39Caba1d2055f613970575a7e7069636Be', token: '0x456569838f1d43009A91ebA4263147Afd7233483',
  treasury: st.addresses.treasury, treasuryStart: '90000',            // 0.09 tUSD8 after the seed payment (deploy.mjs check)
  // acme.wallet: Acme's registered (public) wallet, so GET /extract fills its genuine sample without a chain read. Not a key.
  vendors: { acme: { id: st.acme_id, name: st.acme_name, wallet: st.addresses.vendor_acme }, hijack: { id: st.hijack_id, name: st.hijack_name }, new: { id: st.new_id, name: st.new_name } },
  paidInvoiceHash: st.paid_invoice_hash,
  addresses: Object.fromEntries(ROLES.map((r) => [r, st.addresses[r]])),
  maxGasPriceWei: '5000000000', minBalanceWei: '5000000000000000',          // 5 gwei cap; 0.005 tQDAY floor per key (~40 failed stages)
  seed: { deployTx: st.payrun_deploy_tx, paidTx: st.seed_execute, ...(version === 'v3' ? { registryDeployTx: st.registry_deploy_tx } : {}) },
  // v3: the PayRunV2 sandbox's public log stays readable at /history/v2 (its Durable Object instance is kept as it was)
  ...(version === 'v3' ? { history: { v2: { payrun: '0x8034c01ba98d882abd30118235d648183d3fae52' } } } : {}),
};

if (mode === 'fork') {
  const out = opt('--out'); if (!out) die('--out file?');
  const q = (v) => `'${v}'`;     // values are JSON without single quotes
  const lines = [
    `SANDBOX_KEYS=${q(JSON.stringify(keys))}`,
    `SANDBOX_CONFIG=${q(JSON.stringify(config))}`,
    'TURNSTILE_SECRET=1x0000000000000000000000000000000AA',            // Cloudflare's documented always-pass TEST secret
  ];
  // F7: never follow a symlink at --out; write a fresh 0600 file (O_EXCL) and rename it into place
  try { if (lstatSync(out).isSymbolicLink()) die('--out is a symlink'); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  const tmp = `${out}.tmp-${process.pid}-${Date.now()}`;
  writeFileSync(tmp, lines.join('\n') + '\n', { mode: 0o600, flag: 'wx' });
  chmodSync(tmp, 0o600);
  renameSync(tmp, out);
  console.log(`wrote ${out} (mode 600): ${ROLES.length} keys, config for ${version === 'v3' ? 'PayRunV3' : 'PayRunV2'} ${config.payrun}`);
} else {
  if (!args.includes('--put-secrets')) { console.log(JSON.stringify({ ...config }, null, 1)); process.exit(0); }
  for (const [name, val] of [['SANDBOX_KEYS', JSON.stringify(keys)], ['SANDBOX_CONFIG', JSON.stringify(config)]]) {
    const r = spawnSync('npx', ['wrangler', 'secret', 'put', name, '--config', new URL('./wrangler.toml', import.meta.url).pathname],
      { input: val, stdio: ['pipe', 'ignore', 'pipe'], encoding: 'utf8' });
    console.log(`${name}: wrangler exit ${r.status}`);
    if (r.status !== 0) die(`secret put ${name} failed`);
  }
}
