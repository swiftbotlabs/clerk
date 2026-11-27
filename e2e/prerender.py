"""Server-side render of the approval page: docs/index.html shows the testnet pay run with no wallet and no JavaScript.

    python3 e2e/prerender.py [docs/index.html]     (run by e2e/build_pages.sh after docs/ is copied)

At build time it reads the report (docs/report.json) and the chain (Aevum testnet RPC, read-only via `cast`): each run's status, and
the receipt status of every transaction in the testnet record. It writes the same markup the page's script renders, so a visitor
without JavaScript (or a crawler, or a judge's no-JS fetch) sees the run, the held and stopped invoices and the testnet record. When
the script loads, it re-renders those sections live from the chain, and a connected owner can approve. Nothing here can sign anything.
"""
from __future__ import annotations

import html
import json
import re
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

APP = Path(__file__).resolve().parent.parent
RPC = os.environ.get("AEVUM_RPC", "https://rpc-test.qday.info")
EXPLORER = "https://explorer-test.qday.info"
STATUS = ["Could not read this run from the chain", "Waiting for your approval", "Paid", "Rejected"]
RUN_TTL = 7 * 86400
NAMES = {"0x2ee29a167cddb964aab9c899ea9ae89847e3da98": "PayRun", "0x89d14bf88d8df1ab8b0f520414fbbc9e1d69f541": "PayRunV2"}
V3PAGE = Path(os.environ.get("CLERK_V3PAGE") or APP / "e2e/testnet_v3page.json")   # the approval page's PayRunV3 (written by e2e/deploy_v3_page.sh); absent = none yet


def v3page() -> dict:
    if not V3PAGE.exists():
        return {}
    d = json.loads(V3PAGE.read_text())
    for k in ("payrun_v3", "registry"):
        if not re.fullmatch(r"0x[0-9a-fA-F]{40}", str(d.get(k, ""))):
            raise SystemExit(f"prerender: {V3PAGE.name} {k} is not an address")
    return d


if v3page():
    NAMES[v3page()["payrun_v3"].lower()] = "PayRunV3"


def cast(*args: str, tries: int = 3) -> str:
    for n in range(tries):   # the public RPC drops a request now and then: retry reads
        p = subprocess.run(["cast", *args, "--rpc-url", RPC], capture_output=True, text=True, timeout=60)
        if p.returncode == 0:
            return p.stdout.strip()
        time.sleep(2 * (n + 1))
    raise RuntimeError(f"cast {args[0]}: {(p.stderr or p.stdout).strip()[:200]}")


def esc(s) -> str:
    return html.escape(str(s if s is not None else ""), quote=True)


def short(a: str) -> str:
    return a[:6] + "…" + a[-4:] if a else ""


def money(units) -> str:
    return f"{Decimal(int(units)) / Decimal(10**6):,.2f} tUSD8"


def snippet(text, value) -> str:
    if not text:
        return '<div class="empty">Not found in the invoice</div>'
    v = str(value or "")
    i = text.lower().find(v.lower())
    if v and i >= 0:
        return "<div>" + esc(text[:i]) + "<mark>" + esc(text[i:i + len(v)]) + "</mark>" + esc(text[i + len(v):]) + "</div>"
    return "<div>" + esc(text) + "</div>"


def slip(it: dict, hold: dict | None = None) -> str:
    p, e = it["proposed"], it.get("evidence") or {}
    verdict = ('<span class="verdict v-hold">Registered wallet, on hold</span>' if hold and str(it.get("agent_id")) == hold["agent"]
               else '<span class="verdict v-ok">Payee confirmed</span>')
    src = (f'<div class="src"><div>{esc(e["note"])}</div></div>' if e.get("note") else
           f'<div class="src">{snippet(e.get("amount"), p["amount"])}{snippet(e.get("reference"), p["reference"])}{snippet(e.get("due_date"), p.get("due_date"))}</div>')
    due = f', due {esc(p["due_date"])}' if p.get("due_date") else ""
    return (f'<div class="slip"><div class="who">{esc(it["registered_name"])} <span class="id">agent #{esc(it["agent_id"])}</span></div>'
            f'<div class="amt">{money(it["units"])}</div>'
            f'<div class="meta">{verdict} Invoice {esc(p["reference"])}{due}, to {esc(short(p["wallet"]))}</div>{src}</div>')


