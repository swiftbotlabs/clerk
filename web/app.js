// Clerk approval page. Loaded as a module from index.html (no inline script, so the page runs under script-src 'self').
// Read-only until the owner connects a wallet. Approvals go only to the pinned PayRun contracts below.
import { createWalletClient, createPublicClient, custom, http, parseAbi, formatUnits, encodeFunctionData, encodePacked } from './vendor/viem-2.21.0.js';   // vendored (esm.sh viem@2.21.0 es2022 bundle), sha256 in README
import { walkthrough, simulateRun, BLOCK_REASON } from './sim.js';   // no-wallet simulation (eth_call + a state override; nothing is sent)
const ABI = parseAbi([
  'function runs(uint256) view returns (uint8 status, address stagedBy, uint64 stagedAt, uint128 total, uint32 lineCount)',
  'function execute(uint256 runId)', 'function reject(uint256 runId, string reason)', 'function owner() view returns (address)',
  // PayRunV2 payee-change hold (the v1 PayRun has none of these; the page then behaves as before)
  'function canExecute(uint256 runId) view returns (bool ok, uint256 line, uint8 reason, uint64 releaseAt)',
  'function lineOf(uint256 runId, uint256 i) view returns ((uint256 payeeAgentId, address payee, uint128 amount, bytes32 invoiceHash, bytes32 invoiceRef))',
  'function confirmPayee(uint256 agentId, address wallet)']);
const BLOCKED_TOPIC = '0xeccfe563df0552cce6bb5602228af8212d6b0abec81deed0180430dbc095511e'; // PaymentBlocked(uint256,uint256,uint256,address,uint8,uint64)
const RUN_TTL = 7 * 86400;   // both PayRun versions: a run staged longer ago than this can't be executed (it can still be rejected)
const when = (t) => new Date(Number(t) * 1000).toLocaleString('en', { dateStyle: 'medium', timeStyle: 'short' });
// Why PayRunV2 won't pay a run yet. Read from the contract, never from the report.
async function holdOf(payrun, id, items, stagedAt = 0) {
  let r; try { r = await pub().readContract({ address: payrun, abi: ABI, functionName: 'canExecute', args: [BigInt(id)] }); } catch { return null; }
  const [ok, line, reason, releaseAt] = r; if (ok || ![1, 2, 3].includes(Number(reason))) return null;
  const l = await pub().readContract({ address: payrun, abi: ABI, functionName: 'lineOf', args: [BigInt(id), line] });
  const agent = String(l.payeeAgentId), payee = l.payee;
  const name = items.find((i) => String(i.agent_id) === agent)?.registered_name || 'agent #' + agent;
  const until = [1, 2].includes(Number(reason)) && stagedAt ? ` This run can be paid until ${esc(when(stagedAt + RUN_TTL))}; after that it expires unpaid.` : '';
  return { reason: Number(reason), agent, payee, name, text: holdText(Number(reason), name, payee, releaseAt) + until };
}
function holdText(reason, name, payee, releaseAt) {
  return reason === 1
    ? `<strong>Payment held.</strong> ${esc(name)}'s wallet ${esc(short(payee))} is new or just changed. The hold ends ${esc(when(releaseAt))}. Check the new details with the vendor on a number you already have (not one from the invoice), then confirm the payee, or reject the run.`
    : reason === 2
    ? `<strong>Payment held.</strong> This run was staged while ${esc(name)}'s wallet ${esc(short(payee))} was still on hold, so waiting won't release it. Check the wallet with the vendor on a number you already have, then confirm the payee, or reject the run.`
    : `<strong>Can't be paid.</strong> ${esc(name)}'s registered wallet changed after this run was staged. Reject it; the clerk stages it again and the new wallet is held.`;
}
// The owner may be an ERC-4337 smart account (Kernel v3.1 on Aevum): then the connected wallet is its signing key, signs a
// UserOperation, and submits it to Aevum's EntryPoint v0.7 itself.
const EP = '0x0000000071727De22E5E9d8BAf0edAc6f37da032';
const KECDSA = '0x845ADb2C711129d4f3966735eD98a9F09fC4cE57';   // Kernel's ECDSA validator on Aevum (holds the account's signer)
const OP = '(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)';
const EP_ABI = parseAbi([`function getUserOpHash(${OP} op) view returns (bytes32)`, 'function getNonce(address sender, uint192 key) view returns (uint256)',
  `function handleOps(${OP}[] ops, address beneficiary)`]);
