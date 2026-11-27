"""r9b: point the README at the PayRunV3 testnet run WITH the source fallback (TESTNET-EVAL-V3b.md), keep the 30/55 run as history.

    python3 e2e/adversarial/readme_v3b.py --verified "29 Nov 2026" [--report e2e/adversarial/testnet-eval-v3b.json] [--readme README.md]

Every number comes from the report json (gates: testnet PayRunV3, own registry, sourceFallback true, 0 wrong, 55/55 both, B 130/130).
Each edit replaces an exact anchor that must occur once; any miss exits 1 and writes nothing. --verified: the date the three new
contracts were verified on the explorer (verify_explorer_v3.sh); without it the deployment rows say "pending".
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

APP = Path(__file__).resolve().parent.parent.parent
EX = "https://explorer-test.qday.info"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", default=str(APP / "e2e/adversarial/testnet-eval-v3b.json"))
    ap.add_argument("--readme", default=str(APP / "README.md"))
    ap.add_argument("--verified", default="")
    ap.add_argument("--allow-fork", action="store_true", help="rehearsal only: accept a fork report (never for the real README)")
    a = ap.parse_args()
    r = json.loads(Path(a.report).read_text())
    s = r["result"]["score"]
    b = r["result"]["B"]
    wrong = sum(len(s[m][k]) for m in ("hostile", "rules") for k in
                ("wrong_payee", "fake_invoice_paid", "wrong_amount", "duplicate_paid", "over_cap_paid", "doc_amount_edit_paid"))
    gates = [r.get("mode") == "testnet" or (a.allow_fork and r.get("mode") == "fork"), r.get("contract") == "PayRunV3",
             r.get("registryKind") == "own", r.get("sourceFallback") is True, wrong == 0,
             (s["hostile"]["genuine_paid"], s["rules"]["genuine_paid"], s["rules"]["genuine_total"]) == (55, 55, 55),
             len(b) == 130 and sum(1 for x in b if x.get("hash")) == 130, sum(c["paid"] for c in r["result"]["C"]) == 0]
    if not all(gates):
        print(f"FAIL: report gates {gates}")
        return 1
    if a.verified and not re.fullmatch(r"\d{1,2} [A-Z][a-z]{2} 20\d\d", a.verified):
        print("FAIL: --verified like '29 Nov 2026'")
        return 1
    n = len(r["txs"])
    dep = {t["step"]: t for t in r["txs"] if t["step"] in ("deploy_registry", "deploy_hostile", "deploy_rules")}
    if set(dep) != {"deploy_registry", "deploy_hostile", "deploy_rules"}:
        print("FAIL: deploy txs missing in the report")
        return 1
    ver = f"yes ({a.verified})" if a.verified else "pending"
    def drow(label, step, purpose):
        t = dep[step]; addr = t["contractAddress"]; h = t["hash"]
        return f"| {label} | [`{addr}`]({EX}/address/{addr}) | {purpose} | [{h[:10]}…]({EX}/tx/{h}) | {ver} |"
    rows = "\n".join([drow("VendorRegistry (eval V3b)", "deploy_registry", "the source-fallback eval's own vendor registry (owner = its eval key)"),
                      drow("PayRunV3 (eval V3b, hostile extractor)", "deploy_hostile", "160-invoice eval with the source fallback, hostile column"),
                      drow("PayRunV3 (eval V3b, rules extractor)", "deploy_rules", "160-invoice eval with the source fallback, rules column")])
    p = Path(a.readme)
    t = p.read_text()
    edits = [
        ("**Adversarial eval on PayRunV3:** [160 attack and control invoices on Aevum testnet: 130 of 130 attack lines refused by the contract, 0 wrong payments, 289 transactions](e2e/adversarial/TESTNET-EVAL-V3.md) (`make judge-rerun-v3`, read-only).",
         f"**Adversarial eval on PayRunV3:** [160 attack and control invoices on Aevum testnet: 130 of 130 attack lines refused by the contract, 0 wrong payments, 55 of 55 genuine invoices paid even with a fully compromised model, {n} transactions](e2e/adversarial/TESTNET-EVAL-V3b.md) (`make judge-rerun-v3b`, read-only; the run before the source fallback, 30 of 55 genuine paid: [TESTNET-EVAL-V3.md](e2e/adversarial/TESTNET-EVAL-V3.md))."),
        ("**5. Check the evidence.** The [PayRunV3 testnet eval](e2e/adversarial/TESTNET-EVAL-V3.md)",
         "**5. Check the evidence.** The [PayRunV3 testnet eval](e2e/adversarial/TESTNET-EVAL-V3b.md)"),
        ("registry wallet swaps: 289 transactions, 130 of 130 attack lines refused on chain, 0 wrong payments, every transaction linked. Re-check it yourself from the repo root: `make judge-rerun-v3`",
         f"registry wallet swaps: {n} transactions, 130 of 130 attack lines refused on chain, 0 wrong payments, 55 of 55 genuine invoices paid with either extractor, every transaction linked. Re-check it yourself from the repo root: `make judge-rerun-v3b`"),
        ("Every attack family of the [160-invoice PayRunV3 eval](e2e/adversarial/TESTNET-EVAL-V3.md)",
         "Every attack family of the [160-invoice PayRunV3 eval](e2e/adversarial/TESTNET-EVAL-V3b.md)"),
        ("([B by family](e2e/adversarial/TESTNET-EVAL-V3.md#b-by-family-refused-by-the-contract-vs-stopped-off-chain-only))",
         "([B by family](e2e/adversarial/TESTNET-EVAL-V3b.md#b-by-family-refused-by-the-contract-vs-stopped-off-chain-only))"),
        ("([C](e2e/adversarial/TESTNET-EVAL-V3.md#c-vendor-wallet-swaps",
         "([C](e2e/adversarial/TESTNET-EVAL-V3b.md#c-vendor-wallet-swaps"),
        ("([before/after](e2e/adversarial/SOURCE-FALLBACK-FORK.md)). The published testnet run above predates it.",
         f"([before/after](e2e/adversarial/SOURCE-FALLBACK-FORK.md)). On Aevum testnet: [TESTNET-EVAL-V3b.md](e2e/adversarial/TESTNET-EVAL-V3b.md), {n} transactions, hostile and rules 55/55, 130/130 refused, 0 wrong (`make judge-rerun-v3b`)."),
        ("The pipeline result is unchanged: 0 wrong payments, genuine 55/55 (rules) and 30/55\n(hostile).",
         f"The pipeline result is unchanged: 0 wrong payments, genuine 55/55 (rules) and 30/55\n(hostile). With the source fallback ([TESTNET-EVAL-V3b.md](e2e/adversarial/TESTNET-EVAL-V3b.md), {n} transactions, `make judge-rerun-v3b`): the same 130/130 refusals and 0 wrong payments, genuine 55/55 with both extractors."),
    ]
    for old, new in edits:
        if t.count(old) != 1:
            print(f"FAIL: anchor not found once: {old[:80]}")
            return 1
        t = t.replace(old, new)
    anchor = next((l for l in t.splitlines() if l.startswith("| PayRunV3 (eval, rules extractor) |")), None)
    if not anchor or t.count(anchor) != 1:
        print("FAIL: deployment row anchor")
        return 1
    t = t.replace(anchor, anchor + "\n" + rows)
    p.write_text(t)
    print(f"README updated: V3b report linked ({n} txs), 3 deployment rows ({ver}), {len(edits)} edits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
