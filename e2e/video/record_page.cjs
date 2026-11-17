// Records the approval page paying a staged run on the LOCAL FORK. A tiny EIP-1193 shim stands in for a browser wallet:
// it forwards JSON-RPC to anvil, whose default account 0 (the PayRun owner on the fork) is unlocked, so eth_sendTransaction
// is signed by anvil. Fork only: nothing here touches the real testnet.
const { chromium } = require('playwright');
const OWNER = process.env.OWNER, RPC = 'http://127.0.0.1:8555', OUT = process.env.OUT || '/data/aevum/app/e2e/video/out';
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1, recordVideo: { dir: OUT, size: { width: 1280, height: 800 } } });
  await ctx.addInitScript(({ OWNER, RPC }) => {
    let id = 0;
    const call = async (method, params) => {
      if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [OWNER];
      const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params: params || [] }) });
      const j = await r.json(); if (j.error) throw Object.assign(new Error(j.error.message), j.error); return j.result;
    };
    window.ethereum = { isMetaMask: false, request: ({ method, params }) => call(method, params), on() {}, removeListener() {} };
  }, { OWNER, RPC });
  const p = await ctx.newPage();
  await p.goto('http://127.0.0.1:8099/web/index.html?report=/e2e/reports/report.json&chain=440050');
  await p.waitForSelector('.run'); await p.waitForTimeout(2500);
  const smooth = async (y, ms) => { await p.evaluate(([y, ms]) => new Promise(r => { const s = scrollY, t0 = performance.now(); const f = (t) => { const k = Math.min(1, (t - t0) / ms); scrollTo(0, s + (y - s) * (1 - (1 - k) ** 3)); k < 1 ? requestAnimationFrame(f) : r(); }; requestAnimationFrame(f); }), [y, ms]); };
  await smooth(330, 1600); await p.waitForTimeout(2500);
  await smooth(820, 1600); await p.waitForTimeout(3500);
  await smooth(0, 1400); await p.waitForTimeout(800);
  await p.click('#connect'); await p.waitForTimeout(1500);
  await p.hover('button[data-act="execute"]'); await p.waitForTimeout(700);
  await p.click('button[data-act="execute"]');
  try { await p.waitForFunction(() => /Paid\./.test(document.body.innerText), null, { timeout: 30000 }); } catch (e) { console.log('TX', await p.evaluate(() => document.querySelector('[id^=tx-]')?.innerText)); }
  await p.waitForTimeout(3000);
  await p.screenshot({ path: OUT + '/paid.png' });
  await ctx.close(); await b.close();
})();
