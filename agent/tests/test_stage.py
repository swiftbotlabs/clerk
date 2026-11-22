import os, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from check import Registry
from stage import Directory, extract_rules, invoice_key, plan

ACME = "0x" + "a" * 40
DIRECTORY = Directory(Registry({"Acme Supplies Ltd": ACME}), {"Acme Supplies Ltd": 7})
BODY = "INVOICE\nFrom: Acme Supplies Ltd\n{ref}\nDue: 5 Dec 2026\nAmount due: 120.00 tUSD8\nPay to: " + ACME + "\n{tail}"


class T(unittest.TestCase):
    def test_key_ignores_case_spaces_and_punctuation(self):
        self.assertEqual(invoice_key(7, "INV-1001"), invoice_key(7, "inv 1001"))
        self.assertEqual(invoice_key(7, "INV-1001"), invoice_key(7, "Inv1001"))

    def test_key_depends_on_vendor_and_number(self):
        self.assertNotEqual(invoice_key(7, "INV-1001"), invoice_key(8, "INV-1001"))
        self.assertNotEqual(invoice_key(7, "INV-1001"), invoice_key(7, "INV-1002"))

    def test_rules_extractor_writes_iso_dates(self):
        self.assertEqual(extract_rules(BODY.format(ref="Invoice no: INV-1", tail=""))["due_date"], "2026-12-05")

    def test_resent_copies_in_one_batch_are_staged_once(self):
        with tempfile.TemporaryDirectory() as d:
            files = []
            for name, ref, tail in [("a.txt", "Invoice no: INV-1001", ""),                        # original
                                    ("b.txt", "Invoice no: INV-1001", "REMINDER: now overdue"),   # different bytes
                                    ("c.txt", "Invoice: inv 1001", ""),                           # number re-typed
                                    ("d.txt", "Invoice no: INV-1002", "")]:                       # a different invoice
                p = Path(d) / name
                p.write_text(BODY.format(ref=ref, tail=tail))
                files.append(p)
            items = {i.file: i for i in plan(None, None, files, DIRECTORY, "rules")}
        self.assertTrue(all(i.decision == "PAYABLE" for i in items.values()), {f: i.reasons for f, i in items.items()})
        self.assertIsNone(items["a.txt"].skip)
        self.assertIn("duplicate of a.txt", items["b.txt"].skip)
        self.assertIn("duplicate of a.txt", items["c.txt"].skip)
        self.assertIsNone(items["d.txt"].skip)
        self.assertEqual(items["a.txt"].invoice_hash, invoice_key(7, "INV-1001"))


if __name__ == "__main__":
    unittest.main()
