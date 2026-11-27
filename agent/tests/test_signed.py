import json, os, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import stage
from check import Registry
from stage import Directory, Planned, due_yyyymmdd, proofs_arg, read_signature, signature_gate

ACME = "0x" + "a" * 40
DIRECTORY = Directory(Registry({"Acme Supplies Ltd": ACME}), {"Acme Supplies Ltd": 7})
SIG = "0x" + "11" * 65


class FakeChain:
    """Answers PayRunV3.checkInvoice like the contract: required per vendor, valid only for the signature it was told is good."""
    def __init__(self, required: bool, good: str):
        self.required, self.good, self.calls = required, good, []

    def call(self, to, sig, line, proof):
        self.calls.append((sig, line, proof))
        valid = proof.endswith("," + self.good + ")")
        return f"{'true' if self.required else 'false'}\n{'true' if valid else 'false'}"


def item(name: str) -> Planned:
    return Planned(name, "0x" + "22" * 32, {"reference": "INV-1", "due_date": "2026-12-05"}, "PAYABLE", "MATCH",
                   "Acme Supplies Ltd", 7, units=1_000_000)


class T(unittest.TestCase):
    def test_due_dates(self):
        self.assertEqual(due_yyyymmdd("2026-12-05"), 20261205)
        for bad in (None, "", "5 Dec 2026", "2026-12-5", "2026-12-05x"):
            self.assertEqual(due_yyyymmdd(bad), 0)

    def test_read_signature_fails_closed(self):
        with tempfile.TemporaryDirectory() as d:
            inv = Path(d) / "a.txt"; inv.write_text("x")
            side = Path(d) / "a.txt.sig.json"
            self.assertEqual(read_signature(inv), "")                     # none
            side.write_text(json.dumps({"signature": SIG})); self.assertEqual(read_signature(inv), SIG)
            for bad in ("{", json.dumps({"signature": "0x123"}), json.dumps({"signature": 5}), json.dumps(["x"]),
                        json.dumps({"signature": "0x" + "ab" * 3000})):
                side.write_text(bad); self.assertEqual(read_signature(inv), "", bad[:30])
            side.unlink(); real = Path(d) / "real.json"; real.write_text(json.dumps({"signature": SIG}))
            side.symlink_to(real); self.assertEqual(read_signature(inv), "", "symlink refused")

    def test_gate_holds_mismatch_and_missing(self):
        with tempfile.TemporaryDirectory() as d:
            for n, sig in (("good.txt", SIG), ("bad.txt", "0x" + "33" * 65), ("none.txt", None)):
                (Path(d) / n).write_text("x")
                if sig: (Path(d) / (n + ".sig.json")).write_text(json.dumps({"signature": sig}))
            items = [item("good.txt"), item("bad.txt"), item("none.txt")]
            signature_gate(FakeChain(True, SIG), "0xP", items, Path(d), DIRECTORY)
            self.assertEqual([i.decision for i in items], ["PAYABLE", "HOLD", "HOLD"])
            self.assertIn("does not match", items[1].reasons[-1]); self.assertIn("none came", items[2].reasons[-1])
            self.assertEqual(items[0].due, 20261205)
            self.assertEqual(proofs_arg([items[0]]), f"[(20261205,{SIG})]")
            # vendor that does not sign: an unsigned line passes, an attached bad signature is still held
            items = [item("none.txt"), item("bad.txt")]
            signature_gate(FakeChain(False, SIG), "0xP", items, Path(d), DIRECTORY)
            self.assertEqual([i.decision for i in items], ["PAYABLE", "HOLD"])
            self.assertEqual(proofs_arg([items[0]]), "[(20261205,0x)]")


if __name__ == "__main__":
    unittest.main()
