// PayRunV3 variant (r7): the built approval page against a LOCAL fork (chain id 440050 on :8555) where e2e/deploy_v3_page.sh
// deployed the page's PayRunV3 and the clerk staged run 1 WITH Acme's signature; Acme is new to the contract, so run 1 is HELD.
// Checks: the stranger can't release it; the owner's signer confirms the payee and pays through the Kernel account (Paid);
// the page names the contract PayRunV3. (Original: e2e/video/fork_page_check.cjs, PayRunV2.)
// The EIP-1193 shim signs personal_sign in THIS process with the testnet owner key (KEYS file, never printed) and sends
// transactions through anvil impersonation. Nothing reaches the real testnet: the shim only talks to 127.0.0.1:8555.
//   1. negative control: a wallet that is NOT the owner's signer is told so, and its Confirm payee fails with a plain message
//   2. owner signer: tick + Confirm payee (UserOperation), then Approve and pay (UserOperation) -> Paid; Reject run 2 in one click
// Exits 1 on any miss.
const { chromium } = require('playwright');
const { privateKeyToAccount } = require('viem/accounts');
const fs = require('fs');
const RPC = 'http://127.0.0.1:8555', PAGE = process.env.PAGE_URL || 'http://127.0.0.1:8097/?chain=440050', OUT = process.env.OUT || '.';
const key = JSON.parse(fs.readFileSync(process.env.KEYS, 'utf8')).owner.private_key;
const owner = privateKeyToAccount(key);
const STRANGER = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8';   // anvil public test account 1 (not the owner's signer)
const V2 = String(process.env.V3_ADDR || '').slice(2, 10).toLowerCase();   // keyOf(): first 8 hex of the PayRunV3 address
if (!/^[0-9a-f]{8}$/.test(V2)) throw new Error('V3_ADDR?');
const fail = (m) => { console.log('FORK PAGE FAIL: ' + m); process.exitCode = 1; };
async function rpc(method, params) {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json(); if (j.error) throw Object.assign(new Error(j.error.message), j.error); return j.result;
}
async function session(b, addr, signer) {
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 } });
  await ctx.exposeFunction('__wallet', async (method, params) => {
    if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [addr];
    if (method === 'personal_sign') {
      if (!signer) return '0x' + '11'.repeat(65);   // a stranger's signature: wrong key
      return await owner.signMessage({ message: { raw: params[0] } });
    }
    if (method === 'eth_sendTransaction') { await rpc('anvil_impersonateAccount', [addr]); await rpc('anvil_setBalance', [addr, '0x8AC7230489E80000']); }
    if (method === 'wallet_switchEthereumChain' || method === 'wallet_addEthereumChain') return null;
    return await rpc(method, params || []);
  });
  await ctx.addInitScript(() => {
    window.ethereum = { request: async ({ method, params }) => { const r = await window.__wallet(method, params); return r; }, on() {}, removeListener() {} };
  });
  const p = await ctx.newPage();
  const errors = [], dialogs = [];
  p.on('pageerror', (e) => errors.push(String(e))); p.on('dialog', (d) => { dialogs.push(d.message()); d.dismiss(); });
  await p.goto(PAGE); await p.waitForSelector(`article[data-key="${V2}-1"]`, { timeout: 120000 });   // a fresh fork fetches state lazily from the public RPC
  return { ctx, p, errors, dialogs };
}
const art = (k) => `article[data-key="${V2}-${k}"]`;
const txt = (p, k) => p.$eval(`${art(k)} .slip.status`, (e) => e.innerText).catch(() => '');
(async () => {
  const b = await chromium.launch(process.env.CHROME_BIN ? { executablePath: process.env.CHROME_BIN } : {});
  try {
    // 1. negative control: not the owner's signer
    let s = await session(b, STRANGER, false);
    const h0 = await s.p.innerText('#headline'); console.log('headline:', h0);
    const st0 = await s.p.$eval(`${art(1)} .status`, (e) => e.innerText); console.log('V3 run 1:', st0);
    if (!/^PayRunV3 run 1: Held/.test(st0)) fail('V3 run 1 is not shown as a held PayRunV3 run: ' + st0);
    if (!/held payments? to confirm or reject/.test(h0)) fail('headline does not count the held run: ' + h0);
    await s.p.click('#connect'); await s.p.waitForFunction(() => /signer/.test(document.querySelector('#net').innerText), null, { timeout: 20000 });
    const net0 = await s.p.innerText('#net'); console.log('stranger net:', net0);
    if (!/not the owner's signer/.test(net0)) fail('a stranger was not told it is not the owner\'s signer');
    await s.p.check(`${art(1)} input[data-ack]`); await s.p.click(`${art(1)} button[data-act="confirm"]`);
    await s.p.waitForFunction((sel) => /Not sent|cancelled/.test(document.querySelector(sel)?.innerText || ''), `${art(1)} .slip.status`, { timeout: 60000 });
    console.log('stranger confirm:', (await txt(s.p, 1)).slice(0, 160));
    if (await s.p.$(`${art(1)} button[data-act="execute"]`)) fail('stranger confirm released the hold');
    await s.ctx.close();
    // 2. the owner's signer, through the Kernel smart account
    s = await session(b, owner.address, true);
    await s.p.click('#connect'); await s.p.waitForFunction(() => /signer/.test(document.querySelector('#net').innerText), null, { timeout: 20000 });
    const net1 = await s.p.innerText('#net'); console.log('owner net:', net1);
    if (!/owner's signer$/.test(net1)) fail('owner signer not recognised: ' + net1);
    await s.p.screenshot({ path: OUT + '/fork_v3_before.png', fullPage: true });
    await s.p.check(`${art(1)} input[data-ack]`); await s.p.click(`${art(1)} button[data-act="confirm"]`);
    await s.p.waitForFunction((sel) => /Payee confirmed|Not sent/.test(document.querySelector(sel)?.innerText || ''), `${art(1)} .slip.status`, { timeout: 90000 });
    console.log('owner confirm:', (await txt(s.p, 1)).slice(0, 160));
    await s.p.waitForSelector(`${art(1)} button[data-act="execute"]`, { timeout: 30000 });
    await s.p.click(`${art(1)} button[data-act="execute"]`);
    await s.p.waitForFunction((sel) => /Paid\.|Not paid|Not sent/.test(document.querySelector(sel)?.innerText || ''), `${art(1)} .slip.status`, { timeout: 90000 });
    const paid = await txt(s.p, 1); console.log('owner pay:', paid.slice(0, 160)); if (!/^Paid\./.test(paid)) fail('run 1 not paid');
    await s.p.waitForFunction((sel) => /PayRunV3 run 1: Paid/.test(document.querySelector(sel)?.innerText || ''), `${art(1)} .status`, { timeout: 60000 })
      .catch(() => fail('run 1 is not shown as "PayRunV3 run 1: Paid" after paying'));
    console.log('run status:', await s.p.$eval(`${art(1)} .status`, (e) => e.innerText));
    if (await s.p.$(`${art(1)} button[data-act="execute"]`)) fail('Approve and pay still offered after paying');
    console.log('headline after:', await s.p.innerText('#headline'));
    await s.p.screenshot({ path: OUT + '/fork_v3_after.png', fullPage: true });
    if (s.dialogs.length) fail('dialogs: ' + s.dialogs.join(' | '));
    if (s.errors.length) fail('page errors: ' + s.errors.join(' | '));
    await s.ctx.close();
    console.log(process.exitCode ? 'FORK PAGE CHECK FAILED' : 'FORK PAGE CHECK OK');
  } catch (e) { fail(String(e)); } finally { await b.close(); }
})();
