// The approval page's no-wallet simulation, in a real (separate, headless) browser against the LIVE Aevum testnet, READ-ONLY.
// No wallet is injected. Serves docs/ from 127.0.0.1 and checks:
//   - the 4-step walkthrough: staged + held, "Approve and pay" not paid, payee confirmed, then paid 0.01 tUSD8 (all labelled Simulation)
//   - per-run "Simulate" buttons on the PayRunV2 runs the page lists (a payable run is paid; a held run is paid only after confirming)
//   - every RPC request is a read (eth_call / getBlock / chainId ...); NONE is a send or a wallet method; state overrides are used
//   - no page errors, no dialogs; screenshots at 390 px and 1280 px into OUT
// Usage: NODE_PATH=/data/motion/node_modules CHROME_BIN=/usr/bin/google-chrome OUT=dir PORT=8098 node e2e/video/sim_page_check.cjs
const { chromium } = require('playwright');
const OUT = process.env.OUT || '.', PORT = process.env.PORT || '8098';
const URL = process.env.PAGE_URL || `http://127.0.0.1:${PORT}/index.html`;   // PAGE_URL: e.g. the live page (reads only)
const READS = new Set(['eth_call', 'eth_getBlockByNumber', 'eth_chainId', 'eth_blockNumber', 'eth_getCode', 'eth_getLogs', 'eth_getBalance', 'eth_getTransactionReceipt']);
let failed = 0;
const fail = (m) => { console.log('SIM FAIL: ' + m); failed++; };
(async () => {
  const b = await chromium.launch(process.env.CHROME_BIN ? { executablePath: process.env.CHROME_BIN } : {});
  try {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 900 } });
    const p = await ctx.newPage();
    const errors = [], dialogs = [], methods = [];
    let overrides = 0;
    p.on('pageerror', (e) => errors.push(String(e)));
    p.on('console', (m) => { if (m.type() === 'error' && !/fonts\.g/.test(m.text())) errors.push('console: ' + m.text()); });
    p.on('dialog', (d) => { dialogs.push(d.message()); d.dismiss(); });
    p.on('request', (r) => {
      if (!r.url().startsWith('https://rpc-test.qday.info')) return;
      try {
        const body = JSON.parse(r.postData() || 'null');
        for (const q of Array.isArray(body) ? body : [body]) {
          methods.push(q.method);
          if (q.method === 'eth_call' && q.params?.[2] && Object.keys(q.params[2]).length) overrides++;
        }
      } catch { methods.push('UNPARSEABLE'); }
    });
    await p.goto(URL, { waitUntil: 'load', timeout: 120_000 });
    await p.waitForSelector('#simNext:not([hidden])', { timeout: 60_000 });
    await p.waitForSelector('article[data-run]', { timeout: 120_000 });
    if (await p.evaluate(() => typeof window.ethereum !== 'undefined')) fail('a wallet is present: this check must run without one');

    // ---- the walkthrough
    const want = [/Staged as run \d+\..*Held: the payee is new or just changed/s, /Not paid: the contract blocked it\. The treasury still holds/,
      /The contract accepts the confirmation \(only the owner can give it\)\. The run can now be paid\./, /Paid 0\.01 tUSD8 to .*registered wallet\. Treasury [\d.]+ tUSD8 → [\d.]+ tUSD8\. Run \d+: Paid\./s];
    for (let i = 1; i <= 4; i++) {
      await p.click('#simNext');
      await p.waitForFunction((n) => document.querySelectorAll('#simSteps li').length === n && !document.querySelector('#simNext').disabled, i, { timeout: 90_000 })
        .catch(() => fail(`walkthrough step ${i} did not render (${'note'})`));
      const lis = await p.$$eval('#simSteps li', (x) => x.map((e) => e.innerText));
      if (!want[i - 1].test(lis[i - 1] || '')) fail(`step ${i} text: ${JSON.stringify(lis[i - 1])}; note: ${await p.$eval('#simNote', (e) => e.innerText)}`);
      if (!lis.every((t) => /^Simulation\s/.test(t))) fail(`step ${i}: a line is not labelled Simulation`);
      if (i === 4) {   // B2: the treasury's start balance is the probe's own pre-call read, so start - end is exactly the 0.01 paid
        const m = /Treasury ([\d.,]+) tUSD8 → ([\d.,]+) tUSD8/.exec(lis[3]); const num = (x) => Math.round(Number(x.replace(/,/g, '')) * 100);
        if (!m || num(m[1]) - num(m[2]) !== 1) fail(`step 4: treasury change is not exactly 0.01: ${JSON.stringify(lis[3])}`);
      }
    }
    const note = await p.$eval('#simNote', (e) => e.innerText);
    if (!/nothing was signed or sent/.test(note)) fail('final note does not say nothing was sent: ' + note);
    await p.screenshot({ path: `${OUT}/sim-desktop.png`, fullPage: false, clip: await p.$eval('#sim', (e) => { const r = e.getBoundingClientRect(); return { x: 0, y: r.top + window.scrollY - 8, width: 1280, height: Math.min(900, r.height + 16) }; }) });

    // ---- per-run simulate buttons
    const sims = await p.$$eval('button[data-act="sim"]', (x) => x.map((e) => ({ key: e.dataset.key, kind: e.dataset.kind, label: e.innerText })));
    if (!sims.length) fail('no per-run Simulate button on the page');
    for (const s of sims) {
      await p.click(`button[data-act="sim"][data-key="${s.key}"]`);
      await p.waitForFunction((k) => /What the live contract says|Could not run/.test(document.querySelector('#tx-' + k)?.innerText || ''), s.key, { timeout: 90_000 }).catch(() => {});
      const t = await p.$eval('#tx-' + s.key, (e) => e.innerText);
      if (!/^Simulation\s/.test(t) || !/nothing was signed or sent/.test(t)) fail(`run ${s.key}: result not labelled: ${t}`);
      if (s.kind === 'held' && !/not paid, the hold blocks it[\s\S]*Confirm the payee, only after you've checked the vendor[^:]*: accepted[\s\S]*Approve and pay: paid/.test(t)) fail(`held run ${s.key}: ${t}`);
      if (s.kind === 'pay' && !/Approve and pay: paid .* to .*registered wallet/.test(t)) fail(`payable run ${s.key}: ${t}`);
      const pm = /Approve and pay: paid ([\d.,]+) tUSD8/.exec(t);   // B2: "paid X" = probe's pre-call balance vs after; never 0
      if (pm && !(Number(pm[1].replace(/,/g, '')) > 0)) fail(`run ${s.key}: paid amount is not positive: ${pm[1]}`);
      console.log(`run ${s.key} (${s.kind}): ${t.replace(/\s+/g, ' ').slice(0, 220)}`);
    }

    // ---- phone width
    await p.setViewportSize({ width: 390, height: 844 });
    await p.goto(URL, { waitUntil: 'load', timeout: 120_000 });
    await p.waitForSelector('#simNext:not([hidden])', { timeout: 60_000 });
    for (let i = 1; i <= 4; i++) { await p.click('#simNext'); await p.waitForFunction((n) => document.querySelectorAll('#simSteps li').length === n && !document.querySelector('#simNext').disabled, i, { timeout: 90_000 }).catch(() => fail('phone step ' + i)); }
    const overflow = await p.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
    if (overflow) fail('horizontal scroll at 390 px');
    await (await p.$('#sim')).screenshot({ path: `${OUT}/sim-390.png` });

    // ---- reads only
    const bad = methods.filter((m) => !READS.has(m));
    if (bad.length) fail('non-read RPC methods: ' + [...new Set(bad)].join(', '));
    if (!methods.length) fail('0 RPC requests seen (the check saw nothing)');
    if (!overrides) fail('no eth_call with a state override was seen');
    if (errors.length) fail('page errors: ' + errors.join(' | ').slice(0, 400));
    if (dialogs.length) fail('dialogs: ' + dialogs.join(' | '));
    console.log(`rpc requests ${methods.length} (${[...new Set(methods)].join(', ')}), state-override calls ${overrides}, per-run sims ${sims.length}`);
  } finally { await b.close(); }
  console.log(failed ? `SIM PAGE CHECK FAILED (${failed})` : 'SIM PAGE CHECK OK');
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.log('SIM FAIL: ' + (e.stack || e)); process.exit(1); });
