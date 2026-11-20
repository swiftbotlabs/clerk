"""Clerk reconciliation: match PayRun `Paid` events on Aevum against the accounts-payable ledger.

    python3 reconcile.py --payrun 0x... --from-block N --ledger ledger.csv [--out recon.json]

ledger.csv columns: reference,agent_id,amount   (amount in tUSD8, e.g. 120.00)
Reads logs in 1,000-block chunks (Aevum's eth_getLogs limit), retrying each chunk. Flags, never fixes:
  PAID_OK          paid once, right payee identity, right amount
  AMOUNT_MISMATCH  paid, but not the ledger amount
  PAYEE_MISMATCH   paid to a different vendor identity than the ledger says
  UNPAID           in the ledger, no Paid event yet
  NOT_IN_LEDGER    a Paid event the ledger doesn't know (investigate)
  DUPLICATE        the same reference paid more than once (the contract prevents it per invoice file; checked anyway)
  HELD             unpaid because PayRunV2's payee-change hold blocked its run (a PaymentBlocked event names it)
PayRunV2 also gets a payee audit trail (PayeeChanged, HoldStarted, PaymentBlocked, PayeeConfirmed, HoldReleased), printed
as ALERT lines; on the v1 PayRun there are none.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
import time
from decimal import Decimal

RPC = os.environ.get("AEVUM_RPC", "https://rpc-test.qday.info")
PAID = "Paid(uint256,uint256,bytes32,bytes32,uint256,address,uint256)"
CHUNK = 1000
# PayRunV2 payee-change hold events (name, signature, indexed fields after topic0, data fields as (name, kind))
HOLD_EVENTS = {
    "PayeeChanged": ("PayeeChanged(uint256,address,address,uint32)", ["agent_id", "from", "to"], [("changes", "int")]),
    "HoldStarted": ("HoldStarted(uint256,address,uint64)", ["agent_id", "wallet"], [("release_at", "int")]),
    "PaymentBlocked": ("PaymentBlocked(uint256,uint256,uint256,address,uint8,uint64)", ["run", "agent_id"],
                       [("line", "int"), ("payee", "addr"), ("reason", "int"), ("release_at", "int")]),
    "PayeeConfirmed": ("PayeeConfirmed(uint256,address,address,uint64)", ["agent_id", "wallet", "by"], [("release_at", "int")]),
    "HoldReleased": ("HoldReleased(uint256,address,bool)", ["agent_id", "wallet"], [("early", "int")]),
}
BLOCK_REASONS = {1: "payee on hold", 2: "staged during the hold: needs the owner's confirmation", 3: "payee changed since staging (run closed)"}


def cast(args: list[str], tries: int = 3) -> str:
    last = ""
    for i in range(tries):
        p = subprocess.run(["cast", *args, "--rpc-url", RPC], capture_output=True, text=True, timeout=90)
        if p.returncode == 0:
            return p.stdout.strip()
        last = (p.stderr or p.stdout).strip()
        time.sleep(2 * (i + 1))
    raise RuntimeError(f"cast {args[0]} failed: {last[:300]}")


def paid_events(payrun: str, start: int, end: int) -> list[dict]:
    out = []
    for lo in range(start, end + 1, CHUNK):
        hi = min(lo + CHUNK - 1, end)
        raw = cast(["logs", "--json", "--from-block", str(lo), "--to-block", str(hi), "--address", payrun, PAID])
        logs = json.loads(raw or "[]")
        logs = logs.get("data", logs) if isinstance(logs, dict) else logs
        for lg in logs:
            t, d = lg["topics"], lg["data"][2:]
            words = [d[i:i + 64] for i in range(0, len(d), 64)]  # line, invoiceRef, payee, amount
            ref = bytes.fromhex(words[1]).rstrip(b"\0").decode(errors="replace")
            out.append({"run": int(t[1], 16), "invoice_hash": t[2], "agent_id": int(t[3], 16), "line": int(words[0], 16),
                        "reference": ref, "payee": "0x" + words[2][24:], "units": int(words[3], 16),
                        "tx": lg.get("transactionHash"), "block": int(lg["blockNumber"], 16)})
    return out


def hold_events(payrun: str, start: int, end: int) -> list[dict]:
    """The payee-change hold audit trail, oldest first. Empty for the v1 PayRun (it has no such events)."""
    out = []
    for name, (sig, indexed, data) in HOLD_EVENTS.items():
        for lo in range(start, end + 1, CHUNK):
            hi = min(lo + CHUNK - 1, end)
            logs = json.loads(cast(["logs", "--json", "--from-block", str(lo), "--to-block", str(hi), "--address", payrun, sig]) or "[]")
            logs = logs.get("data", logs) if isinstance(logs, dict) else logs
            for lg in logs:
                t, d = lg["topics"], lg["data"][2:]
                ev = {"event": name, "block": int(lg["blockNumber"], 16), "log_index": int(lg.get("logIndex", "0x0"), 16),
                      "tx": lg.get("transactionHash")}
                for k, topic in zip(indexed, t[1:]):
                    ev[k] = int(topic, 16) if k in ("agent_id", "run") else "0x" + topic[-40:]
                for i, (k, kind) in enumerate(data):
                    w = d[64 * i:64 * (i + 1)]
                    ev[k] = int(w, 16) if kind == "int" else "0x" + w[-40:]
                out.append(ev)
    out.sort(key=lambda e: (e["block"], e["log_index"]))
    return out


def blocked_refs(payrun: str, holds: list[dict]) -> dict[str, dict]:
    """reference -> latest PaymentBlocked event for it (reads the staged line's invoiceRef from the contract)."""
    refs: dict[str, dict] = {}
    for e in holds:
        if e["event"] != "PaymentBlocked":
            continue
        raw = cast(["call", payrun, "lineOf(uint256,uint256)", str(e["run"]), str(e["line"])])[2:]
        if len(raw) < 64 * 5:
            continue
        ref = bytes.fromhex(raw[64 * 4:64 * 5]).rstrip(b"\0").decode(errors="replace")
        refs[ref] = e
    return refs


def reconcile(events: list[dict], ledger: list[dict], blocked: dict[str, dict] | None = None) -> list[dict]:
    by_ref: dict[str, list[dict]] = {}
    for e in events:
        by_ref.setdefault(e["reference"], []).append(e)
    rows, seen = [], set()
    for row in ledger:
        ref, want_id = row["reference"].strip(), int(row["agent_id"])
        want = int((Decimal(row["amount"]) * 10**6).to_integral_value())
        paid = by_ref.get(ref, [])
        seen.add(ref)
        if not paid:
            b = (blocked or {}).get(ref)
            if b:
                rows.append({"reference": ref, "status": "HELD", "expected_units": want, "run": b["run"],
                             "why": BLOCK_REASONS.get(b["reason"], str(b["reason"])), "release_at": b["release_at"], "tx": b["tx"]})
            else:
                rows.append({"reference": ref, "status": "UNPAID", "expected_units": want})
            continue
        e = paid[0]
        status = ("DUPLICATE" if len(paid) > 1 else "PAYEE_MISMATCH" if e["agent_id"] != want_id
                  else "AMOUNT_MISMATCH" if e["units"] != want else "PAID_OK")
        rows.append({"reference": ref, "status": status, "expected_units": want, "paid_units": e["units"],
                     "agent_id": e["agent_id"], "run": e["run"], "tx": e["tx"], "times_paid": len(paid)})
    for ref, paid in by_ref.items():
        if ref not in seen:
            rows.append({"reference": ref, "status": "NOT_IN_LEDGER", "paid_units": paid[0]["units"], "tx": paid[0]["tx"]})
    return rows


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Match PayRun Paid events to the ledger")
    ap.add_argument("--payrun", required=True)
    ap.add_argument("--from-block", type=int, required=True, help="the PayRun deployment block")
    ap.add_argument("--to-block", type=int)
    ap.add_argument("--ledger", required=True)
    ap.add_argument("--out", default="recon.json")
    a = ap.parse_args(argv)
    end = a.to_block or int(cast(["block-number"]))
    events = paid_events(a.payrun, a.from_block, end)
    holds = hold_events(a.payrun, a.from_block, end)
    ledger = list(csv.DictReader(open(a.ledger)))
    rows = reconcile(events, ledger, blocked_refs(a.payrun, holds))
    json.dump({"payrun": a.payrun, "blocks": [a.from_block, end], "events": events, "payee_audit": holds, "rows": rows},
              open(a.out, "w"), indent=1)
    for e in holds:
        detail = {k: v for k, v in e.items() if k not in ("event", "block", "log_index", "tx")}
        if e["event"] == "PaymentBlocked":
            detail["why"] = BLOCK_REASONS.get(e["reason"], e["reason"])
        print(f"ALERT {e['event']:15} block {e['block']} " + " ".join(f"{k}={v}" for k, v in detail.items()))
    for r in rows:
        print(f"{r['status']:16} {r['reference']:12} expected {r.get('expected_units', 0) / 1e6:>9.2f} paid {r.get('paid_units', 0) / 1e6:>9.2f} {r.get('tx') or ''}")
    return 0 if all(r["status"] == "PAID_OK" for r in rows) else 2


if __name__ == "__main__":
    sys.exit(main())
