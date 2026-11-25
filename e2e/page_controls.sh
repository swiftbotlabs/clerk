#!/usr/bin/env bash
# Planted controls for the approval-page fixes: each mutant breaks one fix; its test must go RED. Then the restored source must
# be GREEN. Sources are restored from a copy on exit, whatever happens.
#   KEYS=<testnet keys json> e2e/page_controls.sh       (PAGE_ONLY=unit skips the browser runs; ONLY="J2_x J3_y" runs only those mutants)
set -uo pipefail; cd "$(dirname "$0")/.."
B=$(mktemp -d e2e/work/controls-XXXX); cp web/app.js web/index.html e2e/prerender.py "$B/"
restore() { cp "$B/app.js" web/app.js; cp "$B/index.html" web/index.html; cp "$B/prerender.py" e2e/prerender.py; cp web/app.js docs/app.js; }
trap 'restore; rm -rf "$B"' EXIT
LOG=e2e/work/page-controls.log; : > "$LOG"
unit() { python3 -m unittest e2e/test_prerender.py >>"$LOG" 2>&1; }
hold() { PAGE=1 WORK=$PWD/e2e/work/hold bash e2e/hold_local.sh >>"$LOG" 2>&1; }
fork() { cp web/app.js docs/app.js; OUT=e2e/work bash e2e/page_fork.sh >>"$LOG" 2>&1; }
mut() {  # mut <name> <file> <old> <new> <test>
  local name=$1 f=$2 old=$3 new=$4 t=$5
  if [ -n "${ONLY:-}" ] && ! [[ " $ONLY " == *" $name "* ]]; then return; fi
  python3 - "$f" "$old" "$new" <<'PY' || { echo "MUTANT $name: anchor missing (control broken)"; FAILED=1; return; }
import sys; f, o, n = sys.argv[1:4]; s = open(f).read()
assert s.count(o) == 1, "anchor"; open(f, "w").write(s.replace(o, n))
PY
  echo "== $name" >>"$LOG"
  if $t; then echo "MUTANT $name: GREEN (control FAILED: the test did not catch it)"; FAILED=1; else echo "MUTANT $name: RED (caught)"; fi
  restore
}
FAILED=0
mut P1_check_not_counted e2e/prerender.py 'c["check"] = len(other("HOLD"))' 'c["check"] = 0' unit
mut P2_held_counted_as_pay e2e/prerender.py 'elif hold: c["held"] += 1;' 'elif hold: c["pay"] += 1;' unit
mut P3_amount_runs_together e2e/prerender.py '<small>· {plural' '<small>{plural' unit
mut P4_expired_ignored e2e/prerender.py 'expired = st == 1 and now > staged_at + RUN_TTL' 'expired = False' unit
mut P5_inline_script web/index.html '<script type="module" src="app.js"></script>' '<script type="module" src="app.js"></script><script>1</script>' unit
if [ "${PAGE_ONLY:-}" != unit ]; then
  mut J1_held_counted_as_pay web/app.js "c.held++; label = 'Held: confirm the payee or reject';" "c.pay++; label = 'Held: confirm the payee or reject';" hold
  mut J2_amount_runs_together web/app.js '${money(total)} <small>· ${plural' '${money(total)}<small>${plural' hold
  mut J3_confirm_not_gated web/app.js '` disabled data-agent=' '` data-agent=' hold
  mut J4_check_not_counted web/app.js "c.check = other('HOLD').length;" "c.check = 0;" fork
  mut J5_any_wallet_is_signer web/app.js "role = signer.toLowerCase() === account.toLowerCase() ?" "role = true ?" fork
fi
echo "== restored" >>"$LOG"
if unit && { [ "${PAGE_ONLY:-}" = unit ] || { hold && fork; }; }; then echo "RESTORED: GREEN"; else echo "RESTORED: RED"; FAILED=1; fi
exit $FAILED
