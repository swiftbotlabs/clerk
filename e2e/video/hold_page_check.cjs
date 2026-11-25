// Checks the approval page against PayRunV2 on the LOCAL anvil chain from e2e/hold_local.sh (PAGE=1). An EIP-1193 shim
// forwards to anvil, whose unlocked account 0 is the owner. Local only: nothing here touches the real testnet.
// Expects: both runs show a hold, no "Approve and pay", and the headline counts them (never "Nothing is waiting" while a
// line is held). Confirm payee stays disabled until the owner ticks "I checked this wallet"; then one click confirms run 5
// (Acme's new wallet) on chain, and the run can be approved and is paid. Run 3 (Globex, never confirmed) is rejected with
// one click. No browser dialogs. Text never runs together ("tUSD82 invoices"). Exits 1 on any miss.
const { chromium } = require('playwright');
const OWNER = process.env.OWNER, RPC = 'http://127.0.0.1:8555', OUT = process.env.OUT || '.';
const fail = (m) => { console.log('PAGE FAIL: ' + m); process.exitCode = 1; };
const run = (id) => `article[data-run="${id}"]`;
const note = (p, id) => p.$eval(`${run(id)} .slip.status`, (e) => e.innerText).catch(() => '');
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
    const errors = [], dialogs = [];
    p.on('pageerror', (e) => errors.push(String(e))); p.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
    p.on('dialog', (d) => { dialogs.push(d.message()); d.dismiss(); });
    await p.goto('http://127.0.0.1:8099/web/index.html?report=/e2e/reports/hold_report.json&chain=440050');
    await p.waitForSelector('.held', { timeout: 20000 });
    const held = await p.$$eval('.held', (els) => els.map((e) => e.innerText));
    console.log('held notices:', held.length); held.forEach((t) => console.log('  ' + t.slice(0, 140)));
    if (held.length !== 2) fail('expected 2 held runs');
    if (await p.$('button[data-act="execute"]')) fail('Approve and pay shown for a held run');
    const h0 = await p.innerText('#headline'); console.log('headline before:', h0);
    if (!/^2 held payments to confirm or reject/.test(h0)) fail('headline does not count the held runs: ' + h0);
    const body = await p.innerText('body');
    if (/tUSD8\d/.test(body) || /tUSD(?!8)/.test(body) || /Ltdagent|confirmedInvoice/.test(body)) fail('run-together or wrong token text on the page');
    await p.screenshot({ path: OUT + '/hold_page_before.png', fullPage: true });
    await p.click('#connect');
    const confirm5 = `${run(5)} button[data-act="confirm"]`;
    if (!(await p.$eval(confirm5, (e) => e.disabled))) fail('Confirm payee is enabled before the owner ticked the check');
    await p.click(confirm5, { force: true });   // clicking the disabled button must do nothing
    await p.waitForTimeout(1500);
    if (/Payee confirmed/.test(await note(p, 5))) fail('a disabled Confirm payee still confirmed');
    await p.check(`${run(5)} input[data-ack]`);
    await p.click(confirm5);
    await p.waitForFunction((s) => /Payee confirmed/.test(document.querySelector(s)?.innerText || ''), `${run(5)} .slip.status`, { timeout: 30000 });
    await p.waitForSelector(`${run(5)} button[data-act="execute"]`, { timeout: 10000 });
    if (await p.$(`${run(3)} button[data-act="execute"]`)) fail('Globex became payable without confirmation');
    console.log('headline after confirm:', await p.innerText('#headline'));
    await p.click(`${run(5)} button[data-act="execute"]`);
    await p.waitForFunction((s) => /Paid\./.test(document.querySelector(s)?.innerText || ''), `${run(5)} .slip.status`, { timeout: 30000 });
    await p.click(`${run(3)} button[data-act="reject"]`);
    await p.waitForFunction((s) => /Rejected\./.test(document.querySelector(s)?.innerText || ''), `${run(3)} .slip.status`, { timeout: 30000 });
    const after = await p.$$eval('.held', (els) => els.length);
    if (after !== 0) fail('expected no held run after confirm+pay and reject, got ' + after);
    const st3 = await p.innerText(`${run(3)} .status`); if (!/Rejected/.test(st3)) fail('run 3 not shown as Rejected: ' + st3);
    const h1 = await p.innerText('#headline'); console.log('headline after:', h1);
    if (h1 !== 'Nothing is waiting for you') fail('headline after everything is done: ' + h1);
    await p.screenshot({ path: OUT + '/hold_page_after.png', fullPage: true });
    if (dialogs.length) fail('browser dialogs appeared: ' + dialogs.join(' | '));
    if (errors.length) fail('page errors: ' + errors.join(' | '));
    console.log(process.exitCode ? 'PAGE CHECK FAILED' : 'PAGE CHECK OK');
  } catch (e) { fail(String(e)); } finally { await b.close(); }
})();
