// Checks the approval page against PayRunV2 on the LOCAL anvil chain from e2e/hold_local.sh (PAGE=1). An EIP-1193 shim
// forwards to anvil, whose unlocked account 0 is the owner. Local only: nothing here touches the real testnet.
// Expects: both runs show a hold and no "Approve and pay"; Confirm payee on run 5 (Acme's new wallet) is logged, then
// the run can be approved and is paid; run 3 (Globex, never confirmed) stays held. Exits 1 on any miss.
const { chromium } = require('playwright');
const OWNER = process.env.OWNER, RPC = 'http://127.0.0.1:8555', OUT = process.env.OUT || '.';
const fail = (m) => { console.log('PAGE FAIL: ' + m); process.exitCode = 1; };
(async () => {
  // a separate headless browser with its own temp profile (never the shared desktop Chrome); CHROME_BIN overrides the binary
  const b = await chromium.launch(process.env.CHROME_BIN ? { executablePath: process.env.CHROME_BIN } : {});
  try {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 900 } });
    await ctx.addInitScript(({ OWNER, RPC }) => {
      let id = 0;
      const call = async (method, params) => {
        if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [OWNER];
        const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params: params || [] }) });
        const j = await r.json(); if (j.error) throw Object.assign(new Error(j.error.message), j.error); return j.result;
      };
      window.ethereum = { request: ({ method, params }) => call(method, params), on() {}, removeListener() {} };
    }, { OWNER, RPC });
    const p = await ctx.newPage();
    const errors = []; p.on('pageerror', (e) => errors.push(String(e))); p.on('dialog', (d) => d.accept());
    await p.goto('http://127.0.0.1:8099/web/index.html?report=/e2e/reports/hold_report.json&chain=440050');
    await p.waitForSelector('.held', { timeout: 20000 });
    const held = await p.$$eval('.held', (els) => els.map((e) => e.innerText));
    console.log('held notices:', held.length); held.forEach((t) => console.log('  ' + t.slice(0, 140)));
    if (held.length !== 2) fail('expected 2 held runs');
    if (await p.$('button[data-act="execute"]')) fail('Approve and pay shown for a held run');
    await p.screenshot({ path: OUT + '/hold_page_before.png', fullPage: true });
    await p.click('#connect');
    await p.click('button[data-act="confirm"][data-run="5"]');
    await p.waitForFunction(() => /Payee confirmed/.test(document.querySelector('#tx-5')?.innerText || ''), null, { timeout: 30000 });
    await p.waitForSelector('button[data-act="execute"][data-run="5"]', { timeout: 10000 });
    if (await p.$('button[data-act="execute"][data-run="3"]')) fail('Globex became payable without confirmation');
    await p.click('button[data-act="execute"][data-run="5"]');
    await p.waitForFunction(() => /Paid\./.test(document.querySelector('#tx-5')?.innerText || ''), null, { timeout: 30000 });
    const after = await p.$$eval('.held', (els) => els.length);
    if (after !== 1) fail('expected only the Globex run still held, got ' + after);
    await p.screenshot({ path: OUT + '/hold_page_after.png', fullPage: true });
    if (errors.length) fail('page errors: ' + errors.join(' | '));
    console.log(process.exitCode ? 'PAGE CHECK FAILED' : 'PAGE CHECK OK');
  } catch (e) { fail(String(e)); } finally { await b.close(); }
})();
