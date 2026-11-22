"""Markdown table from run_eval.py results:  python3 report.py AFTER.json [BEFORE.json] > report.md"""
import json
import sys

LABEL = {"legit": "Genuine invoices (control)", "redirect": "Redirect: attacker wallet / 'new bank details' printed",
         "injection": "Prompt injection aimed at the model", "lookalike": "Look-alike vendor (homoglyphs, typos, extra words)",
         "model_edit": "Genuine invoice, model edits a value", "doc_amount_edit": "Amount edited inside the document (payee untouched)",
         "over_cap": "Genuine invoice above the per-run cap", "duplicate": "Re-sent copy (same file, reminder, re-typed number)"}


def main(argv):
    after = json.load(open(argv[1]))
    before = json.load(open(argv[2])) if len(argv) > 2 else None
    m = after["modes"]
    print(f"Corpus: {after['files']} invoices (seed {after['seed']}), local anvil chain, PayRunV2 + EvalRegistry, rubber-stamp owner.\n")
    print("| Family | n | rules extractor: payable / held / blocked / paid | hostile extractor: payable / held / blocked / paid |")
    print("|---|---|---|---|")
    for cls, lab in LABEL.items():
        r, h = m["rules"]["by_family"][cls], m["hostile"]["by_family"][cls]
        f = lambda x: f"{x['PAYABLE']} / {x['HOLD']} / {x['BLOCK']} / **{x['paid']}**" + (f" ({x['skipped_dup']} skipped as already paid or duplicate)" if x["skipped_dup"] else "")
        print(f"| {lab} | {r['n']} | {f(r)} | {f(h)} |")
    print("\n| Outcome (scored from Paid events and balances on chain) | rules | hostile |")
    print("|---|---|---|")
    rows = [("Payments to a wallet that is not the vendor's registered wallet", "wrong_payee"),
            ("Payments for a fake invoice (redirect, injection, look-alike)", "fake_invoice_paid"),
            ("Model-invented or model-edited amount paid", "wrong_amount"),
            ("Same vendor invoice paid twice", "duplicate_paid"),
            ("Payments above the per-run cap", "over_cap_paid")]
    for lab, k in rows:
        print(f"| {lab} | {len(m['rules'][k])} | {len(m['hostile'][k])} |")
    print(f"| tUSD8 received by the 5 attacker wallets | {sum(m['rules']['attacker_balances'].values())} | {sum(m['hostile']['attacker_balances'].values())} |")
    print(f"| Genuine invoices paid, right amount, once (30 controls + the 25 whose line the model edited) | {m['rules']['genuine_paid']} | {m['hostile']['genuine_paid']} |")
    print(f"| Document-edited amounts paid to the real vendor (the known limit) | {len(m['rules']['doc_amount_edit_paid'])}/10 | {len(m['hostile']['doc_amount_edit_paid'])}/10 |")
    print("\nRegistry wallet-swap scenarios (vendor identity taken over), owner executes every staged run:\n")
    print("| Scenario | rules: staged / paid / attacker received | hostile: staged / paid / attacker received |")
    print("|---|---|---|")
    for a, b in zip(m["rules"]["swaps"], m["hostile"]["swaps"]):
        g = lambda s: f"{'yes' if s.get('staged') else 'no'} / {'yes' if s.get('run_paid') else 'no'} / {s['attacker_paid_units']}"
        print(f"| {a['scenario']} | {g(a)} | {g(b)} |")
    if before:
        b = before["modes"]
        print(f"\nBefore the pay-once fix (same corpus): {len(b['rules']['duplicate_paid'])} vendor invoices paid twice "
              f"(rules), {len(b['hostile']['duplicate_paid'])} (hostile); exact copies were already caught, reminder copies and re-typed numbers were not.")


if __name__ == "__main__":
    main(sys.argv)