const KERNEL_ABI = parseAbi(['function execute(bytes32 mode, bytes executionCalldata)']);
const ECDSA_ABI = parseAbi(['function ecdsaValidatorStorage(address account) view returns (address owner)']);
const OP_EVENT = '0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f'; // UserOperationEvent
async function viaSmartAccount(owner, target, inner) {
  const callData = encodeFunctionData({ abi: KERNEL_ABI, functionName: 'execute', args: ['0x' + '00'.repeat(32),
    encodePacked(['address', 'uint256', 'bytes'], [target, 0n, inner])] });
  const nonce = await pub().readContract({ address: EP, abi: EP_ABI, functionName: 'getNonce', args: [owner, 0n] });
  const op = { sender: owner, nonce, initCode: '0x', callData, accountGasLimits: encodePacked(['uint128', 'uint128'], [600000n, 600000n]),
    preVerificationGas: 60000n, gasFees: encodePacked(['uint128', 'uint128'], [1000000000n, 1000000000n]), paymasterAndData: '0x', signature: '0x' };
  const userOpHash = await pub().readContract({ address: EP, abi: EP_ABI, functionName: 'getUserOpHash', args: [op] });
  op.signature = await wallet.signMessage({ account, message: { raw: userOpHash } });
  const hash = await wallet.writeContract({ account, chain: null, address: EP, abi: EP_ABI, functionName: 'handleOps', args: [[op], account], type: 'legacy' });
  const rc = await pub().waitForTransactionReceipt({ hash });
  const ev = rc.logs.find((l) => l.topics[0] === OP_EVENT);
  if (!ev || BigInt('0x' + ev.data.slice(2 + 64, 2 + 128)) !== 1n) throw new Error('the smart account refused the call (nothing was paid)');
  return hash;
}
const AEVUM = { chainId: '0xabe5', chainName: 'Aevum testnet', rpcUrls: ['https://rpc-test.qday.info'],
  nativeCurrency: { name: 'tQDAY', symbol: 'tQDAY', decimals: 18 }, blockExplorerUrls: ['https://explorer-test.qday.info'] };
const CHAINS = { 44005: { name: 'Aevum testnet', rpc: 'https://rpc-test.qday.info', explorer: 'https://explorer-test.qday.info' },
                 440050: { name: 'Aevum fork (local)', rpc: 'http://127.0.0.1:8555', explorer: null } };
