"""reconcile(): ledger rows vs Paid events, including HELD rows from PayRunV2's PaymentBlocked events."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from reconcile import reconcile  # noqa: E402

LEDGER = [{"reference": "INV-1", "agent_id": "1", "amount": "120.00"},
          {"reference": "INV-2", "agent_id": "1", "amount": "50.00"},
          {"reference": "G-77", "agent_id": "2", "amount": "80.00"}]
PAID = [{"reference": "INV-1", "agent_id": 1, "units": 120_000_000, "run": 1, "tx": "0x1"}]


class ReconcileTest(unittest.TestCase):
    def test_v1_unpaid_without_hold_events(self):
        rows = {r["reference"]: r["status"] for r in reconcile(PAID, LEDGER)}
        self.assertEqual(rows, {"INV-1": "PAID_OK", "INV-2": "UNPAID", "G-77": "UNPAID"})

    def test_blocked_reference_is_held_with_reason(self):
        blocked = {"INV-2": {"run": 2, "reason": 1, "release_at": 1795283954, "tx": "0xb"}}
        rows = {r["reference"]: r for r in reconcile(PAID, LEDGER, blocked)}
        self.assertEqual(rows["INV-2"]["status"], "HELD")
        self.assertEqual(rows["INV-2"]["why"], "payee on hold")
        self.assertEqual(rows["G-77"]["status"], "UNPAID")
        self.assertEqual(rows["INV-1"]["status"], "PAID_OK")

    def test_paid_wins_over_an_older_block(self):
        blocked = {"INV-1": {"run": 1, "reason": 2, "release_at": 0, "tx": "0xb"}}
        rows = {r["reference"]: r["status"] for r in reconcile(PAID, LEDGER, blocked)}
        self.assertEqual(rows["INV-1"], "PAID_OK")


if __name__ == "__main__":
    unittest.main()
