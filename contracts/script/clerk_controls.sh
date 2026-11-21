#!/usr/bin/env bash
# Revert-control for ClerkStagePolicy: switch each check off in src/ClerkStagePolicy.sol, run the policy tests (unit, and the
# Aevum fork suite when FORK=1), expect RED; restore byte for byte and expect GREEN. Non-zero exit if a mutant stays green.
#   script/clerk_controls.sh            unit tests only
#   FORK=1 script/clerk_controls.sh     also test/fork/ClerkPermissionFork.t.sol against https://rpc-test.qday.info
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src/ClerkStagePolicy.sol
BK="$(mktemp -d "$PWD/cache/clerkctl.XXXXXX")"
cp -p "$SRC" "$BK/orig"; SHA=$(sha256sum "$SRC" | cut -d' ' -f1)
restore() { cp -p "$BK/orig" "$SRC"; }
trap restore EXIT
run() {
  local out f=0
  out=$(forge build 2>&1); grep -q "Compiler run successful\|No files changed" <<<"$out" || { echo "COMPILE"; return; }
  out=$(forge test --match-path test/ClerkStagePolicy.t.sol 2>&1); grep -q "Suite result: ok" <<<"$out" || f=1
  if [ "${FORK:-0}" = 1 ]; then
    out=$(forge test --match-path test/fork/ClerkPermissionFork.t.sol --fork-url https://rpc-test.qday.info 2>&1)
    grep -q "Suite result: ok" <<<"$out" || f=1
  fi
  echo $f
}
mutate() { restore; python3 - "$SRC" "$2" "$3" <<'PY' || { echo "MUTATION $1 did not apply"; exit 3; }
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1: raise SystemExit("pattern count != 1")
open(p, "w").write(s.replace(a, b))
PY
  r=$(run)
  if [ "$r" = COMPILE ]; then echo "$1: does not compile (BAD control)"; bad=1
  elif [ "$r" = 1 ]; then echo "$1: RED (good)"; else echo "$1: still GREEN (BAD)"; bad=1; fi; }
bad=0
mutate allow_all 'if (callData.length < 4 || bytes4(callData[0:4]) != KERNEL_EXECUTE) return false;' 'return true;'
mutate no_mode_check 'if (mode != bytes32(0)) return false;' ''
mutate no_target_check 'target != payRun || ' ''
mutate no_selector_check ' || sel != PayRunV2.stage.selector' ''
mutate no_cap_check 'return total <= perRunCap;' 'return true;'
mutate no_expiry 'return uint256(c.validUntil) << 160;' 'return PASS;'
mutate no_value_check 'target != payRun || value != 0 ||' 'target != payRun ||'
mutate no_installed_check 'if (c.validUntil == 0) return FAIL;' ''
mutate no_paymaster_check 'if (userOp.paymasterAndData.length != 0) return FAIL;' ''
mutate no_fee_check 'if (maxFee > c.maxFeePerGas) return FAIL;' ''
mutate no_budget_check 'if (cost > c.gasBudget) return FAIL;' ''
mutate no_budget_spend 'c.gasBudget -= uint128(cost);' ''
mutate len_not_reduced 'mstore(args, sub(mload(exec), 56))' 'mstore(args, mload(exec))'
mutate no_max_lines 'if (n == 0 || n > MAX_LINES) return false;' 'if (n == 0) return false;'
restore
[ "$(sha256sum "$SRC" | cut -d' ' -f1)" = "$SHA" ] || { echo "restore mismatch"; exit 4; }
r=$(run); [ "$r" = 0 ] && echo "restored: GREEN" || { echo "restored: RED"; bad=1; }
exit $bad
