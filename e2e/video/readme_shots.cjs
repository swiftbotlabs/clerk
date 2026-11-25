// Screenshots for the README's judge walkthrough (desktop 1280 px and phone 390 px), in a separate headless browser.
// Read-only everywhere: the approval page's simulation is eth_call only; the sandbox pages are GETs; the extractor demo POST
// sends no transaction (on the live Worker it needs the demo token: DEMO_TOKEN_FILE, sent only to the sandbox origin, never printed).
//   PAGE_URL     approval page        (default https://clerk.swiftbotlab.workers.dev/)
//   SANDBOX_URL  sandbox Worker       (default https://clerk-sandbox.swiftbotlab.workers.dev)
//   EXTRACT_URL  where to run step 3  (default SANDBOX_URL; a local `wrangler dev` works with its test Turnstile secret)
//   OUT          output dir           (default media/walkthrough)      STEPS=1,2,3,4 (default all)
// NODE_PATH=/data/motion/node_modules CHROME_BIN=/usr/bin/google-chrome node e2e/video/readme_shots.cjs
const { chromium } = require('playwright');
const fs = require('fs');
const PAGE = process.env.PAGE_URL || 'https://clerk.swiftbotlab.workers.dev/';
const SBX = (process.env.SANDBOX_URL || 'https://clerk-sandbox.swiftbotlab.workers.dev').replace(/\/$/, '');
const XURL = (process.env.EXTRACT_URL || SBX).replace(/\/$/, '');
const OUT = process.env.OUT || 'media/walkthrough';
const STEPS = (process.env.STEPS || '1,2,3,4').split(',');
const SIZES = [['desktop', 1280, 900], ['390', 390, 844]];
fs.mkdirSync(OUT, { recursive: true });
let token = null;
if (process.env.DEMO_TOKEN_FILE) {
  const st = fs.lstatSync(process.env.DEMO_TOKEN_FILE);
  if (st.isSymbolicLink()) throw new Error('demo token file is a symlink');
  token = fs.readFileSync(process.env.DEMO_TOKEN_FILE, 'utf8').trim();
  if (!/^[0-9a-f]{32,256}$/i.test(token)) throw new Error('demo token file: unexpected format');
}
const shot = async (el, path) => { await el.screenshot({ path }); console.log('wrote ' + path); };
(async () => {
  const b = await chromium.launch(process.env.CHROME_BIN ? { executablePath: process.env.CHROME_BIN } : {});
  let bad = 0;
  try {
    for (const [tag, w, h] of SIZES) {
      const ctx = await b.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 2 });
      if (token) await ctx.route(XURL + '/extract', (route) => route.continue({ headers: { ...route.request().headers(), authorization: 'Bearer ' + token } }));
      const p = await ctx.newPage();
      if (STEPS.includes('1') || STEPS.includes('2')) {
        await p.goto(PAGE, { waitUntil: 'load', timeout: 120_000 });
        await p.waitForSelector('article[data-run]', { timeout: 120_000 });
        await p.waitForTimeout(1500);
        if (STEPS.includes('1')) await p.screenshot({ path: `${OUT}/1-approval-page-${tag}.png` }).then(() => console.log(`wrote ${OUT}/1-approval-page-${tag}.png`));
        if (STEPS.includes('2')) {
          for (let i = 1; i <= 4; i++) {
            await p.click('#simNext');
            await p.waitForFunction((n) => document.querySelectorAll('#simSteps li').length === n && !document.querySelector('#simNext').disabled, i, { timeout: 90_000 });
          }
          await shot(await p.$('#sim'), `${OUT}/2-simulation-${tag}.png`);
        }
      }
      if (STEPS.includes('3')) {
        await p.goto(XURL + '/extract?sample=injection', { waitUntil: 'load', timeout: 60_000 });
        await p.evaluate(() => {   // submit the page's own form; on live the demo token (header) stands in for the human check
          const f = document.querySelector('form[action="/extract"]');
          const i = document.createElement('input'); i.type = 'hidden'; i.name = 'cf-turnstile-response'; i.value = 'XXXX.DUMMY.TOKEN.XXXX'; f.appendChild(i);
          f.querySelectorAll('.cf-turnstile').forEach((x) => x.remove());
          f.submit();
        });
        await p.waitForSelector('#result', { timeout: 60_000 }).catch(() => { bad++; console.log('extract: no result section'); });
        const el = await p.$('#result');
        if (el) {
          const box = await p.evaluate(() => { const a = document.querySelector('#result').getBoundingClientRect(); const z = document.querySelector('main p.muted:last-of-type') || document.querySelector('.result'); const c = z.getBoundingClientRect(); return { x: 0, y: a.top + window.scrollY - 12, width: document.documentElement.clientWidth, height: c.bottom - a.top + 24 }; });
          await p.screenshot({ path: `${OUT}/3-extractor-${tag}.png`, clip: box, fullPage: true });
          console.log(`wrote ${OUT}/3-extractor-${tag}.png`);
        }
      }
      if (STEPS.includes('4')) {
        const st = await (await p.request.get(SBX + '/api/state')).json();
        const a = (st.attempts || []).find((x) => x.outcome === 'refused' && x.kind === 'payee_swap') || (st.attempts || []).find((x) => x.outcome === 'refused');
        if (!a) { bad++; console.log('sandbox: no refused attempt in the log'); }
        else {
          await p.goto(`${SBX}/attempt/${a.id}`, { waitUntil: 'load', timeout: 60_000 });
          await p.screenshot({ path: `${OUT}/4-sandbox-refusal-${tag}.png` });
          console.log(`wrote ${OUT}/4-sandbox-refusal-${tag}.png (attempt ${a.id}, ${a.kind})`);
          fs.writeFileSync(`${OUT}/4-sandbox-attempt.json`, JSON.stringify({ id: a.id, kind: a.kind, url: `${SBX}/attempt/${a.id}` }));
        }
      }
      await ctx.close();
    }
  } finally { await b.close(); }
  process.exit(bad ? 1 : 0);
})().catch((e) => { console.log('SHOTS FAIL: ' + (e.stack || e)); process.exit(1); });