const STATUS = ['Could not read this run from the chain', 'Waiting for your approval', 'Paid', 'Rejected'];
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const short = (a) => a ? a.slice(0, 6) + '…' + a.slice(-4) : '';
const money = (u) => Number(formatUnits(BigInt(u), 6)).toLocaleString('en', { minimumFractionDigits: 2 }) + ' tUSD8';
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
// The only PayRuns this hosted page will send approvals to (Aevum testnet): PayRun (v1), PayRunV2 and, once deployed, the page's
// PayRunV3 (vendor-signed invoices, our own VendorRegistry). e2e/build_pages.sh fills V3_PAGE from e2e/testnet_v3page.json; empty = none.
const V3_PAGE = '';
const PINNED = { 44005: ['0x2EE29a167CDDb964aAB9C899ea9Ae89847e3Da98', '0x89d14Bf88D8dF1AB8b0F520414fbbC9e1d69F541', ...(/^0x[0-9a-fA-F]{40}$/.test(V3_PAGE) ? [V3_PAGE] : [])] };
const LOCAL = ['localhost', '127.0.0.1', ''].includes(location.hostname);
const isInt = (v) => (typeof v === 'number' && Number.isSafeInteger(v) && v >= 0) || (typeof v === 'string' && /^\d{1,18}$/.test(v));
const isAddr = (a) => /^0x[0-9a-fA-F]{40}$/.test(String(a));
// Reports are data from outside: keep only well-formed fields, so nothing from a report can become markup or a contract address unchecked.
function clean(r) {
  if (!r || typeof r !== 'object' || !isAddr(r.payrun)) throw new Error('not a Clerk pay-run report');
  const items = (Array.isArray(r.items) ? r.items : []).slice(0, 200).filter((i) => i && typeof i === 'object' && i.proposed && typeof i.proposed === 'object'
    && (i.run_id == null || (isInt(i.run_id) && Number(i.run_id) > 0)) && (i.agent_id == null || isInt(i.agent_id)) && isInt(i.units ?? 0))
    .map((i) => ({ ...i, payrun: r.payrun, run_id: i.run_id == null ? null : Number(i.run_id), agent_id: i.agent_id == null ? null : Number(i.agent_id), units: String(i.units ?? 0) }));
  return { payrun: r.payrun, items };
}
const NAMES = { '0x2ee29a167cddb964aab9c899ea9ae89847e3da98': 'PayRun', '0x89d14bf88d8df1ab8b0f520414fbbc9e1d69f541': 'PayRunV2', ...(V3_PAGE ? { [V3_PAGE.toLowerCase()]: 'PayRunV3' } : {}) };
const cname = (payrun) => NAMES[String(payrun).toLowerCase()] || short(payrun);
const trusted = (payrun) => LOCAL || (PINNED[chainId] || []).some((a) => a.toLowerCase() === String(payrun).toLowerCase());
const keyOf = (payrun, id) => String(payrun).slice(2, 10).toLowerCase() + '-' + id;   // DOM-safe: hex + digits only
const notes = {};   // run key -> what happened to the owner's last action (kept across re-renders)
let reports = [], wallet, account, chainId = Number(new URLSearchParams(location.search).get('chain') || 44005);
if (!CHAINS[chainId]) chainId = 44005;
const pub = () => createPublicClient({ transport: http(CHAINS[chainId].rpc) });

function snippet(text, value) {
  if (!text) return '<div class="empty">Not found in the invoice</div>';
  const v = String(value ?? ''); const i = text.toLowerCase().indexOf(v.toLowerCase());
  return '<div>' + (v && i >= 0 ? esc(text.slice(0, i)) + '<mark>' + esc(text.slice(i, i + v.length)) + '</mark>' + esc(text.slice(i + v.length)) : esc(text)) + '</div>';
}
function slip(it, hold) {
  const p = it.proposed, e = it.evidence || {};
  const verdict = hold && String(it.agent_id) === hold.agent ? '<span class="verdict v-hold">Registered wallet, on hold</span>' : '<span class="verdict v-ok">Payee confirmed</span>';
  const src = e.note ? `<div class="src"><div>${esc(e.note)}</div></div>`
    : `<div class="src">${snippet(e.amount, p.amount)}${snippet(e.reference, p.reference)}${snippet(e.due_date, p.due_date)}</div>`;
  return `<div class="slip"><div class="who">${esc(it.registered_name)} <span class="id">agent #${esc(it.agent_id)}</span></div>
    <div class="amt">${money(it.units)}</div>
    <div class="meta">${verdict} Invoice ${esc(p.reference)}${p.due_date ? ', due ' + esc(p.due_date) : ''}, to ${esc(short(p.wallet))}</div>${src}</div>`;
}
// The headline counts everything that needs the owner: runs to approve, held payments, runs to clear, and invoices to check.
function headline(c) {
  const parts = [];
  if (c.pay) parts.push(plural(c.pay, 'pay run to approve', 'pay runs to approve'));
  if (c.held) parts.push(plural(c.held, 'held payment to confirm or reject', 'held payments to confirm or reject'));
  if (c.clear) parts.push(plural(c.clear, 'run that can no longer pay (reject it)', 'runs that can no longer pay (reject them)'));
  if (c.check) parts.push(plural(c.check, 'invoice to check', 'invoices to check'));
  if (c.unread) parts.push(plural(c.unread, 'run could not be read from the chain', 'runs could not be read from the chain'));
  if (!parts.length) return c.runs ? 'Nothing is waiting for you' : 'Nothing to approve';
  const s = parts.join(', '); return s[0].toUpperCase() + s.slice(1);
}
const btn = (act, k, payrun, id, label, cls = '', extra = '') =>
  `<button class="${cls}" data-act="${act}" data-key="${k}" data-payrun="${esc(payrun)}" data-run="${id}"${extra}>${label}</button>`;
