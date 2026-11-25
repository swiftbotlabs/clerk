"""Oracle for test/parity.test.mjs: runs agent/check.py (the reference) on JSON cases from stdin, prints verdicts as JSON."""
import json, os, sys
from decimal import Decimal
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "agent"))
from check import AmountPolicy, Registry, check_line, amounts_in, dates_in  # noqa: E402
import difflib  # noqa: E402
from stage import extract_rules  # noqa: E402

out = []
for case in json.load(sys.stdin):
    kind = case["kind"]
    if kind == "ratio":
        out.append(difflib.SequenceMatcher(None, case["a"], case["b"]).ratio())
    elif kind == "amounts":
        out.append(sorted(str(d) for d in amounts_in(case["text"])))
    elif kind == "dates":
        out.append(sorted(d.isoformat() for d in dates_in(case["text"])))
    elif kind == "extract":
        out.append(extract_rules(case["text"]))
    else:
        pol = None
        if case.get("policy"):
            p = case["policy"]
            pol = AmountPolicy({v: {k: Decimal(a) for k, a in pos.items()} for v, pos in p.get("purchaseOrders", {}).items()},
                               {v: Decimal(a) for v, a in p.get("bands", {}).items()})
        v = check_line(case["source"], case["line"], Registry(dict(case["registry"])), pol)
        out.append({"decision": v.decision, "cop": v.cop, "registeredName": v.registered_name, "checks": v.checks,
                    "reasons": v.reasons, "warnings": v.warnings})
json.dump(out, sys.stdout)
