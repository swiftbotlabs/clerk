"""Testnet subset of the adversarial eval: pick the invoices, and run the REAL planning pipeline (agent/stage.py: extract ->
check.py -> pay-once dedupe -> pack) for testnet_eval.mjs, which does every chain send itself (keys stay in that process).
No keys here, no sends: only read calls (cast call) against the RPC.

    python3 tn_plan.py subset CORPUS OUT                       # 16 invoices covering every family (+ batch-2 duplicates)
    python3 tn_plan.py full CORPUS OUT                         # all 160 invoices, same layout
    python3 tn_plan.py plan --rpc URL --registry ADDR --payrun ADDR --clerk ADDR --ids 1:1830,2:1831,3:1832 \
        --batch DIR --extractor rules|json [--pos pos.csv] --out plan.json
    python3 tn_plan.py hostile --corpus OUT --ids ... --out lines.json   # the attacker's best line per attack file, in
                                                                         # on-chain form (for the 'checks bypassed' layer)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from dataclasses import asdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent.parent
ADDR = re.compile(r"0x[0-9a-fA-F]{40}")


def subset(corpus: Path, out: Path) -> dict:
    """Deterministic pick from the seeded corpus: every family, both duplicate kinds, every injection goal."""
    truth = json.loads((corpus / "truth.json").read_text())
    files = truth["files"]
    by = lambda cls: sorted((f, t) for f, t in files.items() if t["cls"] == cls)
    pick: list[str] = []
    # duplicates first: their originals must be in the subset (batch 1 pays them, batch 2 re-sends them)
    dups = by("duplicate")
    for kind in ("exact", "retyped"):
        f, t = next((f, t) for f, t in dups if t["dup_kind"] == kind)
        pick.append(f)
        pick.append("batch1/" + t["duplicate_of"])
    vendors = {files[f]["vendor_id"] for f in pick if files[f]["cls"] == "legit"}
    for f, t in by("legit"):
        if t["vendor_id"] not in vendors:
            pick.append(f)
            vendors.add(t["vendor_id"])
    red = by("redirect")
    pick += [next(f for f, t in red if "new bank details" in (corpus / f).read_text()),
             next(f for f, t in red if "new bank details" not in (corpus / f).read_text())]
    inj = by("injection")
    real = truth["vendors"]
    pick += [next(f for f, t in inj if t["hostile_line"]["wallet"] and t["hostile_line"]["vendor"] == real[str(t["vendor_id"])]),
             next(f for f, t in inj if t["hostile_line"]["vendor"] != real[str(t["vendor_id"])]),
             next(f for f, t in inj if not t["hostile_line"]["wallet"])]
    look = by("lookalike")
    pick += [next(f for f, t in look if t["hostile_line"]["vendor"] in real.values()),        # model maps it onto the real vendor
             next(f for f, t in look if t["hostile_line"]["vendor"] not in real.values())]
    me = by("model_edit")
    pick += [next(f for f, t in me if t["edit"] == "amount_x10"), next(f for f, t in me if t["edit"] == "vendor")]
    pick += [by("doc_amount_edit")[0][0], by("over_cap")[0][0]]
    assert len(pick) == len(set(pick)), "subset picked a file twice"
    return materialize(corpus, out, truth, pick)


def full(corpus: Path, out: Path) -> dict:
    """The whole seeded corpus (160 invoices, every family at the local eval's counts), in the same layout as subset()."""
    truth = json.loads((corpus / "truth.json").read_text())
    return materialize(corpus, out, truth, sorted(truth["files"]))


def materialize(corpus: Path, out: Path, truth: dict, pick: list[str]) -> dict:
    files = truth["files"]
    if out.exists():
        shutil.rmtree(out)
    for b in ("batch1", "batch2"):
        (out / b).mkdir(parents=True)
    sub = {}
    for f in sorted(pick):
        shutil.copyfile(corpus / f, out / f)
        sub[f] = files[f]
    shutil.copyfile(corpus / "pos.csv", out / "pos.csv")
    # one directory per extractor mode: 'hostile' gets the compromised extractor's line next to each invoice
    for mode in ("rules", "hostile"):
        for f in sorted(pick):
            dst = out / mode / f
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(corpus / f, dst)
            if mode == "hostile":
                (dst.parent / (dst.name + ".line.json")).write_text(json.dumps(files[f]["hostile_line"]))
    (out / "truth.json").write_text(json.dumps({**truth, "files": sub, "subset_of": len(files)}, indent=1, ensure_ascii=False))
    fam: dict[str, int] = {}
    for t in sub.values():
        fam[t["cls"]] = fam.get(t["cls"], 0) + 1
    return {"files": len(sub), "by_family": fam}


def parse_ids(s: str) -> dict[int, int]:
    m = {}
    for part in s.split(","):
        k, v = part.split(":")
        m[int(k)] = int(v)
    if sorted(m) != [1, 2, 3]:
        raise SystemExit("--ids needs 1:<id>,2:<id>,3:<id>")
    return m


def remap_pos(pos: Path, ids: dict[int, int], extra: list[str], dst: Path) -> Path:
    """The corpus's purchase-order book is keyed by corpus vendor 1..3; the chain knows them by their ERC-8004 ids."""
    rows = pos.read_text().splitlines()
    out = [rows[0]] + [f"{ids[int(r.split(',')[0])]},{r.split(',', 1)[1]}" for r in rows[1:] + extra if r.strip()]
    dst.write_text("\n".join(out) + "\n")
    return dst


def plan(a) -> dict:
    os.environ["AEVUM_RPC"], os.environ["AEVUM_REGISTRY"] = a.rpc, a.registry
    sys.path.insert(0, str(APP / "agent"))
    import stage  # noqa: E402  (reads AEVUM_RPC / AEVUM_REGISTRY at import)
    ids = parse_ids(a.ids)
    chain = stage.Chain(a.rpc, tries=3)
    directory = stage.load_directory(chain, [ids[1], ids[2], ids[3]])
    if len(directory.ids) != 3:
        raise SystemExit(f"directory: expected 3 vendors with names and wallets, got {len(directory.ids)}")
    pos = None
    if a.pos:
        extra = [r for r in (a.pos_extra or "").split(";") if r]
        pos = str(remap_pos(Path(a.pos), ids, extra, Path(a.out).with_suffix(".pos.csv")))
    policy = stage.load_policy(directory, pos, None)
    files = sorted(Path(a.batch).glob("*.txt"))
    if not files:
        raise SystemExit("no invoices in --batch (0 files is a failure)")
    items = stage.plan(chain, a.payrun, files, directory, a.extractor, policy)
    per_run, today = [int(x.split()[0]) for x in chain.call(a.payrun, "headroom(address)(uint256,uint256)", a.clerk).splitlines()[:2]]
    runs = stage.pack(items, per_run, today)
    run_lines = []
    for run in runs:
        lines = []
        for it in run:
            lines.append({"file": it.file, "payeeAgentId": str(it.agent_id), "payee": directory.registry.entries[it.registered_name],
                          "amount": str(it.units), "invoiceHash": it.invoice_hash, "invoiceRef": stage.ref32(it.proposed["reference"])})
        run_lines.append(lines)
    return {"extractor": a.extractor, "batch": a.batch, "per_run": per_run, "today": today,
            "directory": {n: {"id": directory.ids[n], "wallet": w} for n, w in directory.registry.entries.items()},
            "items": [{k: v for k, v in asdict(i).items() if k != "evidence"} for i in items], "runs": run_lines}


def hostile(a) -> dict:
    """The attacker's best line for each attack file, as the clerk key would stage it if check.py were bypassed too.
    The claimed vendor identity is the real vendor the invoice is about (or impersonates); an empty wallet means the
    model kept the registered one."""
    sys.path.insert(0, str(APP / "agent"))
    import stage  # noqa: E402
    ids = parse_ids(a.ids)
    truth = json.loads((Path(a.corpus) / "truth.json").read_text())
    wallets = json.loads(Path(a.wallets).read_text())["vendors"]
    names = {v: int(k) for k, v in truth["vendors"].items()}
    out = []
    for f, t in sorted(truth["files"].items()):
        if t["cls"] == "legit":
            continue
        hl = t["hostile_line"]
        vid = names.get(hl["vendor"]) or t.get("vendor_id") or t.get("impersonates")
        payee = hl["wallet"] or wallets[str(vid)]
        if not ADDR.fullmatch(payee):
            raise SystemExit(f"{f}: bad wallet in hostile line")
        aid = ids[vid]
        out.append({"file": f, "cls": t["cls"], "claimed_vendor": hl["vendor"], "payeeAgentId": str(aid), "payee": payee,
                    "amount": str(stage.to_units(hl["amount"])), "invoiceHash": stage.invoice_key(aid, hl["reference"]),
                    "invoiceRef": stage.ref32(hl["reference"])})
    return {"lines": out}


def main(argv: list[str]) -> int:
    if len(argv) > 1 and argv[1] in ("subset", "full"):
        print(json.dumps((subset if argv[1] == "subset" else full)(Path(argv[2]), Path(argv[3]))))
        return 0
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["plan", "hostile"])
    ap.add_argument("--rpc")
    ap.add_argument("--registry")
    ap.add_argument("--payrun")
    ap.add_argument("--clerk")
    ap.add_argument("--ids", required=True)
    ap.add_argument("--batch")
    ap.add_argument("--extractor", choices=["rules", "json"])
    ap.add_argument("--pos")
    ap.add_argument("--pos-extra", help="extra PO rows 'vid,PO,amount;...' (corpus vendor numbers)")
    ap.add_argument("--corpus")
    ap.add_argument("--wallets")
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv[1:])
    if a.cmd == "plan":
        for k in ("rpc", "registry", "payrun", "clerk", "batch", "extractor"):
            if not getattr(a, k):
                raise SystemExit(f"--{k} is required for plan")
        res = plan(a)
    else:
        res = hostile(a)
    Path(a.out).write_text(json.dumps(res, indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