def when(t: int) -> str:
    return datetime.fromtimestamp(int(t), timezone.utc).strftime("%d %b %Y %H:%M UTC")


def hold_of(payrun: str, rid: int, its: list[dict]) -> dict | None:
    """Same reading as the page's holdOf(): PayRunV2.canExecute, then the blocked line. v1 has no canExecute -> None."""
    try:
        ok, line, reason, release = cast("call", payrun, "canExecute(uint256)(bool,uint256,uint8,uint64)", str(rid)).split("\n")[:4]
    except RuntimeError:
        return None
    reason, release = int(reason.split()[0]), int(release.split()[0])
    if ok.strip() == "true" or reason not in (1, 2, 3):
        return None
    l = cast("call", payrun, "lineOf(uint256,uint256)((uint256,address,uint128,bytes32,bytes32))", str(rid), line.split()[0])
    agent, payee = l.strip("()").split(", ")[:2]
    name = next((i["registered_name"] for i in its if str(i.get("agent_id")) == agent), f"agent #{agent}")
    n, w = esc(name), esc(short(payee))
    text = (f"<strong>Payment held.</strong> {n}'s wallet {w} is new or just changed. The hold ends {esc(when(release))}. Check the new details with the vendor on a number you already have (not one from the invoice), then confirm the payee, or reject the run."
            if reason == 1 else
            f"<strong>Payment held.</strong> This run was staged while {n}'s wallet {w} was still on hold, so waiting won't release it. Check the wallet with the vendor on a number you already have, then confirm the payee, or reject the run."
            if reason == 2 else
            f"<strong>Can't be paid.</strong> {n}'s registered wallet changed after this run was staged. Reject it; the clerk stages it again and the new wallet is held.")
    return {"reason": reason, "agent": agent, "payee": payee, "text": text}


def plural(n: int, one: str, many: str) -> str:
    return f"{n} {one if n == 1 else many}"


def headline(c: dict) -> str:
    """Same wording as the page's headline(): counts everything that needs the owner."""
    parts = []
    if c["pay"]: parts.append(plural(c["pay"], "pay run to approve", "pay runs to approve"))
    if c["held"]: parts.append(plural(c["held"], "held payment to confirm or reject", "held payments to confirm or reject"))
    if c["clear"]: parts.append(plural(c["clear"], "run that can no longer pay (reject it)", "runs that can no longer pay (reject them)"))
    if c["check"]: parts.append(plural(c["check"], "invoice to check", "invoices to check"))
    if c["unread"]: parts.append(plural(c["unread"], "run could not be read from the chain", "runs could not be read from the chain"))
    if not parts:
        return "Nothing is waiting for you" if c["runs"] else "Nothing to approve"
    s = ", ".join(parts)
    return s[0].upper() + s[1:]


def card(i: dict, cls: str, label: str) -> str:
    p = i["proposed"]
    amt = f' · <span class="nw">{esc(p["amount"])} {esc(p.get("currency", ""))}</span>' if p.get("amount") else ""
    lis = "".join(f"<li>{esc(r)}</li>" for r in [*(i.get("reasons") or []), *(i.get("warnings") or []), *([i["skip"]] if i.get("skip") else [])])
    return f'<div class="item"><span class="verdict {cls}">{label}</span> <strong>{esc(p.get("vendor") or i["file"])}</strong>{amt}<ul>{lis}</ul></div>'


def tx_ok(h: str) -> bool:
    try:
        return cast("receipt", h, "status").split()[0] in ("1", "true", "(success)", "success")
    except RuntimeError:
        return False


