#!/usr/bin/env bash
# Revert-control for the payee-change hold: switch parts of the feature off in src/PayRunV2.sol, run the unit suite,
# expect RED; restore the source byte for byte and expect GREEN. Exits non-zero if any mutant stays green or the
# restored suite is not all green.
#   script/hold_controls.sh [backup_dir]    (backup_dir default: a fresh mktemp dir under ./cache)
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src/PayRunV2.sol
BK="${1:-$(mktemp -d "$PWD/cache/holdctl.XXXXXX")}"
mkdir -p "$BK"; cp -p "$SRC" "$BK/PayRunV2.sol.orig"
SHA=$(sha256sum "$SRC" | cut -d' ' -f1)
restore() { cp -p "$BK/PayRunV2.sol.orig" "$SRC"; }
trap restore EXIT

counts() {  # prints "passed failed" from the forge summary line; empty on a compile error
  forge test --no-match-path 'test/fork/*' 2>&1 | tee "$BK/last.log" |
    sed -nE 's/.*: ([0-9]+) tests passed, ([0-9]+) failed.*/\1 \2/p' | tail -1
}

mutate() {  # name, python replacement script
  restore
  python3 - "$SRC" "$2" <<'EOF' || { echo "MUTATION $1 did not apply"; exit 3; }
import sys
p, rules = sys.argv[1], sys.argv[2]
s = open(p).read()
for pair in rules.split("\n@@\n"):
    a, b = pair.split("\n=>\n")
    if s.count(a) < 1: raise SystemExit(f"pattern not found: {a[:60]}")
    s = s.replace(a, b)
open(p, "w").write(s)
EOF
}

declare -A RULES
RULES[hold_off]='return wallet != address(0) && (wallet == p.trusted || (wallet == p.pending && block.timestamp >= p.releaseAt));
=>
return wallet != address(0);
@@
 || p.changes != m.epoch) reason
=>
) reason
@@
            else if (m.stagedOnHold && !(p.confirmed && p.trusted == l.payee)) reason = BLOCK_NEEDS_CONFIRMATION;
=>
'
RULES[flipback_restores_known]='            from = p.trusted;
            p.trusted = address(0);
            p.confirmed = false;
=>
            from = p.trusted;
'
RULES[clerk_can_confirm]='function confirmPayee(uint256 agentId, address wallet) external onlyOwner {
=>
function confirmPayee(uint256 agentId, address wallet) external {
'
RULES[wait_releases_staged_on_hold]='            else if (m.stagedOnHold && !(p.confirmed && p.trusted == l.payee)) reason = BLOCK_NEEDS_CONFIRMATION;
=>
'
RULES[no_change_since_staging_check]='            if (reg != l.payee || p.changes != m.epoch) reason = BLOCK_CHANGED_SINCE_STAGING;
=>
            if (reg != l.payee) reason = BLOCK_CHANGED_SINCE_STAGING;
'

rc=0
for name in hold_off flipback_restores_known clerk_can_confirm wait_releases_staged_on_hold no_change_since_staging_check; do
  mutate "$name" "${RULES[$name]}"
  c=$(counts); p=${c% *}; f=${c#* }
  red=$(grep -E '^\[FAIL' "$BK/last.log" | sed -E 's/.*\] ([a-zA-Z_]+)\(.*/\1/' | sort -u | tr '\n' ' ')
  if [ -z "$c" ]; then echo "MUTANT $name: COMPILE ERROR"; rc=1
  elif [ "$f" -gt 0 ]; then echo "MUTANT $name: RED passed=$p failed=$f :: $red"
  else echo "MUTANT $name: STILL GREEN passed=$p (control failed)"; rc=1; fi
done
restore; trap - EXIT
[ "$(sha256sum "$SRC" | cut -d' ' -f1)" = "$SHA" ] || { echo "RESTORE FAILED"; exit 2; }
c=$(counts); p=${c% *}; f=${c#* }
if [ -n "$c" ] && [ "$f" -eq 0 ] && [ "$p" -gt 0 ]; then echo "RESTORED: GREEN passed=$p failed=0 (source sha256 $SHA)"; else echo "RESTORED: NOT GREEN ($c)"; rc=1; fi
exit $rc