async function render() {
  const items = reports.flatMap((r) => r.items);
  const byRun = new Map();
  for (const it of items) if (it.run_id) { const k = keyOf(it.payrun, it.run_id); if (!byRun.has(k)) byRun.set(k, { payrun: it.payrun, id: it.run_id, its: [] }); byRun.get(k).its.push(it); }
  let now = Math.floor(Date.now() / 1000);
  try { now = Number((await pub().getBlock()).timestamp); } catch {}
  const parts = [], c = { runs: byRun.size, pay: 0, held: 0, clear: 0, check: 0, unread: 0 };
  for (const [k, { payrun, id, its }] of byRun) {
    let st = 0, stagedAt = 0;
    try { const r = await pub().readContract({ address: payrun, abi: ABI, functionName: 'runs', args: [BigInt(id)] }); st = Number(r[0]); stagedAt = Number(r[2]); } catch {}
    const expired = st === 1 && now > stagedAt + RUN_TTL;
    const hold = st === 1 && !expired ? await holdOf(payrun, id, its, stagedAt) : null;
    let label = STATUS[st] || 'Unknown', acts = '';
    const can = st === 1 && trusted(payrun);
    const v2 = ['PayRunV2', 'PayRunV3'].includes(cname(payrun)) && trusted(payrun);   // both have the payee-change hold
    const simBtn = (kind, label) => (v2 ? btn('sim', k, payrun, id, label, '', ` data-kind="${kind}"`) : '');
    if (st === 0) c.unread++;
    else if (expired) { if (!(V3_PAGE && cname(payrun) !== 'PayRunV3')) c.clear++; label = 'Expired, not paid: staged more than 7 days ago, so it can no longer be paid'; if (can) acts = btn('reject', k, payrun, id, 'Reject'); }
    else if (hold && hold.reason === 3) { c.clear++; label = 'Can\'t be paid: the payee changed'; if (can) acts = btn('reject', k, payrun, id, 'Reject'); }
    else if (hold) {
      c.held++; label = 'Held: confirm the payee or reject';
      if (can) acts = `<label class="ack"><input type="checkbox" data-ack="${k}"> I checked this wallet with the vendor on a number I already had</label>`
        + btn('confirm', k, payrun, id, 'Confirm payee', 'pay', ` disabled data-agent="${esc(hold.agent)}" data-wallet="${esc(hold.payee)}"`) + btn('reject', k, payrun, id, 'Reject');
    } else if (st === 1) { c.pay++; if (can) acts = btn('execute', k, payrun, id, 'Approve and pay', 'pay') + btn('reject', k, payrun, id, 'Reject'); }
    if (st === 1 && !expired && !(hold && hold.reason === 3)) acts += simBtn(hold ? 'held' : 'pay', hold ? 'Simulate: confirm, then pay' : 'Simulate approving (no wallet)');
    const total = its.reduce((s, i) => s + BigInt(i.units), 0n);
    const rank = st === 1 ? (hold && hold.reason !== 3 ? 0 : expired || hold ? 2 : 1) : st === 0 ? 3 : 4;   // what needs the owner comes first
    parts.push([rank, `<article class="run ${st === 2 ? 'done' : ''}" data-key="${k}" data-run="${id}"><div class="runhead"><div><div class="status">${esc(cname(payrun))}${V3_PAGE && cname(payrun) !== 'PayRunV3' ? ' (earlier contract, history)' : ''} run ${id}: ${esc(label)}</div>
      <div class="total">${money(total)} <small>· ${plural(its.length, 'invoice', 'invoices')}</small></div></div>
      <div class="actions">${acts}</div></div>
      ${hold ? `<div class="slip"><div class="held" role="alert">${hold.text}</div></div>` : ''}${its.map((it) => slip(it, hold)).join('')}<div class="slip status" id="tx-${k}" aria-live="polite" ${notes[k] ? '' : 'hidden'}>${notes[k] || ''}</div></article>`]);
  }
  const other = (dec) => items.filter((i) => i.decision === dec || (dec === 'HOLD' && i.decision === 'PAYABLE' && i.skip && !i.run_id && String(i.skip).startsWith('over')));
  c.check = other('HOLD').length;
  $('#headline').textContent = headline(c);
  $('#runs').innerHTML = parts.sort((a, b) => a[0] - b[0]).map((x) => x[1]).join('') || '<p class="empty">The clerk staged nothing this time.</p>';
  if (reports.some((r) => !trusted(r.payrun))) $('#runs').insertAdjacentHTML('afterbegin', '<p class="empty" role="alert">This report names a contract that is not one of Clerk\'s deployed PayRuns, so it is shown read-only.</p>');
  const card = (i, cls, label) => `<div class="item"><span class="verdict ${cls}">${label}</span> <strong>${esc(i.proposed.vendor || i.file)}</strong>
    ${i.proposed.amount ? ' · <span class="nw">' + esc(i.proposed.amount) + ' ' + esc(i.proposed.currency || '') + '</span>' : ''}<ul>${[...(i.reasons || []), ...(i.warnings || []), ...(i.skip ? [i.skip] : [])].map((r) => `<li>${esc(r)}</li>`).join('')}</ul></div>`;
  $('#hold').innerHTML = other('HOLD').map((i) => card(i, 'v-hold', i.decision === 'PAYABLE' ? 'Over the clerk\'s limit' : i.cop === 'CLOSE_MATCH' ? 'Name is close, not exact' : i.cop === 'NO_MATCH' ? 'Unknown vendor' : 'Not found in the invoice')).join('') || '<p class="empty">Nothing waiting.</p>';
  $('#stop').innerHTML = other('BLOCK').map((i) => card(i, 'v-stop', 'Stopped')).join('') || '<p class="empty">Nothing stopped.</p>';
}
// Plain-language wallet state: which network, and whether this key can sign for the PayRun owner.
async function whoAmI() {
  const net = CHAINS[chainId]?.name || `Chain ${chainId}: switch to Aevum testnet`;
  let role = '';
  try {
    const payrun = reports.find((r) => trusted(r.payrun))?.payrun;
    if (payrun && CHAINS[chainId]) {
      const owner = await pub().readContract({ address: payrun, abi: ABI, functionName: 'owner' });
      let signer = owner;
      if ((await pub().getBytecode({ address: owner }))?.length > 2) signer = await pub().readContract({ address: KECDSA, abi: ECDSA_ABI, functionName: 'ecdsaValidatorStorage', args: [owner] });
      role = signer.toLowerCase() === account.toLowerCase() ? ', owner\'s signer' : ', not the owner\'s signer (approvals will fail)';
    }
  } catch {}
  $('#net').textContent = `${net}, ${short(account)}${role}`;
}
async function connect() {
  if (!window.ethereum) { $('#net').textContent = 'No browser wallet found: see "How to connect your wallet" below'; $('#howto').open = true; return; }
  try {
    wallet = createWalletClient({ transport: custom(window.ethereum) });
    [account] = await wallet.requestAddresses();
    chainId = await wallet.getChainId();
    if (!CHAINS[chainId]) {   // offer to switch to (or add) Aevum testnet
      try { await window.ethereum.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: AEVUM.chainId }] }); }
      catch (e) { if (e && e.code === 4902) await window.ethereum.request({ method: 'wallet_addEthereumChain', params: [AEVUM] }); else throw e; }
      chainId = await wallet.getChainId();
    }
    $('#connect').textContent = 'Connected';
    await whoAmI();
    if (reports.length && CHAINS[chainId]) await render();
  } catch (e) { wallet = null; $('#net').textContent = e && e.code === 4001 ? 'You cancelled in your wallet' : 'Could not connect: ' + (e.shortMessage || e.message || e); }
}
const plainError = (e) => e && (e.code === 4001 || /rejected|denied/i.test(e.shortMessage || e.message || '')) ? 'You cancelled in your wallet. Nothing was sent.'
  : 'Not sent: ' + (e.shortMessage || e.message || e);