def record() -> str:
    t1 = json.loads((APP / "e2e/testnet.json").read_text())
    t2 = json.loads((APP / "e2e/testnet_v2.json").read_text())
    rows = [
        ("PayRun run 1 staged by the clerk's session key (2 invoices; a redirect stopped, a look-alike held)", t1["stage_tx"]),
        ("PayRun run 1 paid by the owner's smart account (UserOperation)", t1["execute_tx"]),
        ("PayRun run 3 (shown above) staged", "0x24f2d55b9a0c2f2edf17c6215c6ff324336ebb50c7c58b74b2012885ae423b33"),
        ("PayRun run 3 paid from this page", "0xf01567cde9d18e6d06de1c473de937b41a9ec6c8bdb6cc8b25452f2df4e83303"),
        ("PayRunV2 deployed (payee-change hold)", t2["payrun_v2_deploy_tx"]),
        ("PayRunV2 run 1 (shown above): a new payee staged on hold, the owner's pay attempt blocked, nothing paid", t2["block_execute_tx"]),
        ("Owner confirms a payee early (audit event on chain)", t2["confirm_tx"]),
        ("The clerk's key as a Kernel permission: first UserOperation enables it and stages PayRunV2 run 2 (shown above)", t2["perm_stage_tx"]),
        ("The owner revokes the clerk's permission", t2["perm_revoke_tx"]),
    ]
    t3 = v3page()
    for label, key in (("PayRunV3 deployed for this page (vendor-signed invoices; vendors in our own VendorRegistry)", "payrun_v3_deploy_tx"),
                       ("PayRunV3 set up by the owner's smart account (allowance, the clerk's session, Acme signs its invoices)", "setup_tx"),
                       ("PayRunV3 run 1 staged by the clerk with the vendor's signature (held: the payee is new to this contract)", "stage_tx")):
        if t3.get(key):
            rows.append((label, t3[key]))
    lis = []
    for label, h in rows:
        ok = tx_ok(h)
        lis.append(f'<li>{esc(label)}: <a href="{EXPLORER}/tx/{esc(h)}">{esc(h[:10])}…</a>'
                   f'{"" if ok else " (could not read its receipt at build time)"}</li>')
    v3 = (f'<a href="{EXPLORER}/address/{esc(t3["payrun_v3"])}">PayRunV3</a> and its '
          f'<a href="{EXPLORER}/address/{esc(t3["registry"])}">VendorRegistry</a>, ') if t3 else ""
    return ("<h2>On Aevum testnet</h2><p>Every step below is a transaction you can open on the explorer. Contracts: "
            f'{v3}<a href="{EXPLORER}/address/0x89d14Bf88D8dF1AB8b0F520414fbbC9e1d69F541">PayRunV2</a>, '
            f'<a href="{EXPLORER}/address/0x2EE29a167CDDb964aAB9C899ea9Ae89847e3Da98">PayRun</a>, '
            f'<a href="{EXPLORER}/address/0x4Ea16B1bb18005344FC77491F3809a47C74c01a4">ClerkStagePolicy</a> (verified source{"; PayRunV3 and VendorRegistry: see the README deployments table" if t3 else ""}).</p>'
            f'<section id="record" class="item"><ul class="rec">{"".join(lis)}</ul></section>')


