"""Clerk: fail-closed checks between an invoice and the payment an AI staged from it. Stdlib only.

The model reads the invoice and proposes a payment line. Nothing it proposes is trusted:
  * every amount, reference and date must appear in the SOURCE text of the invoice (format-tolerant, value-exact);
  * the payee wallet must be the one REGISTERED (ERC-8004 identity) for the vendor named on the invoice. An address that is only
    printed in the document is never enough: that is how invoice-redirection fraud and prompt injection get paid;
  * the vendor name gets a Confirmation-of-Payee verdict: MATCH, CLOSE_MATCH (human must confirm) or NO_MATCH (blocked).
A line is PAYABLE only if every check passes and the verdict is MATCH. Anything else is HOLD (needs a human) or BLOCK.
"""
from __future__ import annotations

import difflib
import re
import unicodedata
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal, InvalidOperation

MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1)}
INJECTION_HINTS = re.compile(
    r"ignore (all |any )?(previous|prior|above) instructions|you are now|system prompt|pay (instead|to) 0x|"
    r"disregard .{0,30}(rules|instructions)|new (bank|wallet) details", re.I)
ADDR = re.compile(r"0x[0-9a-fA-F]{40}")


def norm_text(s: str) -> str:
    s = unicodedata.normalize("NFKC", s)
    return re.sub(r"\s+", " ", s).strip().lower()


