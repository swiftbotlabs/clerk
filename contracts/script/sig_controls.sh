#!/usr/bin/env bash
# Revert-control for vendor-signed invoices: switch parts of the check off in src/PayRunV3.sol, run the unit suite,
# expect RED; restore the source byte for byte and expect GREEN. Exits non-zero if any mutant stays green or the
# restored suite is not all green.
#   script/sig_controls.sh [backup_dir]    (backup_dir default: a fresh mktemp dir under ./cache)
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src/PayRunV3.sol
BK="${1:-$(mktemp -d "$PWD/cache/sigctl.XXXXXX")}"
mkdir -p "$BK"; cp -p "$SRC" "$BK/PayRunV3.sol.orig"
SHA=$(sha256sum "$SRC" | cut -d' ' -f1)
restore() { cp -p "$BK/PayRunV3.sol.orig" "$SRC"; }
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
RULES[signed_only_off]='            } else if (signedOnly[l.payeeAgentId]) {
                revert VendorSignatureRequired(i, l.payeeAgentId);
            }
=>
            }
'
RULES[any_signature_ok]='    function _signedBy(address wallet, bytes32 digest, bytes memory sig) internal view returns (bool) {
=>
    function _signedBy(address wallet, bytes32 digest, bytes memory sig) internal view returns (bool) {
        if (sig.length > 0) return true;
'
RULES[amount_not_signed]='            l.payeeAgentId, l.payee, l.amount, l.invoiceHash, dueDate))));
=>
            l.payeeAgentId, l.payee, uint128(0), l.invoiceHash, dueDate))));
'
RULES[due_date_not_signed]='            l.payeeAgentId, l.payee, l.amount, l.invoiceHash, dueDate))));
=>
            l.payeeAgentId, l.payee, l.amount, l.invoiceHash, uint32(0)))));
'
RULES[invoice_not_signed]='            l.payeeAgentId, l.payee, l.amount, l.invoiceHash, dueDate))));
=>
            l.payeeAgentId, l.payee, l.amount, bytes32(0), dueDate))));
'
RULES[agent_not_signed]='            l.payeeAgentId, l.payee, l.amount, l.invoiceHash, dueDate))));
=>
            uint256(0), l.payee, l.amount, l.invoiceHash, dueDate))));
'
RULES[domain_unbound]='VERSION_HASH, block.chainid, address(this)));
=>
VERSION_HASH, uint256(0), address(0)));
'
RULES[high_s_accepted]='if (uint256(sv) <= HALF_N && (v == 27 || v == 28)) {
=>
if (v == 27 || v == 28) {
'
RULES[erc1271_any_reply]='return ok && ret.length >= 32 && bytes4(abi.decode(ret, (bytes32))) == ERC1271_MAGIC;
=>
return ok;
'

rc=0
for name in signed_only_off any_signature_ok amount_not_signed due_date_not_signed invoice_not_signed agent_not_signed domain_unbound high_s_accepted erc1271_any_reply; do
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