def main(argv: list[str]) -> int:
    page = Path(argv[1]) if len(argv) > 1 else APP / "docs/index.html"
    reports = [json.loads((page.parent / f).read_text()) for f in ("report.json", "report-v2.json", "report-v3.json") if (page.parent / f).exists()]
    items = [dict(i, payrun=r["payrun"]) for r in reports for i in (r.get("items") or [])]
    by_run: dict[tuple[str, int], list[dict]] = {}
    for it in items:
        if it.get("run_id"):
            by_run.setdefault((it["payrun"], int(it["run_id"])), []).append(it)
    now = int(cast("block", "latest", "--field", "timestamp"))
    parts, c = [], {"runs": len(by_run), "pay": 0, "held": 0, "clear": 0, "check": 0, "unread": 0}
    for (payrun, rid), its in by_run.items():
        try:
            r = cast("call", payrun, "runs(uint256)(uint8,address,uint64,uint128,uint32)", str(rid)).split("\n")
            st, staged_at = int(r[0].split()[0]), int(r[2].split()[0])
        except RuntimeError:
            st, staged_at = 0, 0
        expired = st == 1 and now > staged_at + RUN_TTL
        hold = hold_of(payrun, rid, its) if st == 1 and not expired else None
        label = STATUS[st] if st < len(STATUS) else "Unknown"
        if st == 0: c["unread"] += 1
        elif expired: c["clear"] += 1; label = "Expired: staged more than 7 days ago, so it can no longer be paid"
        elif hold and hold["reason"] == 3: c["clear"] += 1; label = "Can't be paid: the payee changed"
        elif hold: c["held"] += 1; label = "Held: confirm the payee or reject"
        elif st == 1: c["pay"] += 1
        total = sum(int(i["units"]) for i in its)
        held_html = f'<div class="slip"><div class="held" role="alert">{hold["text"]}</div></div>' if hold else ""
        rank = (0 if hold and hold["reason"] != 3 else 2 if expired or hold else 1) if st == 1 else 3 if st == 0 else 4
        parts.append((rank, f'<article class="run {"done" if st == 2 else ""}" data-run="{rid}"><div class="runhead"><div>'
                     f'<div class="status">{esc(NAMES.get(payrun.lower(), short(payrun)))} run {rid}: {esc(label)}</div>'
                     f'<div class="total">{money(total)} <small>· {plural(len(its), "invoice", "invoices")}</small></div></div>'
                     f'<div class="actions"></div></div>{held_html}{"".join(slip(i, hold) for i in its)}</article>'))

    def other(dec: str) -> list[dict]:
        return [i for i in items if i.get("decision") == dec or (dec == "HOLD" and i.get("decision") == "PAYABLE" and i.get("skip")
                                                                 and not i.get("run_id") and str(i["skip"]).startswith("over"))]
    c["check"] = len(other("HOLD"))
    head = headline(c)
    hold = "".join(card(i, "v-hold", "Over the clerk's limit" if i["decision"] == "PAYABLE" else "Name is close, not exact"
                        if i.get("cop") == "CLOSE_MATCH" else "Unknown vendor" if i.get("cop") == "NO_MATCH" else "Not found in the invoice")
                   for i in other("HOLD")) or '<p class="empty">Nothing waiting.</p>'
    stop = "".join(card(i, "v-stop", "Stopped") for i in other("BLOCK")) or '<p class="empty">Nothing stopped.</p>'
    block = cast("block-number")
    stamp = datetime.now(timezone.utc).strftime("%d %b %Y %H:%M UTC")

    s = page.read_text()
    def put(old: str, new: str) -> None:
        nonlocal s
        if s.count(old) != 1:
            raise SystemExit(f"prerender: anchor not found once: {old[:50]}")
        s = s.replace(old, new)
    put('<h1 id="headline">Pay runs waiting for you</h1>', f'<h1 id="headline">{esc(head)}</h1>')
    runs_html = "".join(h for _, h in sorted(parts, key=lambda x: x[0])) or '<p class="empty">The clerk staged nothing this time.</p>'
    put('<section id="runs"></section>', f'<section id="runs">{runs_html}</section>')
    put('<section id="hold"></section>', f'<section id="hold">{hold}</section>')
    put('<section id="stop"></section>', f'<section id="stop">{stop}</section>\n{record()}\n'
        f'<p class="status">Rendered from Aevum testnet block {esc(block)} on {stamp}. With JavaScript the page re-reads the chain live; '
        'connect the owner\'s wallet only to approve.</p>')
    put('<button id="connect">Connect wallet</button>', '<button id="connect">Connect wallet</button><noscript><span class="net">(JavaScript is only needed to approve)</span></noscript>')
    page.write_text(s)
    print(f"prerendered {page}: {len(by_run)} run(s) {c}, {len(other('HOLD'))} to check, {len(other('BLOCK'))} stopped, block {block}; headline: {head}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
