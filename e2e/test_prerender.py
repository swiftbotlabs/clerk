"""Unit tests for the approval page's server render (e2e/prerender.py) with a fake chain: no network.

    python3 -m unittest e2e/test_prerender.py

Covers the judge's page findings: the headline must count held runs and invoices to check (never "Nothing is waiting"
while something is held), amounts never run into the next word ("0.45 tUSD82 invoices"), every token label is tUSD8,
expired and unreadable runs say so plainly.
"""
import html
import json
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prerender  # noqa: E402

V1 = "0x2EE29a167CDDb964aAB9C899ea9Ae89847e3Da98"
V2 = "0x89d14Bf88D8dF1AB8b0F520414fbbC9e1d69F541"
NOW = 1_800_000_000
GLOBEX = "0xdA286b3Ad1f68d4e67a70417328743d013FC6B72"


def item(run, agent, name, units, ref, payrun_note=None):
    ev = {"note": payrun_note} if payrun_note else {"amount": f"Total {int(units) / 1e6:.2f}", "reference": "Invoice: " + ref, "due_date": "Due 2026-12-08"}
    return {"file": ref, "run_id": run, "agent_id": agent, "registered_name": name, "decision": "PAYABLE", "cop": "MATCH", "units": units,
            "proposed": {"vendor": name, "wallet": GLOBEX, "amount": f"{int(units) / 1e6:.2f}", "currency": "tUSD8", "reference": ref, "due_date": "2026-12-08"},
            "evidence": ev, "reasons": [], "warnings": []}


LOOKALIKE = {"file": "x.txt", "decision": "HOLD", "cop": "CLOSE_MATCH", "proposed": {"vendor": "Acme Suppiles Ltd", "amount": "0.45", "currency": "tUSD8"},
             "reasons": ["name is a close match"], "warnings": []}


class FakeChain:
    """runs[(payrun, id)] = (status, stagedAt); can[(payrun, id)] = (ok, line, reason, releaseAt) or None (v1: call reverts)."""
    def __init__(self, runs, can, unreadable=()):
        self.runs, self.can, self.unreadable = runs, can, set(unreadable)

    def __call__(self, *a, tries=3):
        if a[0] == "block":
            return str(NOW)
        if a[0] == "block-number":
            return "123"
        if a[0] == "receipt":
            return "1"
        if a[0] == "call":
            addr, sig, args = a[1], a[2], a[3:]
            k = (addr, int(args[0])) if args else None
            if sig.startswith("runs("):
                if k in self.unreadable:
                    raise RuntimeError("cast call: rpc down")
                st, at = self.runs[k]
                return f"{st}\n0x0000000000000000000000000000000000000001\n{at} [1e9]\n100000\n1"
            if sig.startswith("canExecute("):
                c = self.can.get(k)
                if c is None:
                    raise RuntimeError("cast call: execution reverted")
                return "\n".join(str(x).lower() for x in c)
            if sig.startswith("lineOf("):
                return f"(1699, {GLOBEX}, 100000 [1e5], 0x{'ab' * 32}, 0x{'cd' * 32})"
        raise AssertionError(f"unexpected cast {a}")


