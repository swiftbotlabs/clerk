// Clerk checks, ported from agent/check.py for the public sandbox Worker (no dependencies; runs in Node and Workers).
// Same rules, same verdicts: every amount, reference and date the extractor proposes must appear in the invoice text; the
// payee wallet must be the one REGISTERED for the vendor; the vendor name gets MATCH / CLOSE_MATCH / NO_MATCH; look-alike
// vendor names anywhere in the invoice hold the line; instruction-like text and printed foreign wallets raise warnings.
// Port notes (fail-closed differences from Python, by design):
//   - digits are ASCII only: an amount written in non-ASCII digits is not found, so the line HOLDs (Python would read it);
//   - word characters are Unicode letters/numbers/underscore ([\p{L}\p{N}_]), as close to Python's \w as JS allows.
// test/check.test.mjs runs the Python fixtures; test/parity.test.mjs compares this file with check.py on generated inputs.

const MONTHS = Object.fromEntries(['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'].map((m, i) => [m, i + 1]));
export const INJECTION_HINTS = /ignore (all |any )?(previous|prior|above) instructions|you are now|system prompt|pay (instead|to) 0x|disregard .{0,30}(rules|instructions)|new (bank|wallet) details/i;
const ADDR = /0x[0-9a-fA-F]{40}/g;
const W = '[\\p{L}\\p{N}_]';

export function normText(s) {
  return String(s).normalize('NFKC').replace(/\s+/gu, ' ').trim().toLowerCase();
}

export function normName(s) {
  let t = normText(s);
  t = t.replace(new RegExp(`[^\\p{L}\\p{N}_ ]`, 'gu'), ' ');
  t = t.replace(new RegExp(`(?<!${W})(ltd|limited|llc|inc|gmbh|plc|co|corp|corporation|company|the)(?!${W})`, 'gu'), ' ');
  return t.replace(/\s+/gu, ' ').trim();
}

// ---------------------------------------------------------------- money as integer cents (Decimal.quantize(0.01), half-even)