document.addEventListener('change', (ev) => {
  const k = ev.target?.dataset?.ack; if (!k) return;
  const b = document.querySelector(`button[data-act="confirm"][data-key="${k}"]`); if (b) b.disabled = !ev.target.checked;
});
document.addEventListener('click', async (ev) => {
  const b = ev.target.closest('button[data-act]'); if (!b || !reports.length) return;
  const payrun = b.dataset.payrun, k = b.dataset.key;
  if (!isAddr(payrun) || !trusted(payrun) || !/^[0-9a-f]{8}-\d{1,18}$/.test(k || '') || !/^\d{1,18}$/.test(b.dataset.run || '')) return;
  if (b.dataset.act === 'sim') return simulateClick(b, payrun, k);
  if (!wallet) await connect(); if (!wallet) return;
  const id = BigInt(b.dataset.run), out = $('#tx-' + k); out.hidden = false;
  document.querySelectorAll(`button[data-key="${k}"]`).forEach((x) => { x.disabled = true; });
  try {
    let fn = b.dataset.act, args;
    if (fn === 'confirm') {
      if (!/^\d{1,18}$/.test(b.dataset.agent || '') || !isAddr(b.dataset.wallet)) throw new Error('bad payee data');
      if (!document.querySelector(`input[data-ack="${k}"]`)?.checked) throw new Error('tick the box first: check the wallet with the vendor');
      fn = 'confirmPayee'; args = [BigInt(b.dataset.agent), b.dataset.wallet];
    } else if (fn === 'reject') args = [id, 'rejected by the owner on the approval page'];
    else if (fn === 'execute') args = [id];
    else return;
    out.textContent = fn === 'execute' ? 'Paying… confirm in your wallet.' : fn === 'confirmPayee' ? 'Confirming the payee… confirm in your wallet.' : 'Rejecting… confirm in your wallet.';
    const owner = await pub().readContract({ address: payrun, abi: ABI, functionName: 'owner' });
    let hash;
    if ((await pub().getBytecode({ address: owner }))?.length > 2) {   // smart-account owner: sign a UserOperation
      out.textContent += ' (signing for the smart account ' + short(owner) + ')';
      hash = await viaSmartAccount(owner, payrun, encodeFunctionData({ abi: ABI, functionName: fn, args }));
    } else {
      hash = await wallet.writeContract({ account, chain: null, address: payrun, abi: ABI, functionName: fn, args, type: 'legacy' });
      await pub().waitForTransactionReceipt({ hash });
    }
    if (!/^0x[0-9a-fA-F]{64}$/.test(String(hash))) throw new Error('the wallet returned something that is not a transaction hash');
    const ex = CHAINS[chainId]?.explorer;
    const rc = await pub().getTransactionReceipt({ hash });
    const blocked = rc.logs.some((l) => l.address.toLowerCase() === payrun.toLowerCase() && l.topics[0] === BLOCKED_TOPIC);
    notes[k] = (fn === 'execute' ? (blocked ? 'Not paid: the payee hold blocked it. Nothing moved. ' : 'Paid. ')
      : fn === 'confirmPayee' ? 'Payee confirmed (logged on chain). You can now approve and pay. ' : 'Rejected. Nothing was paid. ') + (ex ? `<a href="${ex}/tx/${hash}" target="_blank" rel="noopener">View transaction</a>` : 'Transaction ' + esc(hash));
    await render();
  } catch (e) {
    out.textContent = plainError(e);
    document.querySelectorAll(`button[data-key="${k}"]`).forEach((x) => { x.disabled = x.dataset.act === 'confirm' ? !document.querySelector(`input[data-ack="${k}"]`)?.checked : false; });
  }
});
$('#connect').addEventListener('click', connect);
$('#file').addEventListener('change', async (e) => { try { reports = [clean(JSON.parse(await e.target.files[0].text()))]; $('#loader').hidden = true; render(); } catch (err) { $('#headline').textContent = 'That file is not a Clerk report'; } });
// ?report= may only name a file on this same site (no other host): a link can't make this page load someone else's report.
function sameSite(src) { try { const u = new URL(src, location.href); return u.origin === location.origin ? u.href : null; } catch { return null; } }
const src = new URLSearchParams(location.search).get('report');
async function load(url) { const r = await fetch(url, { credentials: 'omit' }); if (!r.ok) throw new Error('report not found'); return clean(await r.json()); }
try {
  if (src) { const u = sameSite(src); if (!u) throw new Error('Reports can only be opened from this site'); reports = [await load(u)]; }
  else reports = (await Promise.all(['report.json', 'report-v2.json', 'report-v3.json'].map((f) => load(f).catch(() => null)))).filter(Boolean);   // hosted: PayRun v1 + PayRunV2 (+ PayRunV3)
  if (reports.length) await render(); else $('#loader').hidden = false;
} catch (err) { $('#headline').textContent = String(err.message); $('#loader').hidden = false; }

