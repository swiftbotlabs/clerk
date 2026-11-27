"""Build docs/report-v2.json: every run on PayRunV2 (Aevum testnet), read from the chain, for the approval page.

    python3 e2e/report_v2.py [out.json]        (run by e2e/build_pages.sh; read-only `cast call`, no keys)
    python3 e2e/report_v2.py out.json --v3     the approval page's PayRunV3 (e2e/testnet_v3page.json) -> docs/report-v3.json;
                                               vendor names from our VendorRegistry's registration files (tokenURI)

The PayRunV2 runs on testnet were staged by test scripts (the payee-change hold demo and the Kernel-permission test), not
from invoice documents, so each line carries a note saying where it came from instead of invoice text. Lines that a real
clerk run staged can be merged in from that run's report with --with <report.json> (its items win for the same run).
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from decimal import Decimal
from pathlib import Path

APP = Path(__file__).resolve().parent.parent
RPC = os.environ.get("AEVUM_RPC", "https://rpc-test.qday.info")
ORIGIN = {  # invoiceRef -> where the line came from (true for the testnet runs in e2e/testnet_v2.json)
    "G-80": "Staged by the payee-change hold demo (e2e/block_v2_testnet.sh); there is no invoice document for this line.",
    "CLERK-PERM": "Staged by the clerk's Kernel permission in its first UserOperation (contracts/script/ClerkPermission.s.sol); there is no invoice document for this line.",
}


def cast(*args: str, tries: int = 3) -> str:
    for n in range(tries):   # the public RPC drops a request now and then: retry reads, never guess
        p = subprocess.run(["cast", *args, "--rpc-url", RPC], capture_output=True, text=True, timeout=60)
        if p.returncode == 0:
            return p.stdout.strip()
        time.sleep(2 * (n + 1))
    raise RuntimeError(f"cast {args[0]}: {(p.stderr or p.stdout).strip()[:200]}")


def ref_text(b32: str) -> str:
    raw = bytes.fromhex(b32[2:]).rstrip(b"\0")
    t = raw.decode("utf-8", "replace")
    return t if re.fullmatch(r"[\x20-\x7e]{1,32}", t) else b32[:10] + "…"


def registry_names(registry: str, ids: set[int]) -> dict[int, str]:
    """Vendor names from our VendorRegistry's registration files (data:application/json;base64 with a "name"). Unreadable = no name."""
    import base64
    out = {}
    for i in sorted(ids)[:50]:
        try:
            uri = cast("call", registry, "tokenURI(uint256)(string)", str(i)).strip().strip('"')
            m = re.fullmatch(r"data:application/json;base64,([A-Za-z0-9+/=]{1,8000})", uri)
            n = json.loads(base64.b64decode(m.group(1))).get("name") if m else None
            if isinstance(n, str) and re.fullmatch(r"[\x20-\x7e]{1,60}", n):
                out[i] = n
        except Exception:
            pass
    return out


def build(payrun: str, names: dict[int, str], tag: str = "payrunv2") -> dict:
    n = int(cast("call", payrun, "runCount()(uint256)").split()[0])
    if n > 500:
        raise SystemExit(f"report_v2: runCount {n} looks wrong; refusing")
    items = []
    for rid in range(1, n + 1):
        out = cast("call", payrun, "linesOf(uint256)((uint256,address,uint128,bytes32,bytes32)[])", str(rid))
        for agent, payee, amount, h, ref in re.findall(r"\((\d+), (0x[0-9a-fA-F]{40}), (\d+)(?: \[[^\]]*\])?, (0x[0-9a-f]{64}), (0x[0-9a-f]{64})\)", out):
            r = ref_text(ref)
            items.append({"file": f"{tag}-run{rid}", "run_id": rid, "agent_id": int(agent), "registered_name": names.get(int(agent), f"agent #{agent}"),
                          "decision": "PAYABLE", "cop": "MATCH", "units": str(int(amount)), "invoice_hash": h,
                          "proposed": {"vendor": names.get(int(agent), ""), "wallet": payee, "amount": f"{Decimal(int(amount)) / Decimal(10**6):.2f}",
                                       "currency": "tUSD8", "reference": r, "due_date": None},
                          "evidence": {"note": ORIGIN.get(r, "Staged on chain by a test script; there is no invoice document for this line.")},
                          "reasons": [], "warnings": []})
        if not any(i["run_id"] == rid for i in items):
            raise SystemExit(f"report_v2: could not parse the lines of run {rid}")
    return {"payrun": payrun, "items": items}


def main(argv: list[str]) -> int:
    out = Path(argv[1]) if len(argv) > 1 and not argv[1].startswith("--") else APP / "docs/report-v2.json"
    if "--v3" in argv:
        t3 = json.loads(Path(os.environ.get("CLERK_V3PAGE") or APP / "e2e/testnet_v3page.json").read_text())
        for k in ("payrun_v3", "registry"):
            if not re.fullmatch(r"0x[0-9a-fA-F]{40}", str(t3.get(k, ""))):
                raise SystemExit(f"report_v2 --v3: testnet_v3page.json {k} is not an address")
        rep = build(t3["payrun_v3"], {}, "payrunv3")
        names = registry_names(t3["registry"], {i["agent_id"] for i in rep["items"]})
        for i in rep["items"]:
            n = names.get(i["agent_id"])
            if n:
                i["registered_name"] = n; i["proposed"]["vendor"] = n
    else:
        t1 = json.loads((APP / "e2e/testnet.json").read_text())
        t2 = json.loads((APP / "e2e/testnet_v2.json").read_text())
        names = {int(t1["acme_id"]): "Acme Supplies Ltd", int(t1["globex_id"]): "Globex Logistics"}
        rep = build(t2["payrun_v2"], names)
    if "--with" in argv:
        extra = json.loads(Path(argv[argv.index("--with") + 1]).read_text())
        if extra["payrun"].lower() != rep["payrun"].lower():
            raise SystemExit("report_v2: --with report is for another contract")
        runs = {i["run_id"] for i in extra["items"] if i.get("run_id")}
        rep["items"] = [i for i in rep["items"] if i["run_id"] not in runs] + extra["items"]
    out.write_text(json.dumps(rep, indent=1))
    print(f"report_v2: {out}: {len({i['run_id'] for i in rep['items'] if i.get('run_id')})} run(s), {len(rep['items'])} line(s) on {rep['payrun']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
