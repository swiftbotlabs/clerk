"""Clerk staging flow: invoices in, a capped and checked pay run staged on Aevum, nothing paid without the owner.

    python3 stage.py plan  --invoices DIR --vendors 7,9,12 [--extractor rules|json]   # read-only: what would be staged and why
    python3 stage.py stage --invoices DIR --vendors 7,9,12 --account clerk-session    # stage the PAYABLE lines (session key)

Pipeline per invoice (each step fails closed):
  1. extract  : a proposed payment line {vendor, wallet, amount, currency, reference, due_date}. The extractor (an LLM with
                no tools, or the deterministic `rules` extractor used in tests) only PROPOSES; nothing it says is trusted.
  2. check    : check.py: every number/reference/date must appear in the source; the payee must be the vendor's ERC-8004
                registered wallet (Confirmation of Payee MATCH); otherwise HOLD or BLOCK.
  3. dedupe   : invoiceHash = keccak256(file bytes). Skipped if the chain says it is already paid or already in an open run.
  4. pack     : PAYABLE lines are packed into runs that fit the session key's headroom (per-run cap, what is left today).
  5. simulate : each run is simulated (eth_call from the session key) before it is sent; a revert is reported, not retried.
  6. send     : sent with retries; after a timeout we re-read stagedInRun for the run's first invoice before resending, so a
                retry can never stage the same invoice twice (the contract would refuse it anyway: AlreadyStaged).
Chain access goes through Foundry's `cast` (HTTPS RPC, legacy txs, as the Aevum kit recommends).
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check import Registry, Verdict, check_line  # noqa: E402

RPC = os.environ.get("AEVUM_RPC", "https://rpc-test.qday.info")
REGISTRY = os.environ.get("AEVUM_REGISTRY", "0xF45E7f39Caba1d2055f613970575a7e7069636Be")
DECIMALS = 6  # tUSD8
LINE_TUPLE = "(uint256,address,uint128,bytes32,bytes32)[]"
STAGED_TOPIC = "0x8400e17d532706ea458bde53c28cd26ebffe99def46f75abf218ce1c94d8b099"


# ------------------------------------------------------------------------------------------------ chain (cast)
class ChainError(RuntimeError):
    pass


class Chain:
    """Thin, retrying wrapper around `cast`. Reads retry on transport errors; a revert is never retried."""

    def __init__(self, rpc: str = RPC, tries: int = 3, backoff: float = 2.0):
        self.rpc, self.tries, self.backoff = rpc, tries, backoff

    def _cast(self, args: list[str], timeout: int = 60) -> str:
        last = ""
        for attempt in range(self.tries):
            try:
                p = subprocess.run(["cast", *args, "--rpc-url", self.rpc], capture_output=True, text=True, timeout=timeout)
            except subprocess.TimeoutExpired:
                last = "timeout"
            else:
                if p.returncode == 0:
                    return p.stdout.strip()
                last = (p.stderr or p.stdout).strip()
                if "revert" in last.lower() or "execution reverted" in last.lower():
                    raise ChainError(last[:600])
            time.sleep(self.backoff * (attempt + 1))
        raise ChainError(f"cast {' '.join(args[:2])} failed after {self.tries} tries: {last[:400]}")

    def call(self, to: str, sig: str, *args: str) -> str:
        return self._cast(["call", to, sig, *args])

    def call_from(self, sender: str, to: str, sig: str, *args: str) -> str:
        return self._cast(["call", "--from", sender, to, sig, *args])

    def send(self, account: str, to: str, sig: str, *args: str) -> dict:
        if account.startswith("env:"):   # local fork tests only: key from an env var (anvil's public test keys)
            auth = ["--private-key", os.environ[account[4:]]]
        else:
            auth = ["--account", account] + (["--password-file", os.environ["CLERK_PASSWORD_FILE"]] if os.environ.get("CLERK_PASSWORD_FILE") else [])
        out = self._cast(["send", "--legacy", "--json", *auth, to, sig, *args], timeout=180)
        d = json.loads(out)
        if isinstance(d, dict) and d.get("success") is False:   # newer cast wraps results: {success, data, errors}
            raise ChainError(json.dumps(d.get("errors"))[:600])
        return (d.get("data") or d) if isinstance(d, dict) else d


def keccak(data: bytes) -> str:
    out = subprocess.run(["cast", "keccak", "0x" + data.hex()], capture_output=True, text=True, check=True)
    return out.stdout.strip()


# ------------------------------------------------------------------------------------------------ vendor directory
@dataclass
class Directory:
    registry: Registry
    ids: dict[str, int]  # registered display name -> ERC-8004 agentId


def registration_name(token_uri: str) -> str | None:
    """Name from an ERC-8004 registration file given inline (data:application/json[;base64],...) or as raw JSON."""
    try:
        if token_uri.startswith("data:"):
            head, _, body = token_uri.partition(",")
            raw = base64.b64decode(body) if ";base64" in head else body.encode()
            doc = json.loads(raw)
        elif token_uri.lstrip().startswith("{"):
            doc = json.loads(token_uri)
        else:
            return None
        name = doc.get("name")
        return name.strip() if isinstance(name, str) and name.strip() else None
    except (ValueError, json.JSONDecodeError):
        return None


def load_directory(chain: Chain, agent_ids: list[int]) -> Directory:
    """Name and wallet of each vendor straight from the ERC-8004 registry. A vendor without a readable name is left out."""
    entries, ids = {}, {}
    for aid in agent_ids:
        uri = chain.call(REGISTRY, "tokenURI(uint256)(string)", str(aid)).strip('"')
        name = registration_name(uri.encode().decode("unicode_escape"))
        wallet = chain.call(REGISTRY, "getAgentWallet(uint256)(address)", str(aid))
        if name and re.fullmatch(r"0x[0-9a-fA-F]{40}", wallet) and int(wallet, 16) != 0:
            entries[name], ids[name] = wallet, aid
    return Directory(Registry(entries), ids)


# ------------------------------------------------------------------------------------------------ extraction
def extract_rules(text: str) -> dict:
    """Deterministic extractor for labelled invoices (tests, demo fixtures). Proposes; never trusted."""
    def grab(*labels: str) -> str | None:
        for lab in labels:
            m = re.search(rf"(?im)^\s*{lab}\s*[:#]\s*(.+?)\s*$", text)
            if m:
                return m.group(1)
        return None
    amount = grab("amount due", "total due", "total")
    m = re.search(r"([0-9][0-9.,]*)", amount or "")
    return {
        "vendor": grab("from", "vendor", "supplier") or "",
        "wallet": grab("pay to", "wallet", "payment address") or "",
        "amount": m.group(1) if m else "",
        "currency": "tUSD8",
        "reference": grab("invoice no", "invoice number", "invoice", "reference") or "",
        "due_date": grab("due date", "due") or "",
    }


def extract_json(path: Path) -> dict:
    """Pre-extracted line next to the invoice (<invoice>.line.json), e.g. written by the LLM extractor."""
    return json.loads(path.with_suffix(path.suffix + ".line.json").read_text())


# ------------------------------------------------------------------------------------------------ planning
@dataclass
class Planned:
    file: str
    invoice_hash: str
    proposed: dict
    decision: str
    cop: str
    registered_name: str | None
    agent_id: int | None
    reasons: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    units: int = 0
    skip: str | None = None  # already paid / already staged
    evidence: dict = field(default_factory=dict)
    run_id: int | None = None


def evidence(text: str, line: dict) -> dict:
    """The source line behind each proposed value, for the approval page (the owner sees WHERE each number came from)."""
    out = {}
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    for key in ("vendor", "amount", "reference", "due_date", "wallet"):
        val = str(line.get(key) or "").strip()
        if not val:
            continue
        probe = val.lower().replace(",", "")
        hit = next((l for l in lines if probe in l.lower().replace(",", "")), None)
        out[key] = hit[:160] if hit else None
    return out


def to_units(amount: str) -> int:
    d = Decimal(re.sub(r"[^\d.]", "", amount.replace(",", "")) or "0")
    return int((d * (10 ** DECIMALS)).to_integral_value())


def ref32(ref: str) -> str:
    b = ref.encode()[:32]
    return "0x" + b.hex().ljust(64, "0")


def plan(chain: Chain, payrun: str | None, invoices: list[Path], directory: Directory, extractor: str) -> list[Planned]:
    out = []
    for p in sorted(invoices):
        raw = p.read_bytes()
        text = raw.decode("utf-8", errors="replace")
        line = extract_rules(text) if extractor == "rules" else extract_json(p)
        v: Verdict = check_line(text, line, directory.registry)
        h = keccak(raw)
        item = Planned(p.name, h, line, v.decision, v.cop, v.registered_name,
                       directory.ids.get(v.registered_name) if v.registered_name else None, v.reasons, v.warnings,
                       evidence=evidence(text, line))
        if v.decision == "PAYABLE":
            item.units = to_units(line["amount"])
            if payrun:
                if int(chain.call(payrun, "paidInRun(bytes32)(uint256)", h).split()[0]) != 0:
                    item.skip = "already paid"
                elif int(chain.call(payrun, "stagedInRun(bytes32)(uint256)", h).split()[0]) != 0:
                    item.skip = "already staged"
        out.append(item)
    return out


def pack(items: list[Planned], per_run: int, today: int) -> list[list[Planned]]:
    """Greedy: biggest first, each run <= per_run, all runs together <= today's headroom, <= 25 lines a run.
    A line bigger than the per-run cap is never staged (it needs the owner)."""
    runs: list[list[Planned]] = []
    left = today
    cur, cur_total = [], 0
    for it in sorted((i for i in items if i.decision == "PAYABLE" and not i.skip), key=lambda i: -i.units):
        if it.units > per_run or it.units > left:
            it.skip = "over the session cap: needs the owner"
            continue
        if cur_total + it.units > per_run or len(cur) == 25:
            runs.append(cur)
            cur, cur_total = [], 0
        cur.append(it)
        cur_total += it.units
        left -= it.units
    if cur:
        runs.append(cur)
    return runs


def lines_arg(run: list[Planned], directory: Directory) -> str:
    parts = []
    for it in run:
        wallet = directory.registry.entries[it.registered_name]
        parts.append(f"({it.agent_id},{wallet},{it.units},{it.invoice_hash},{ref32(it.proposed['reference'])})")
    return "[" + ",".join(parts) + "]"


def stage_runs(chain: Chain, payrun: str, account: str, session_addr: str, runs: list[list[Planned]], directory: Directory) -> list[dict]:
    results = []
    for run in runs:
        arg = lines_arg(run, directory)
        sig = f"stage({LINE_TUPLE})(uint256)"
        try:
            chain.call_from(session_addr, payrun, sig, arg)  # simulate first: a revert here is final
        except ChainError as e:
            results.append({"files": [i.file for i in run], "status": "refused in simulation", "error": str(e)[:300]})
            continue
        try:
            receipt = chain.send(account, payrun, f"stage({LINE_TUPLE})", arg)
            run_id = next((int(l["topics"][1], 16) for l in receipt.get("logs", []) if l["topics"][0].lower() == STAGED_TOPIC), None)
            for i in run:
                i.run_id = run_id
            results.append({"files": [i.file for i in run], "status": "staged", "run_id": run_id, "tx": receipt.get("transactionHash")})
        except ChainError as e:
            # idempotency: did it land anyway?
            landed = int(chain.call(payrun, "stagedInRun(bytes32)(uint256)", run[0].invoice_hash).split()[0])
            results.append({"files": [i.file for i in run], "status": f"staged (run {landed}) after a send error" if landed else "send failed",
                            "error": str(e)[:300]})
    return results


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["plan", "stage"])
    ap.add_argument("--invoices", required=True)
    ap.add_argument("--vendors", required=True, help="comma-separated ERC-8004 agentIds of known vendors")
    ap.add_argument("--payrun", default=os.environ.get("PAYRUN"))
    ap.add_argument("--account", help="cast keystore account of the clerk's session key (stage only)")
    ap.add_argument("--extractor", choices=["rules", "json"], default="rules")
    ap.add_argument("--out", default="run_report.json")
    a = ap.parse_args(argv)
    chain = Chain()
    directory = load_directory(chain, [int(x) for x in a.vendors.split(",") if x.strip()])
    files = [p for p in Path(a.invoices).iterdir() if p.is_file() and p.suffix.lower() in (".txt", ".eml", ".csv", ".md")]
    items = plan(chain, a.payrun, files, directory, a.extractor)
    report: dict = {"payrun": a.payrun, "items": [asdict(i) for i in items]}
    if a.cmd == "stage":
        if not (a.payrun and a.account):
            ap.error("stage needs --payrun and --account")
        session = (subprocess.run(["cast", "wallet", "address", os.environ[a.account[4:]]], capture_output=True, text=True, check=True).stdout.strip()
                   if a.account.startswith("env:") else
                   subprocess.run(["cast", "wallet", "address", "--account", a.account], capture_output=True, text=True, check=True).stdout.strip())
        per_run, today = [int(x.split()[0]) for x in chain.call(a.payrun, "headroom(address)(uint256,uint256)", session).splitlines()[:2]]
        runs = pack(items, per_run, today)
        report["headroom"] = {"perRun": per_run, "today": today}
        report["runs"] = stage_runs(chain, a.payrun, a.account, session, runs, directory)
        report["items"] = [asdict(i) for i in items]
    Path(a.out).write_text(json.dumps(report, indent=1))
    for i in items:
        print(f"{i.decision:8} {i.cop:12} {i.file:28} {i.units / 10**DECIMALS:>10.2f} {i.skip or ''} {'; '.join(i.reasons)[:90]}")
    for r in report.get("runs", []):
        print("RUN", r["status"], r.get("tx", ""), ",".join(r["files"]), r.get("error", ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
