// r8: what a judge sees on the approval page for the page's PayRunV3 runs, in a real headless browser, NO wallet, reads only.
// Used by e2e/refresh_fork.sh on a LOCAL fork (chain 440050 on 127.0.0.1:8555) after time warps: a held run, a held run after its
// hold ran out, an expired run, and fresh runs after e2e/refresh_page_run.sh. Also usable on the live page (PAGE_URL, chain 44005).
//   EXPECT='1=^PayRunV3 run 1: Expired, not paid;2=^PayRunV3 run 2: Held'   run id = regex on that run's status line
//   HELD_TEXT='regex'      the held run's explanation must match (e.g. "can be paid until")
//   HEADLINE='regex'       the headline must match
//   WALK=1                 the no-wallet walkthrough must still run 4 steps and end "Paid" (simulation)
//   V3_ADDR=0x…            the page's PayRunV3 (article keys use its first 8 hex)
// Fails (exit 1) on any miss, any page error or dialog, or any JSON-RPC call that is not a read.
const { chromium } = require('playwright');
const PAGE = process.env.PAGE_URL || 'http://127.0.0.1:8097/?chain=440050', OUT = process.env.OUT || '.';
const KEY = String(process.env.V3_ADDR || '').slice(2, 10).toLowerCase();
if (!/^[0-9a-f]{8}$/.test(KEY)) throw new Error('V3_ADDR?');
const EXPECT = (process.env.EXPECT || '').split(';').filter(Boolean).map((x) => { const i = x.indexOf('='); return [x.slice(0, i), new RegExp(x.slice(i + 1))]; });
if (!EXPECT.length) throw new Error('EXPECT?');
const READS = new Set(['eth_call', 'eth_getBlockByNumber', 'eth_chainId', 'eth_blockNumber', 'eth_getCode', 'eth_getLogs', 'eth_getBalance', 'eth_getTransactionReceipt']);
let failed = 0; const fail = (m) => { console.log('PAGE STATE FAIL: ' + m); failed++; };
(async () => {
  const b = await chromium.launch(process.env.CHROME_BIN ? { executablePath: process.env.CHROME_BIN } : {});
  try {
    const ctx = await b.newContext({ viewport: { width: 390, height: 844 } });
    const p = await ctx.newPage();
    const errors = [], dialogs = [], bad = [];
    p.on('pageerror', (e) => errors.push(String(e)));
    p.on('console', (m) => { if (m.type() === 'error' && !/fonts\.g/.test(m.text())) errors.push('console: ' + m.text()); });
    p.on('dialog', (d) => { dialogs.push(d.message()); d.dismiss(); });
    p.on('request', (r) => {
      if (r.method() !== 'POST' || !/127\.0\.0\.1:8555|rpc-test\.qday\.info/.test(r.url())) return;
      try { const body = JSON.parse(r.postData() || 'null'); for (const q of Array.isArray(body) ? body : [body]) if (!READS.has(q.method)) bad.push(q.method); }
      catch { bad.push('UNPARSEABLE'); }
    });
    await p.goto(PAGE, { waitUntil: 'load', timeout: 120_000 });
    const ids = EXPECT.map(([id]) => id);
    for (const id of ids) await p.waitForSelector(`article[data-key="${KEY}-${id}"]`, { timeout: 120_000 }).catch(() => fail(`run ${id} is not on the page`));
    await p.waitForTimeout(1500);   // let render() finish its chain reads
    if (await p.evaluate(() => typeof window.ethereum !== 'undefined')) fail('a wallet is present: this check runs without one');
    const head = await p.innerText('#headline'); console.log('headline:', head);
    if (process.env.HEADLINE && !new RegExp(process.env.HEADLINE).test(head)) fail(`headline "${head}" !~ /${process.env.HEADLINE}/`);
    for (const [id, re] of EXPECT) {
      const st = await p.$eval(`article[data-key="${KEY}-${id}"] .status`, (e) => e.innerText).catch(() => '');
      console.log(`run ${id}: ${st}`);
      if (!re.test(st)) fail(`run ${id} status "${st}" !~ ${re}`);
      if (/Held/.test(st) && process.env.HELD_TEXT) {
        const t = await p.$eval(`article[data-key="${KEY}-${id}"] .held`, (e) => e.innerText).catch(() => '');
        console.log(`run ${id} held text: ${t}`);
        if (!new RegExp(process.env.HELD_TEXT).test(t)) fail(`run ${id} held text !~ /${process.env.HELD_TEXT}/`);
      }
    }
    await p.screenshot({ path: `${OUT}/page-state-${process.env.TAG || 'x'}.png`, fullPage: false });
    if (process.env.WALK === '1') {
      await p.waitForSelector('#simNext:not([hidden])', { timeout: 60_000 });
      for (let i = 1; i <= 4; i++) {
        await p.click('#simNext');
        await p.waitForFunction((n) => document.querySelectorAll('#simSteps li').length === n && !document.querySelector('#simNext').disabled, i, { timeout: 90_000 })
          .catch(() => fail(`walkthrough step ${i} did not render`));
      }
      const lis = await p.$$eval('#simSteps li', (x) => x.map((e) => e.innerText));
      console.log('walkthrough step 4:', (lis[3] || '').replace(/\s+/g, ' ').slice(0, 160));
      if (!/^Simulation\s/.test(lis[3] || '') || !/Paid 0\.01 tUSD8 .*Run \d+: Paid\./s.test(lis[3] || '')) fail('walkthrough did not end Paid');
    }
    if (errors.length) fail('page errors: ' + errors.join(' | ').slice(0, 300));
    if (dialogs.length) fail('dialogs: ' + dialogs.join(' | '));
    if (bad.length) fail('non-read RPC methods: ' + [...new Set(bad)].join(','));
  } finally { await b.close(); }
  console.log(failed ? `PAGE STATE CHECK FAILED (${failed})` : 'PAGE STATE CHECK OK');
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.log('PAGE STATE FAIL: ' + e.message); process.exit(1); });