// ---------------------------------------------------------------- no-wallet simulation (labelled; eth_call only, nothing is sent)
const SIM_TAG = '<span class="sim-tag">Simulation</span> ';
const tusd = (u) => money(u);
async function simulateClick(b, payrun, k) {
  const kind = b.dataset.kind; if (!['pay', 'held'].includes(kind)) return;
  const out = $('#tx-' + k); out.hidden = false; b.disabled = true;
  out.innerHTML = SIM_TAG + 'Asking the contract what would happen…';
  try {
    const r = await simulateRun(pub(), payrun, b.dataset.run, kind);
    const last = r.steps[r.steps.length - 1];
    const lines = [];
    if (kind === 'held') {
      lines.push(`Approve and pay now: ${r.steps[0].paid ? 'paid' : 'not paid, the hold blocks it'}. Nothing moves.`);
      lines.push(r.steps[1].ok ? 'Confirm the payee, only after you\'ve checked the vendor (call them on a number you already had): accepted (only the owner can do this).' : 'Confirm the payee: refused, ' + esc(r.steps[1].why));
    }
    lines.push(last.ok && last.paid ? `Approve and pay: <strong>paid</strong> ${tusd(last.payeeBalance - r.before.payee)} to ${esc(short(r.payee))}, the vendor's registered wallet. Treasury ${tusd(r.before.treasury)} → ${tusd(last.treasuryBalance)}.`
      : `Approve and pay: not paid (${esc(last.why || 'blocked')}).`);
    out.innerHTML = `<div class="simres">${SIM_TAG}What the live contract says would happen if the owner approved now (eth_call as the owner; nothing was signed or sent):<ol>${lines.map((l) => `<li>${l}</li>`).join('')}</ol></div>`;
  } catch (e) { out.innerHTML = SIM_TAG + 'Could not run the simulation: ' + esc(e.shortMessage || e.message || e); }
  b.disabled = false;
}
const SIM_STEPS = ['Start: the clerk stages a new vendor\'s first invoice', 'Approve and pay (without checking the vendor)', 'Confirm the payee (after calling the vendor on a known number)', 'Approve and pay'];
let simUpto = 0, simCache = {};
function simPayrun() { return (PINNED[chainId] || [])[2] || (PINNED[chainId] || [])[1] || reports.find((r) => ['PayRunV3', 'PayRunV2'].includes(cname(r.payrun)))?.payrun || null; }
async function simNext() {
  const payrun = simPayrun(); const btnN = $('#simNext');
  if (!payrun) { $('#simNote').textContent = 'No PayRunV2 or PayRunV3 to simulate against on this network.'; return; }
  const upto = simUpto + 1; btnN.disabled = true; $('#simNote').textContent = 'Asking the contract…';
  try {
    const r = await walkthrough(pub(), payrun, upto, simCache);
    simCache = { ctx: r.ctx, vendor: r.vendor };
    const v = r.vendor, s = r.steps, items = [];
    if (s[0]) items.push(s[0].ok ? `<strong>The clerk stages ${esc(v.name)}'s first invoice</strong> (agent #${esc(v.agentId)}): ${tusd(r.amount)} to its registered wallet ${esc(short(v.wallet))}. Staged as ${esc(cname(payrun))} run ${esc(r.runId)}.`
      + `<span class="r">${s[0].held ? 'Held: ' + esc(BLOCK_REASON[s[0].reason] || 'on hold') + '.' : 'Not held: this vendor is already trusted.'}</span>` : esc(s[0].text));
    if (s[1]) items.push(`<strong>The owner presses Approve and pay without checking.</strong><span class="r">${s[1].paid ? 'Paid.' : `Not paid: the contract blocked it. The treasury still holds ${tusd(s[1].treasury)}; the vendor's wallet is unchanged.`}</span>`);
    if (s[2]) items.push(`<strong>The owner calls the vendor on a number they already had, then confirms the payee.</strong><span class="r">${s[2].ok ? `The contract accepts the confirmation (only the owner can give it). The run ${s[2].canAfter ? 'can now be paid' : 'still can\'t be paid'}.` : 'Refused: ' + esc(s[2].why)}</span>`);
    if (s[3]) items.push(`<strong>Approve and pay.</strong><span class="r">${s[3].paid ? `Paid ${tusd(r.amount)} to ${esc(short(v.wallet))}, ${esc(v.name)}'s registered wallet. Treasury ${tusd(r.start.treasury)} → ${tusd(s[3].treasury)}. Run ${esc(r.runId)}: Paid.` : 'Not paid: ' + esc(s[3].why || 'blocked')}</span>`);
    $('#simSteps').innerHTML = items.map((x) => `<li>${SIM_TAG}${x}</li>`).join('');
    simUpto = upto;
    if (simUpto < 4) { btnN.textContent = 'Next: ' + SIM_STEPS[simUpto]; $('#simNote').textContent = ''; }
    else { btnN.textContent = 'Run it again'; simUpto = 0; simCache = {}; $('#simNote').textContent = 'All of this was computed by the live ' + cname(payrun) + ' and then thrown away: nothing was signed or sent. To do it for real, the owner connects the wallet that signs for its smart account.'; }
  } catch (e) { $('#simNote').textContent = 'Could not run the simulation: ' + (e.shortMessage || e.message || e); }
  btnN.disabled = false;
}
// Name the contract the walkthrough really runs on (PayRunV3 + our VendorRegistry once the page pins one), with explorer links.
async function simLabel() {
  const payrun = simPayrun(); const el = $('#simContract'); if (!payrun || !el) return;
  const ex = CHAINS[chainId]?.explorer, link = (a, t) => ex ? `<a href="${ex}/address/${esc(a)}">${esc(t)}</a>` : esc(t);
  let reg = ''; try { reg = await pub().readContract({ address: payrun, abi: SIM_REG_ABI, functionName: 'registry' }); } catch {}
  el.innerHTML = link(payrun, cname(payrun) + ' ' + short(payrun)) + (cname(payrun) === 'PayRunV3' && isAddr(reg) ? ` (vendors from Clerk's VendorRegistry ${link(reg, short(reg))})` : '');
}
const SIM_REG_ABI = parseAbi(['function registry() view returns (address)']);
simLabel();
$('#simNext').hidden = false;
$('#simNext').addEventListener('click', simNext);