def norm_name(s: str) -> str:
    s = norm_text(s)
    s = re.sub(r"[^\w ]", " ", s)
    s = re.sub(r"\b(ltd|limited|llc|inc|gmbh|plc|co|corp|corporation|company|the)\b", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def amounts_in(text: str) -> set[Decimal]:
    """Every money-looking number in the text, read both as 1,234.56 and as 1.234,56 where that is unambiguous."""
    out: set[Decimal] = set()
    for tok in re.findall(r"(?<![\w.,])\d{1,3}(?:[ ,. ']\d{3})*(?:[.,]\d{1,2})?(?![\w])|(?<![\w.,])\d+(?:[.,]\d{1,2})?(?![\w])", text):
        t = tok.replace(" ", " ").replace("'", " ")
        cands = []
        if re.search(r"[.,]\d{1,2}$", t):
            dec_sep = t[-3] if t[-3] in ".," else t[-2]
            whole, frac = t[: t.rfind(dec_sep)], t[t.rfind(dec_sep) + 1:]
            cands.append(re.sub(r"[ ,.]", "", whole) + "." + frac)
        else:
            cands.append(re.sub(r"[ ,.]", "", t))
        for c in cands:
            try:
                out.add(Decimal(c).quantize(Decimal("0.01")))
            except InvalidOperation:
                pass
    return out


def dates_in(text: str) -> set[date]:
    out: set[date] = set()
    for y, m, d in re.findall(r"\b(20\d\d)-(\d{2})-(\d{2})\b", text):
        _add_date(out, int(y), int(m), int(d))
    for d, mon, y in re.findall(r"\b(\d{1,2})(?:st|nd|rd|th)? ([A-Za-z]{3,9})\.?,? (20\d\d)\b", text):
        if mon[:3].lower() in MONTHS:
            _add_date(out, int(y), MONTHS[mon[:3].lower()], int(d))
    for mon, d, y in re.findall(r"\b([A-Za-z]{3,9})\.? (\d{1,2})(?:st|nd|rd|th)?,? (20\d\d)\b", text):
        if mon[:3].lower() in MONTHS:
            _add_date(out, int(y), MONTHS[mon[:3].lower()], int(d))
    return out  # numeric d/m/y forms are deliberately NOT accepted: 03/04 is ambiguous, so they fail closed


def _add_date(out: set[date], y: int, m: int, d: int) -> None:
    try:
        out.add(date(y, m, d))
    except ValueError:
        pass


@dataclass
class Registry:
    """Stand-in for an ERC-8004 identity lookup: registered name -> wallet. The on-chain adapter fills it."""
    entries: dict[str, str]  # display name -> 0x wallet

    def lookup(self, vendor: str) -> tuple[str, str | None, str | None, float]:
        want = norm_name(vendor)
        best, best_name, best_wallet = 0.0, None, None
        for name, wallet in self.entries.items():
            r = difflib.SequenceMatcher(None, want, norm_name(name)).ratio()
            if r > best:
                best, best_name, best_wallet = r, name, wallet
        if best_name is not None and norm_name(best_name) == want:
            return "MATCH", best_name, best_wallet, best
        if best >= 0.85:
            return "CLOSE_MATCH", best_name, best_wallet, best
        return "NO_MATCH", best_name, None, best


@dataclass
class AmountPolicy:
    """What the payer expects to owe, set by the payer (never read from an invoice). Closes the gap a document check can't:
    an invoice whose AMOUNT was edited, with the payee untouched.
      purchase_orders: registered vendor name -> {PO number (letters and digits only): amount}. When a vendor has any, its invoice
                       must cite one of its POs and match that PO's amount exactly (the classic PO match).
      bands:           registered vendor name -> highest amount the payer expects on one invoice; above it is held.
    A vendor with neither is checked as before."""
    purchase_orders: dict[str, dict[str, Decimal]] = field(default_factory=dict)
    bands: dict[str, Decimal] = field(default_factory=dict)


PO_REF = re.compile(r"\b(?:P\.?O\.?|purchase order)\s*(?:no\.?|number|#)?\s*[:#]?\s*([A-Z0-9][A-Z0-9-]{2,})", re.I)


def po_key(s: str) -> str:
    return re.sub(r"[^A-Z0-9]", "", s.upper())


def amount_expectation(source: str, amount: Decimal, reg_name: str, policy: AmountPolicy) -> str | None:
    """None if the amount is what the payer expects from this vendor, else the reason to hold it."""
    pos = policy.purchase_orders.get(reg_name) or {}
    if pos:
        cited = [po_key(m) for m in PO_REF.findall(source)]
        known = [c for c in cited if c in pos]
        if not known:
            return "no purchase order of this vendor is cited on the invoice"
        if all(pos[c] != amount for c in known):
            want = ", ".join(f"{c} = {pos[c]}" for c in known)
            return f"amount {amount} differs from the purchase order ({want})"
    band = policy.bands.get(reg_name)
    if band is not None and amount > band:
        return f"amount {amount} is above this vendor's usual range (up to {band})"
    return None


@dataclass
class Verdict:
    decision: str  # PAYABLE | HOLD | BLOCK
    cop: str
    registered_name: str | None
    checks: dict[str, bool] = field(default_factory=dict)
    reasons: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def check_line(source: str, line: dict, registry: Registry, policy: AmountPolicy | None = None) -> Verdict:
    """line = {vendor, wallet, amount, currency, reference, due_date (ISO)} as staged by the model."""
    text = norm_text(source)
    reasons: list[str] = []
    warnings: list[str] = []
    checks: dict[str, bool] = {}

    vendor = str(line.get("vendor", ""))
    checks["vendor_in_document"] = bool(vendor) and norm_text(vendor) in text
    try:
        raw_amt = str(line.get("amount")).strip()
        if re.fullmatch(r"\d{1,3}(,\d{3})+(\.\d{1,2})?", raw_amt):   # "2,428.99" as printed -> 2428.99
            raw_amt = raw_amt.replace(",", "")
        amt = Decimal(raw_amt).quantize(Decimal("0.01"))
        checks["amount_in_document"] = amt > 0 and amt in amounts_in(source)
    except (InvalidOperation, TypeError):
        checks["amount_in_document"] = False
    ref = str(line.get("reference", ""))
    checks["reference_in_document"] = len(ref) >= 3 and norm_text(ref) in text
    try:
        due = datetime.strptime(str(line.get("due_date")), "%Y-%m-%d").date()
        checks["due_date_in_document"] = due in dates_in(source)
    except ValueError:
        checks["due_date_in_document"] = False
    cur = str(line.get("currency", "")).upper()
    checks["currency_ok"] = cur in ("TUSD8", "USD", "USDC", "USD8") and (cur.lower() in text or "$" in source or "usd" in text)

    cop, reg_name, reg_wallet, score = registry.lookup(vendor)
    wallet = str(line.get("wallet", ""))
    checks["wallet_is_registered_for_vendor"] = bool(reg_wallet) and wallet.lower() == reg_wallet.lower()
    printed = {a.lower() for a in ADDR.findall(source)}
    if printed and reg_wallet and reg_wallet.lower() not in printed:
        warnings.append("the invoice prints a wallet that is NOT the vendor's registered wallet: possible redirection fraud")
    if INJECTION_HINTS.search(source):
        warnings.append("the document contains instruction-like text; it was treated as data")

    # Look-alike names: an invoice that also names a near-copy of the registered vendor ("Acme Suppiles Ltd") is a classic
    # impersonation tell, whichever name the model picked. Any such line holds the payment for a human.
    if reg_name and cop == "MATCH":
        target = norm_name(reg_name)
        for raw in source.splitlines():
            for cand in [raw.split(":", 1)[1] if ":" in raw else raw]:   # a labelled line: judge only the value
                c = norm_name(cand)
                if c and c != target and difflib.SequenceMatcher(None, c, target).ratio() >= 0.8:
                    checks["no_lookalike_vendor_names"] = False
                    warnings.append(f"the invoice also names '{cand.strip()[:60]}', a near-copy of the registered '{reg_name}'")
                    break
        checks.setdefault("no_lookalike_vendor_names", True)

    why = None
    if policy and reg_name and cop == "MATCH" and checks["amount_in_document"]:
        why = amount_expectation(source, amt, reg_name, policy)
        checks["amount_as_expected"] = why is None

    for k, ok in checks.items():
        if not ok:
            reasons.append(why if k == "amount_as_expected" else k.replace("_", " ") + ": failed")
    if cop == "NO_MATCH" or not checks["wallet_is_registered_for_vendor"]:
        decision = "BLOCK"
    elif reasons or cop == "CLOSE_MATCH":
        decision = "HOLD"
        if cop == "CLOSE_MATCH":
            reasons.append(f"name is a close match to the registered '{reg_name}' ({score:.2f}): a human must confirm")
    else:
        decision = "PAYABLE"
    return Verdict(decision, cop, reg_name, checks, reasons, warnings)
