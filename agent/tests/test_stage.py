import os, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from check import Registry
from stage import Directory, extract_rules, invoice_key, load_policy, plan, read_invoice

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

    def test_po_book_holds_an_amount_edited_invoice(self):
        with tempfile.TemporaryDirectory() as d:
            pos = Path(d) / "pos.csv"
            pos.write_text("agent_id,po,amount\n7,PO-55,100.00\n99,PO-56,120.00\n")   # agent 99 is not a known vendor: ignored
            pol = load_policy(DIRECTORY, str(pos), None)
            self.assertEqual(set(pol.purchase_orders), {"Acme Supplies Ltd"})
            f = Path(d) / "a.txt"
            f.write_text(BODY.format(ref="Invoice no: INV-7", tail="PO number: PO-55"))   # invoice says 120.00, the PO 100.00
            item = plan(None, None, [f], DIRECTORY, "rules", pol)[0]
        self.assertEqual(item.decision, "HOLD")
        self.assertIn("differs from the purchase order", " ".join(item.reasons))

    @staticmethod
    def _pdf(lines: list[str]) -> bytes:
        """A minimal one-page PDF with a text layer (Helvetica), written by hand so the test needs no PDF library."""
        esc = lambda t: t.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
        stream = "BT /F1 11 Tf 50 780 Td 14 TL " + " ".join(f"({esc(l)}) Tj T*" for l in lines) + " ET"
        objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 842] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
                f"<< /Length {len(stream)} >>\nstream\n{stream}\nendstream", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
        out, offs = b"%PDF-1.4\n", []
        for i, o in enumerate(objs, 1):
            offs.append(len(out))
            out += f"{i} 0 obj\n{o}\nendobj\n".encode()
        xref = len(out)
        out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode() + b"".join(f"{o:010d} 00000 n \n".encode() for o in offs)
        return out + f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()

    def test_pdf_invoice_is_read_and_checked(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "inv.pdf"
            f.write_bytes(self._pdf(BODY.format(ref="Invoice no: INV-1001", tail="").splitlines()))
            raw, text = read_invoice(f)
            self.assertIn("INV-1001", text)
            item = plan(None, None, [f], DIRECTORY, "rules")[0]
        self.assertEqual(item.decision, "PAYABLE", item.reasons)
        self.assertEqual(item.units, 120_000_000)

    def test_pdf_without_text_layer_fails_closed(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "scan.pdf"
            f.write_bytes(self._pdf([]))
            item = plan(None, None, [f], DIRECTORY, "rules")[0]
        self.assertNotEqual(item.decision, "PAYABLE")


if __name__ == "__main__":
    unittest.main()