class Render(unittest.TestCase):
    def render(self, chain, v1_items, v2_items):
        work = Path(__file__).resolve().parent / "work"
        work.mkdir(exist_ok=True)
        d = Path(tempfile.mkdtemp(dir=work, prefix="prerender-test-"))
        self.addCleanup(shutil.rmtree, d, True)
        shutil_src = (Path(__file__).resolve().parent.parent / "web/index.html").read_text()
        (d / "index.html").write_text(shutil_src)
        (d / "report.json").write_text(json.dumps({"payrun": V1, "items": v1_items}))
        if v2_items is not None:
            (d / "report-v2.json").write_text(json.dumps({"payrun": V2, "items": v2_items}))
        old = prerender.cast
        prerender.cast = chain
        try:
            prerender.main(["prerender", str(d / "index.html")])
        finally:
            prerender.cast = old
        page = (d / "index.html").read_text()
        head = html.unescape(re.search(r'<h1 id="headline">(.*?)</h1>', page).group(1))
        text = html.unescape(re.sub(r"<[^>]+>", "", re.sub(r"<script.*?</script>|<style.*?</style>", "", page, flags=re.S)))
        return page, head, text

    def test_held_run_and_lookalike_are_counted(self):
        chain = FakeChain({(V1, 3): (2, NOW - 100), (V2, 1): (1, NOW - 100), (V2, 2): (1, NOW - 100)},
                          {(V2, 1): (False, 0, 2, NOW + 999), (V2, 2): (True, 0, 0, 0)})
        page, head, text = self.render(chain, [item(3, 1698, "Acme Supplies Ltd", "250000", "INV-1006"), item(3, 1699, "Globex Logistics", "200000", "G-79"), LOOKALIKE],
                                       [item(1, 1699, "Globex Logistics", "100000", "G-80", "test line"), item(2, 1698, "Acme Supplies Ltd", "100000", "P-1", "test line")])
        self.assertEqual(head, "1 pay run to approve, 1 held payment to confirm or reject, 1 invoice to check")
        self.assertIn("PayRunV2 run 1: Held: confirm the payee or reject", text)
        self.assertIn("Payment held.", text)
        self.assertIn("Registered wallet, on hold", text)
        # actionable runs first: the held V2 run comes before the paid v1 run
        self.assertLess(page.index("PayRunV2 run 1:"), page.index("PayRun run 3:"))

    def test_lookalike_alone_is_not_nothing_waiting(self):
        chain = FakeChain({(V1, 3): (2, NOW - 100)}, {})
        _, head, _ = self.render(chain, [item(3, 1698, "Acme Supplies Ltd", "450000", "INV-1"), LOOKALIKE], None)
        self.assertNotIn("Nothing is waiting", head)
        self.assertEqual(head, "1 invoice to check")

    def test_nothing_waiting_only_when_true(self):
        chain = FakeChain({(V1, 3): (2, NOW - 100)}, {})
        _, head, _ = self.render(chain, [item(3, 1698, "Acme Supplies Ltd", "450000", "INV-1")], None)
        self.assertEqual(head, "Nothing is waiting for you")

    def test_amounts_never_run_together_and_say_tusd8(self):
        chain = FakeChain({(V1, 3): (2, NOW - 100)}, {})
        _, _, text = self.render(chain, [item(3, 1698, "Acme Supplies Ltd", "250000", "INV-1006"), item(3, 1699, "Globex Logistics", "200000", "G-79"), LOOKALIKE], None)
        self.assertIn("0.45 tUSD8 · 2 invoices", text)
        self.assertIsNone(re.search(r"tUSD8\d", text), "an amount runs into the next number")
        self.assertIsNone(re.search(r"tUSD(?!8)", text), "a token label without the 8")
        self.assertIsNone(re.search(r"Ltdagent|confirmedInvoice|exactAcme", text), "words run together")

    def test_expired_and_unreadable_runs_say_so(self):
        chain = FakeChain({(V2, 1): (1, NOW - 8 * 86400), (V2, 2): (1, NOW - 100)}, {(V2, 2): (True, 0, 0, 0)}, unreadable=[(V2, 2)])
        _, head, text = self.render(chain, [], [item(1, 1699, "Globex Logistics", "100000", "G-80", "n"), item(2, 1698, "Acme Supplies Ltd", "100000", "P", "n")])
        self.assertIn("Expired: staged more than 7 days ago", text)
        self.assertIn("Could not read this run from the chain", text)
        self.assertEqual(head, "1 run that can no longer pay (reject it), 1 run could not be read from the chain")

    def test_page_keeps_csp_and_external_script(self):
        page = (Path(__file__).resolve().parent.parent / "web/index.html").read_text()
        self.assertRegex(page, r"Content-Security-Policy\" content=\"default-src 'none'; script-src 'self';")
        self.assertNotRegex(page, r"<script(?![^>]*\bsrc=)[^>]*>", "inline script would need 'unsafe-inline'")
        self.assertIn('id="howto"', page)


if __name__ == "__main__":
    unittest.main()
