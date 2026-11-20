// Stills of the approval page paying staged run 2 on the REAL Aevum testnet (signer_proxy.py on :8556 holds the testnet owner key).
const { chromium } = require('playwright');
const OUT = process.env.OUT || '/data/aevum/film/shots';
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
  await ctx.addInitScript(() => {
    let id = 0;
    const call = async (method, params) => {
      const r = await fetch('http://127.0.0.1:8556', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params: params || [] }) });
      const j = await r.json(); if (j.error) throw Object.assign(new Error(j.error.message), j.error); return j.result;
    };
    window.ethereum = { request: ({ method, params }) => call(method, params), on() {}, removeListener() {} };
  });
  const p = await ctx.newPage();
  p.on('console', (m) => { if (m.type() === 'error') console.log('CONSOLE', m.text()); });
  await p.goto('http://127.0.0.1:8099/web/index.html?report=/e2e/film/report3.json&chain=44005');
  await p.waitForSelector('.run'); await p.waitForTimeout(2500);
  await p.screenshot({ path: OUT + '/01_page_top.png' });
  await p.screenshot({ path: OUT + '/02_page_full.png', fullPage: true });
  await p.click('#connect'); await p.waitForTimeout(2000);
  await p.screenshot({ path: OUT + '/03_connected.png' });
  await p.click('button[data-act="execute"]');
  await p.waitForTimeout(1500); await p.screenshot({ path: OUT + '/04_paying.png' });
  await p.waitForFunction(() => /Paid\./.test(document.body.innerText), null, { timeout: 120000 });
  await p.waitForTimeout(1500);
  await p.screenshot({ path: OUT + '/05_paid.png' });
  await p.screenshot({ path: OUT + '/06_paid_full.png', fullPage: true });
  console.log('TXLINK', await p.evaluate(() => [...document.querySelectorAll('a')].map(a => a.href).filter(h => /\/tx\//.test(h)).join(' ')));
  await ctx.close(); await b.close();
})();
