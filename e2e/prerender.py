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
import os
import subprocess
import sys
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

APP = Path(__file__).resolve().parent.parent
RPC = os.environ.get("AEVUM_RPC", "https://rpc-test.qday.info")
EXPLORER = "https://explorer-test.qday.info"
STATUS = ["", "Waiting for your approval", "Paid", "Rejected"]


def cast(*args: str) -> str:
    p = subprocess.run(["cast", *args, "--rpc-url", RPC], capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        raise RuntimeError(f"cast {args[0]}: {(p.stderr or p.stdout).strip()[:200]}")
    return p.stdout.strip()


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


def slip(it: dict) -> str:
    p, e = it["proposed"], it.get("evidence") or {}
    return (f'<div class="slip"><div class="who">{esc(it["registered_name"])}<span class="id">agent #{esc(it["agent_id"])}</span></div>'
            f'<div class="amt">{money(it["units"])}</div>'
            f'<div class="meta"><span class="verdict v-ok">Payee confirmed</span>Invoice {esc(p["reference"])}, due {esc(p["due_date"])}, to {esc(short(p["wallet"]))}</div>'
            f'<div class="src">{snippet(e.get("amount"), p["amount"])}{snippet(e.get("reference"), p["reference"])}{snippet(e.get("due_date"), p["due_date"])}</div></div>')


def card(i: dict, cls: str, label: str) -> str:
    p = i["proposed"]
    amt = f' · {esc(p["amount"])} {esc(p.get("currency", ""))}' if p.get("amount") else ""
    lis = "".join(f"<li>{esc(r)}</li>" for r in [*(i.get("reasons") or []), *(i.get("warnings") or []), *([i["skip"]] if i.get("skip") else [])])
    return f'<div class="item"><span class="verdict {cls}">{label}</span><strong>{esc(p.get("vendor") or i["file"])}</strong>{amt}<ul>{lis}</ul></div>'


def tx_ok(h: str) -> bool:
    try:
        return cast("receipt", h, "status").split()[0] in ("1", "true", "(success)", "success")
    except RuntimeError:
        return False


def record() -> str:
    t1 = json.loads((APP / "e2e/testnet.json").read_text())
    t2 = json.loads((APP / "e2e/testnet_v2.json").read_text())
    rows = [
        ("Run 1 staged by the clerk's session key (2 invoices; a redirect stopped, a look-alike held)", t1["stage_tx"]),
        ("Run 1 paid by the owner's smart account (UserOperation)", t1["execute_tx"]),
        ("Run 3 (shown above) staged", "0x24f2d55b9a0c2f2edf17c6215c6ff324336ebb50c7c58b74b2012885ae423b33"),
        ("Run 3 paid from this page", "0xf01567cde9d18e6d06de1c473de937b41a9ec6c8bdb6cc8b25452f2df4e83303"),
        ("PayRunV2 deployed (payee-change hold)", t2["payrun_v2_deploy_tx"]),
        ("A new payee staged on hold, the owner's pay attempt blocked, nothing paid", t2["block_execute_tx"]),
        ("Owner confirms a payee early (audit event on chain)", t2["confirm_tx"]),
        ("The clerk's key as a Kernel permission: first UserOperation enables it and stages a run", t2["perm_stage_tx"]),
        ("The owner revokes the clerk's permission", t2["perm_revoke_tx"]),
    ]
    lis = []
    for label, h in rows:
        ok = tx_ok(h)
        lis.append(f'<li>{esc(label)}: <a href="{EXPLORER}/tx/{esc(h)}">{esc(h[:10])}…</a>'
                   f'{"" if ok else " (could not read its receipt at build time)"}</li>')
    return ("<h2>On Aevum testnet</h2><p>Every step below is a transaction you can open on the explorer. Contracts: "
            f'<a href="{EXPLORER}/address/0x89d14Bf88D8dF1AB8b0F520414fbbC9e1d69F541">PayRunV2</a>, '
            f'<a href="{EXPLORER}/address/0x2EE29a167CDDb964aAB9C899ea9Ae89847e3Da98">PayRun</a>, '
            f'<a href="{EXPLORER}/address/0x4Ea16B1bb18005344FC77491F3809a47C74c01a4">ClerkStagePolicy</a> (verified source).</p>'
            f'<section id="record" class="item"><ul class="rec">{"".join(lis)}</ul></section>')


def main(argv: list[str]) -> int:
    page = Path(argv[1]) if len(argv) > 1 else APP / "docs/index.html"
    report = json.loads((page.parent / "report.json").read_text())
    items = report.get("items") or []
    by_run: dict[int, list[dict]] = {}
    for it in items:
        if it.get("run_id"):
            by_run.setdefault(int(it["run_id"]), []).append(it)
    parts, waiting = [], 0
    for rid, its in sorted(by_run.items()):
        st = int(cast("call", report["payrun"], "runs(uint256)(uint8,address,uint64,uint128,uint32)", str(rid)).split()[0])
        waiting += st == 1
        total = sum(int(i["units"]) for i in its)
        parts.append(f'<article class="run {"done" if st == 2 else ""}" data-run="{rid}"><div class="runhead"><div>'
                     f'<div class="status">Run {rid}: {STATUS[st] if st < len(STATUS) else "Unknown"}</div>'
                     f'<div class="total">{money(total)}<small>{len(its)} invoice{"s" if len(its) > 1 else ""}</small></div></div>'
                     f'<div class="actions"></div></div>{"".join(slip(i) for i in its)}</article>')
    headline = ("Nothing is waiting for you" if by_run else "Nothing to approve") if waiting == 0 else \
        ("One pay run is waiting for you" if waiting == 1 else f"{waiting} pay runs are waiting for you")

    def other(dec: str) -> list[dict]:
        return [i for i in items if i.get("decision") == dec or (dec == "HOLD" and i.get("decision") == "PAYABLE" and i.get("skip")
                                                                 and not i.get("run_id") and str(i["skip"]).startswith("over"))]
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
    put('<h1 id="headline">Pay runs waiting for you</h1>', f'<h1 id="headline">{esc(headline)}</h1>')
    runs_html = "".join(parts) or '<p class="empty">The clerk staged nothing this time.</p>'
    put('<section id="runs"></section>', f'<section id="runs">{runs_html}</section>')
    put('<section id="hold"></section>', f'<section id="hold">{hold}</section>')
    put('<section id="stop"></section>', f'<section id="stop">{stop}</section>\n{record()}\n'
        f'<p class="status">Rendered from Aevum testnet block {esc(block)} on {stamp}. With JavaScript the page re-reads the chain live; '
        'connect the owner\'s wallet only to approve.</p>')
    put('<button id="connect">Connect wallet</button>', '<button id="connect">Connect wallet</button><noscript><span class="net">(JavaScript is only needed to approve)</span></noscript>')
    page.write_text(s)
    print(f"prerendered {page}: {len(by_run)} run(s), {len(other('HOLD'))} held, {len(other('BLOCK'))} stopped, block {block}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
