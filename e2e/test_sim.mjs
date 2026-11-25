#!/usr/bin/env node
// B1: the probe code the page puts at the owner's address (web/sim.js PROBE_CODE) must be exactly the compiled runtime code of
// contracts/src/sim/DemoProbe.sol (forge artifact contracts/out/DemoProbe.sol/DemoProbe.json, deployedBytecode), and its ABI
// for simulate() must match what sim.js decodes. Also checks docs/sim.js (the built copy) when it exists.
// Run after `forge build` (the gate does: (cd contracts && forge build) && node e2e/test_sim.mjs). Exit 0 = OK, 1 = mismatch.
import { readFileSync, existsSync } from 'node:fs';
const ROOT = new URL('..', import.meta.url).pathname;
const fail = (m) => { console.log('SIM FAIL: ' + m); process.exit(1); };
const ART = ROOT + 'contracts/out/DemoProbe.sol/DemoProbe.json';
if (!existsSync(ART)) fail('no forge artifact (run forge build in contracts/)');
const art = JSON.parse(readFileSync(ART, 'utf8'));
const want = String(art.deployedBytecode?.object || '').toLowerCase();
if (!/^0x[0-9a-f]{200,}$/.test(want)) fail('artifact has no deployedBytecode');
const probe = (file) => {
  const m = [...readFileSync(file, 'utf8').matchAll(/export const PROBE_CODE = '(0x[0-9a-fA-F]+)';/g)];
  if (m.length !== 1) fail(`${file}: expected exactly one PROBE_CODE literal, found ${m.length}`);
  return m[0][1].toLowerCase();
};
let checked = 0;
for (const f of ['web/sim.js', 'docs/sim.js']) {
  if (f === 'docs/sim.js' && !existsSync(ROOT + f)) continue;
  const got = probe(ROOT + f);
  if (got !== want) fail(`${f}: PROBE_CODE (${got.length} chars, ...${got.slice(-16)}) != DemoProbe deployedBytecode (${want.length} chars, ...${want.slice(-16)})`);
  checked++;
}
const sim = art.abi.find((x) => x.type === 'function' && x.name === 'simulate');
const outs = (sim?.outputs || []).map((o) => o.type).join(',');
if (outs !== 'uint256,uint256,tuple[]') fail('simulate() outputs are ' + outs + ', sim.js decodes uint256,uint256,tuple[]');
const src = readFileSync(ROOT + 'web/sim.js', 'utf8');
if (!src.includes('returns (uint256 payeeBefore, uint256 treasuryBefore, Step[] steps)')) fail('web/sim.js SIM_ABI simulate() signature differs from the artifact');
if (checked === 0) fail('0 files checked');
console.log(`SIM CODE OK: ${checked} file(s), PROBE_CODE == DemoProbe deployedBytecode (${(want.length - 2) / 2} bytes)`);