/** Parse a decimal string the way Python's Decimal() accepts it (finite values only) -> cents as BigInt, or null. */
export function toCents(raw) {
  const s = String(raw).trim();
  const m = /^([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$/.exec(s);
  if (!m || (m[2] === '' && (m[3] === undefined || m[3] === ''))) return null;
  let digits = (m[2] || '') + (m[3] || '');
  let exp = -(m[3] || '').length + (m[4] ? parseInt(m[4], 10) : 0);
  if (Math.abs(exp) > 400) return null;
  let v = BigInt(digits || '0');
  // value = v * 10^exp; want round_half_even(value * 100)
  let e = exp + 2;
  if (e >= 0) v = v * 10n ** BigInt(e);
  else {
    const d = 10n ** BigInt(-e);
    const q = v / d, r = v % d;
    const twice = r * 2n;
    v = twice > d || (twice === d && q % 2n === 1n) ? q + 1n : q;
  }
  return m[1] === '-' ? -v : v;
}

export function centsStr(c) {
  const neg = c < 0n; const a = neg ? -c : c;
  return `${neg ? '-' : ''}${a / 100n}.${String(a % 100n).padStart(2, '0')}`;
}

const AMOUNT_TOKEN = new RegExp(
  `(?<!${W}|[.,])[0-9]{1,3}(?:[ ,.\\u00a0'][0-9]{3})*(?:[.,][0-9]{1,2})?(?!${W})|(?<!${W}|[.,])[0-9]+(?:[.,][0-9]{1,2})?(?!${W})`, 'gu');

/** Every money-looking number in the text, as cents strings, read as 1,234.56 and as 1.234,56 where unambiguous. */
export function amountsIn(text) {
  const out = new Set();
  for (const [tok] of String(text).matchAll(AMOUNT_TOKEN)) {
    const t = tok.replaceAll('\u00a0', ' ').replaceAll("'", ' ');
    let cand;
    if (/[.,]\d{1,2}$/.test(t)) {
      const decSep = '.,'.includes(t.at(-3)) ? t.at(-3) : t.at(-2);
      const at = t.lastIndexOf(decSep);
      cand = t.slice(0, at).replace(/[ ,.]/g, '') + '.' + t.slice(at + 1);
    } else cand = t.replace(/[ ,.]/g, '');
    const c = toCents(cand);
    if (c !== null) out.add(centsStr(c));
  }
  return out;
}

// ---------------------------------------------------------------- dates (ISO strings)

function addDate(out, y, m, d) {
  const dt = new Date(Date.UTC(y, m - 1, d));
  if (m >= 1 && m <= 12 && dt.getUTCFullYear() === y && dt.getUTCMonth() === m - 1 && dt.getUTCDate() === d)
    out.add(`${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`);
}

/** ISO dates in the text. Numeric d/m/y forms are deliberately NOT accepted (03/04 is ambiguous): they fail closed. */
export function datesIn(text) {
  const out = new Set(); const s = String(text);
  for (const m of s.matchAll(new RegExp(`(?<!${W})(20\\d\\d)-(\\d{2})-(\\d{2})(?!${W})`, 'gu'))) addDate(out, +m[1], +m[2], +m[3]);
  for (const m of s.matchAll(new RegExp(`(?<!${W})(\\d{1,2})(?:st|nd|rd|th)? ([A-Za-z]{3,9})\\.?,? (20\\d\\d)(?!${W})`, 'gu'))) {
    const mon = MONTHS[m[2].slice(0, 3).toLowerCase()]; if (mon) addDate(out, +m[3], mon, +m[1]);
  }
  for (const m of s.matchAll(new RegExp(`(?<!${W})([A-Za-z]{3,9})\\.? (\\d{1,2})(?:st|nd|rd|th)?,? (20\\d\\d)(?!${W})`, 'gu'))) {
    const mon = MONTHS[m[1].slice(0, 3).toLowerCase()]; if (mon) addDate(out, +m[3], mon, +m[2]);
  }
  return out;
}

// ---------------------------------------------------------------- difflib.SequenceMatcher(None, a, b).ratio(), ported

export function ratio(a, b) {
  a = Array.from(a); b = Array.from(b);
  const la = a.length, lb = b.length;
  if (la + lb === 0) return 1.0;
  const b2j = new Map();
  b.forEach((ch, j) => { if (!b2j.has(ch)) b2j.set(ch, []); b2j.get(ch).push(j); });
  if (lb >= 200) {                                   // difflib autojunk: drop "popular" elements of b
    const ntest = Math.floor(lb / 100) + 1;
    for (const [ch, idx] of [...b2j]) if (idx.length > ntest) b2j.delete(ch);
  }
  const longest = (alo, ahi, blo, bhi) => {
    let besti = alo, bestj = blo, bestsize = 0;
    let j2len = new Map();
    for (let i = alo; i < ahi; i++) {
      const next = new Map();
      for (const j of b2j.get(a[i]) || []) {
        if (j < blo) continue;
        if (j >= bhi) break;
        const k = (j2len.get(j - 1) || 0) + 1;
        next.set(j, k);
        if (k > bestsize) { besti = i - k + 1; bestj = j - k + 1; bestsize = k; }
      }
      j2len = next;
    }
    // no isjunk function: the junk-extension passes of difflib are no-ops; popular elements may extend the match
    while (besti > alo && bestj > blo && !b2j.has(b[bestj - 1]) && a[besti - 1] === b[bestj - 1]) { besti--; bestj--; bestsize++; }
    while (besti + bestsize < ahi && bestj + bestsize < bhi && !b2j.has(b[bestj + bestsize]) && a[besti + bestsize] === b[bestj + bestsize]) bestsize++;
    return [besti, bestj, bestsize];
  };
  let matches = 0;
  const queue = [[0, la, 0, lb]];
  while (queue.length) {
    const [alo, ahi, blo, bhi] = queue.pop();
    const [i, j, k] = longest(alo, ahi, blo, bhi);
    if (k) {
      matches += k;
      if (alo < i && blo < j) queue.push([alo, i, blo, j]);
      if (i + k < ahi && j + k < bhi) queue.push([i + k, ahi, j + k, bhi]);
    }
  }
  return (2.0 * matches) / (la + lb);
}

// ---------------------------------------------------------------- registry, policy, verdict

/** entries: [[registered name, wallet], ...] in registry order (first best wins, as in Python's dict order). */
export function lookup(entries, vendor) {
  const want = normName(vendor);
  let best = 0.0, bestName = null, bestWallet = null;
  for (const [name, wallet] of entries) {
    const r = ratio(want, normName(name));
    if (r > best) { best = r; bestName = name; bestWallet = wallet; }
  }
  if (bestName !== null && normName(bestName) === want) return ['MATCH', bestName, bestWallet, best];
  if (best >= 0.85) return ['CLOSE_MATCH', bestName, bestWallet, best];
  return ['NO_MATCH', bestName, null, best];
}

const PO_REF = new RegExp(`(?<!${W})(?:P\\.?O\\.?|purchase order)\\s*(?:no\\.?|number|#)?\\s*[:#]?\\s*([A-Z0-9][A-Z0-9-]{2,})`, 'giu');
export const poKey = (s) => String(s).toUpperCase().replace(/[^A-Z0-9]/g, '');

/** policy = {purchaseOrders: {vendor: {PO: "amount"}}, bands: {vendor: "amount"}} (set by the payer, never by an invoice). */
export function amountExpectation(source, cents, regName, policy) {
  const pos = (policy.purchaseOrders || {})[regName] || {};
  const posC = Object.fromEntries(Object.entries(pos).map(([k, v]) => [k, toCents(v)]));
  if (Object.keys(pos).length) {
    const cited = [...String(source).matchAll(PO_REF)].map((m) => poKey(m[1]));
    const known = cited.filter((c) => c in posC);
    if (!known.length) return 'no purchase order of this vendor is cited on the invoice';
    if (known.every((c) => posC[c] !== cents)) {
      const want = known.map((c) => `${c} = ${pos[c]}`).join(', ');
      return `amount ${centsStr(cents)} differs from the purchase order (${want})`;
    }
  }
  const band = (policy.bands || {})[regName];
  if (band !== undefined && band !== null && cents > toCents(band))
    return `amount ${centsStr(cents)} is above this vendor's usual range (up to ${band})`;
  return null;
}

const splitLines = (s) => {
  const parts = String(s).split(/\r\n|[\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029]/);
  if (parts.length && parts.at(-1) === '') parts.pop();
  return parts;
};

/** line = {vendor, wallet, amount, currency, reference, due_date (ISO)}; registry = [[name, wallet], ...].
 * Returns {decision: PAYABLE|HOLD|BLOCK, cop, registeredName, registeredWallet, checks, reasons, warnings}. */
export function checkLine(source, line, registry, policy = null) {
  source = String(source);
  const text = normText(source);
  const reasons = [], warnings = [], checks = {};
  const vendor = String(line.vendor ?? '');
  checks.vendor_in_document = Boolean(vendor) && text.includes(normText(vendor));
  let rawAmt = String(line.amount ?? 'None').trim();
  if (/^\d{1,3}(,\d{3})+(\.\d{1,2})?$/.test(rawAmt)) rawAmt = rawAmt.replaceAll(',', '');
  const amt = toCents(rawAmt);
  checks.amount_in_document = amt !== null && amt > 0n && amountsIn(source).has(centsStr(amt));
  const ref = String(line.reference ?? '');
  checks.reference_in_document = ref.length >= 3 && text.includes(normText(ref));
  const dm = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(String(line.due_date ?? ''));
  if (dm) {
    const iso = new Set(); addDate(iso, +dm[1], +dm[2], +dm[3]);
    const [d] = [...iso];
    checks.due_date_in_document = Boolean(d) && datesIn(source).has(d);
  } else checks.due_date_in_document = false;
  const cur = String(line.currency ?? '').toUpperCase();
  checks.currency_ok = ['TUSD8', 'USD', 'USDC', 'USD8'].includes(cur) && (text.includes(cur.toLowerCase()) || source.includes('$') || text.includes('usd'));

  const [cop, regName, regWallet, score] = lookup(registry, vendor);
  const wallet = String(line.wallet ?? '');
  checks.wallet_is_registered_for_vendor = Boolean(regWallet) && wallet.toLowerCase() === regWallet.toLowerCase();
  const printed = new Set([...source.matchAll(ADDR)].map((m) => m[0].toLowerCase()));
  if (printed.size && regWallet && !printed.has(regWallet.toLowerCase()))
    warnings.push("the invoice prints a wallet that is NOT the vendor's registered wallet: possible redirection fraud");
  if (INJECTION_HINTS.test(source)) warnings.push('the document contains instruction-like text; it was treated as data');

  if (regName && cop === 'MATCH') {
    const target = normName(regName);
    for (const raw of splitLines(source)) {
      const cand = raw.includes(':') ? raw.slice(raw.indexOf(':') + 1) : raw;
      const c = normName(cand);
      if (c && c !== target && ratio(c, target) >= 0.8) {
        checks.no_lookalike_vendor_names = false;
        warnings.push(`the invoice also names '${cand.trim().slice(0, 60)}', a near-copy of the registered '${regName}'`);
      }   // check.py warns once per look-alike line (its break only leaves the inner loop)
    }
    if (!('no_lookalike_vendor_names' in checks)) checks.no_lookalike_vendor_names = true;
  }

  let why = null;
  if (policy && regName && cop === 'MATCH' && checks.amount_in_document) {
    why = amountExpectation(source, amt, regName, policy);
    checks.amount_as_expected = why === null;
  }
  for (const [k, ok] of Object.entries(checks))
    if (!ok) reasons.push(k === 'amount_as_expected' ? why : k.replaceAll('_', ' ') + ': failed');
  let decision;
  if (cop === 'NO_MATCH' || !checks.wallet_is_registered_for_vendor) decision = 'BLOCK';
  else if (reasons.length || cop === 'CLOSE_MATCH') {
    decision = 'HOLD';
    if (cop === 'CLOSE_MATCH') reasons.push(`name is a close match to the registered '${regName}' (${score.toFixed(2)}): a human must confirm`);
  } else decision = 'PAYABLE';
  return { decision, cop, registeredName: regName, registeredWallet: regWallet, checks, reasons, warnings };
}

// ---------------------------------------------------------------- deterministic extractor (agent/stage.py extract_rules)

const reEsc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Proposes a payment line from a labelled invoice. Never trusted: checkLine decides. */
export function extractRules(text) {
  text = String(text);
  const grab = (...labels) => {
    for (const lab of labels) {
      const m = new RegExp(`^\\s*${reEsc(lab)}\\s*[:#]\\s*(.+?)\\s*$`, 'im').exec(text);
      if (m) return m[1];
    }
    return null;
  };
  const amount = grab('amount due', 'total due', 'total');
  const m = /([0-9][0-9.,]*)/.exec(amount || '');
  const dueRaw = grab('due date', 'due') || '';
  const found = datesIn(dueRaw);
  return {
    vendor: grab('from', 'vendor', 'supplier') || '',
    wallet: grab('pay to', 'wallet', 'payment address') || '',
    amount: m ? m[1] : '',
    currency: 'tUSD8',
    reference: grab('invoice no', 'invoice number', 'invoice', 'reference') || '',
    due_date: found.size === 1 ? [...found][0] : dueRaw,
  };
}
