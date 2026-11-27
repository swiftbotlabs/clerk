"""Layer B (checks bypassed) before/after: how many attack lines each contract refuses on chain, per family.

    python3 b_compare.py BEFORE_report.json AFTER_report.json [--md]

Reads two testnet_eval.mjs report.json files (e.g. the published PayRunV2 run e2e/adversarial/testnet-eval.json and a PayRunV3
run). Exits 1 if the two runs did not try the same attack lines, or if any line refused before is not refused after."""
from __future__ import annotations

import json
import sys

FAM = {"redirect": "Redirect", "injection": "Prompt injection", "lookalike": "Look-alike vendor",
       "model_edit": "Model edits a value", "doc_amount_edit": "Amount edited in the document", "over_cap": "Over the per-run cap",
       "duplicate": "Re-sent duplicate"}


def load(p: str) -> tuple[str, dict]:
    r = json.load(open(p))
    return r.get("contract", "PayRunV2"), {b["file"]: b for b in r["result"]["B"]}


def main(argv: list[str]) -> int:
    (ca, a), (cb, b) = load(argv[1]), load(argv[2])
    if sorted(a) != sorted(b) or not a:
        print("FAIL: the two runs tried different attack lines (or none)")
        return 1
    rows, regress = {}, []
    for f, x in a.items():
        y = b[f]
        r = rows.setdefault(x["cls"], {"n": 0, "before": 0, "after": 0, "moved": 0, "reasons": {}})
        r["n"] += 1
        r["before"] += bool(x.get("hash"))
        r["after"] += bool(y.get("hash"))
        if not x.get("hash") and y.get("hash"):
            r["moved"] += 1
            r["reasons"][y["error"]["name"]] = r["reasons"].get(y["error"]["name"], 0) + 1
        if x.get("hash") and not y.get("hash"):
            regress.append(f)
    md = "--md" in argv
    head = f"| Family | attack lines | refused on chain: {ca} | refused on chain: {cb} | newly refused (reason) | still off-chain only |"
    print(head if md else head.replace("|", " "))
    if md:
        print("|---|---|---|---|---|---|")
    tot = {"n": 0, "before": 0, "after": 0, "moved": 0}
    for cls in FAM:
        if cls not in rows:
            continue
        r = rows[cls]
        for k in tot:
            tot[k] += r[k]
        why = ", ".join(f"{k} {v}" for k, v in r["reasons"].items()) or "-"
        print(f"| {FAM[cls]} | {r['n']} | {r['before']} | {r['after']} | {r['moved']} ({why}) | {r['n'] - r['after']} |")
    print(f"| All | {tot['n']} | {tot['before']} | {tot['after']} | {tot['moved']} | {tot['n'] - tot['after']} |")
    if regress:
        print("FAIL: refused before but not after: " + ", ".join(regress))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
