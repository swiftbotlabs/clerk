"""Put a finished PayRunV3 (vendor-signed invoices) full-160 TESTNET run in place next to the PayRunV2 one (no chain writes, no git).

    python3 e2e/adversarial/publish_v3.py WORKDIR      # WORKDIR = the --work dir of testnet_eval.mjs --testnet --payrun v3 --set full

Gates (any failure exits 1 and writes nothing): report.json is a testnet PayRunV3 run of the full set with signedOnly ON, against
our own VendorRegistry; 0 wrong
outcomes in its own score; genuine 55/55 (rules) and 30/55 (hostile); the judge rerun (sandbox/judge_rerun.mjs, public RPC,
read-only) exits 0; b_compare.py against the published PayRunV2 run (testnet-eval.json) exits 0 (same attack lines, nothing refused
before is accepted now). Then copies report.md -> TESTNET-EVAL-V3.md and report.json -> testnet-eval-v3.json and prints the
before/after table and the numbers for the submission text.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent.parent


def die(m: str) -> None:
    print("FAIL: " + m)
    sys.exit(1)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        die("usage: publish_v3.py WORKDIR")
    work = Path(argv[1]).resolve()
    rj, rm = work / "report.json", work / "report.md"
    for p in (rj, rm):
        if not p.is_file() or p.is_symlink():
            die(f"{p} missing (or a symlink)")
    if rj.stat().st_size > 20 * 1024 * 1024:
        die("report.json over 20 MB")
    r = json.loads(rj.read_text())
    test_rpc = os.environ.get("PUBLISH_TEST_RPC", "")   # rehearsal of this script with a FORK report only
    if test_rpc and not re.fullmatch(r"http://127\.0\.0\.1:\d+", test_rpc):
        die("PUBLISH_TEST_RPC must be a local anvil URL")
    if r.get("mode") != ("fork" if test_rpc else "testnet"):
        die(f"report mode is {r.get('mode')}")
    if r.get("contract") != "PayRunV3" or r.get("signedOff"):
        die("not a PayRunV3 run with signedOnly on")
    if r.get("registryKind") != "own" or not re.fullmatch(r"0x[0-9a-fA-F]{40}", r.get("registry") or ""):
        die("not a run against our own VendorRegistry (the kit: keep the name-to-address mapping in your own contract)")
    if r.get("set") != "full" or r.get("subset", {}).get("files") != 160:
        die("not the full 160-invoice set")
    s = r["result"]["score"]
    wrong = sum(len(s[m][k]) for m in ("hostile", "rules") for k in
                ("wrong_payee", "fake_invoice_paid", "wrong_amount", "duplicate_paid", "over_cap_paid", "doc_amount_edit_paid"))
    wrong += sum(int(v) for v in s["attacker_balances"].values()) + sum(c["paid"] for c in r["result"]["C"])
    if wrong:
        die(f"{wrong} wrong outcomes in the run's own score")
    if (s["rules"]["genuine_paid"], s["hostile"]["genuine_paid"], s["rules"]["genuine_total"]) != (55, 30, 55):
        die(f"genuine paid rules {s['rules']['genuine_paid']} hostile {s['hostile']['genuine_paid']} (expected 55 / 30 of 55)")
    rpc = test_rpc or "https://rpc-test.qday.info"
    j = subprocess.run(["node", "judge_rerun.mjs", "--report", str(rj), "--rpc", rpc], cwd=APP / "sandbox", capture_output=True, text=True, timeout=1800)
    if j.returncode != 0:
        print(j.stdout[-3000:], j.stderr[-1000:])
        die("judge rerun did not match")
    c = subprocess.run([sys.executable, str(HERE / "b_compare.py"), str(HERE / "testnet-eval.json"), str(rj), "--md"], capture_output=True, text=True)
    if c.returncode != 0:
        print(c.stdout)
        die("b_compare against the published PayRunV2 run failed")
    if test_rpc:
        print("REHEARSAL OK (fork report): nothing copied")
        print(c.stdout)
        return 0
    shutil.copyfile(rm, HERE / "TESTNET-EVAL-V3.md")
    shutil.copyfile(rj, HERE / "testnet-eval-v3.json")
    b = r["result"]["B"]
    print(json.dumps({"txs": len(r["txs"]), "gas_tqday": s["gas_tqday"], "genuine_rules": "55/55", "genuine_hostile": "30/55",
                      "b_lines": len(b), "b_refused": sum(1 for x in b if x.get("hash")), "b_offchain_only": sum(1 for x in b if not x.get("hash")),
                      "payruns": r["payruns"], "registry": r["registry"]}, indent=1))
    print(c.stdout)
    print("copied: e2e/adversarial/TESTNET-EVAL-V3.md, e2e/adversarial/testnet-eval-v3.json")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
