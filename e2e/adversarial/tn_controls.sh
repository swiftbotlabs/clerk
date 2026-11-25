#!/usr/bin/env bash
# Planted positive controls (P10) for the testnet subset eval (sandbox/testnet_eval.mjs). LOCAL anvil fork only.
# Needs: anvil --fork-url https://rpc-test.qday.info --port 18547 --chain-id 44005 --hardfork shanghai
# Usage: e2e/adversarial/tn_controls.sh WORKDIR        (log: WORKDIR/controls.log)
#   C1 check_doc_off   the document check in agent/check.py is disabled -> the eval must go RED, scored from the chain
#                      (a fake or edited invoice paid), not from a crash
#   C2 funder_keep     the funder holds too little -> the eval must refuse BEFORE any send (0 txs)
#   C3 testnet_gate    --testnet with a non-public RPC -> refused
#   GREEN              the restored source (sha checked) on fresh keys -> exit 0, 0 wrong outcomes
set -uo pipefail
APP=$(cd "$(dirname "$0")/../.." && pwd)
W=${1:?workdir}; mkdir -p "$W"; LOG="$W/controls.log"; : > "$LOG"
RPC=http://127.0.0.1:18547
EVAL="node $APP/sandbox/testnet_eval.mjs"
CHK="$APP/agent/check.py"
ORIG=$(sha256sum "$CHK" | cut -c1-16); cp "$CHK" "$W/check.py.orig"
restore() { cp "$W/check.py.orig" "$CHK"; }
trap restore EXIT
cast chain-id --rpc-url $RPC >/dev/null 2>&1 || { echo "no fork on $RPC" | tee -a "$LOG"; exit 2; }
fails=0
keys() { rm -rf "$W/$1"; mkdir -p "$W/$1"; $EVAL --gen-keys "$W/$1/keys.json" >/dev/null
  node -e "const {generatePrivateKey}=require('$APP/sandbox/node_modules/viem/_cjs/accounts/index.js');require('fs').writeFileSync('$W/$1/funder.json',JSON.stringify({keys:{funder:generatePrivateKey()}}),{mode:0o600})"; }
run() { local d=$1; shift; (cd "$W/$d" && env "$@" timeout 1500 $EVAL --fork --rpc $RPC --keys keys.json --funder-keys funder.json --state state.json --work run > run.log 2>&1); }
txs() { node -e "try{const s=require('$W/$1/state.json');console.log(s.txs.length)}catch{console.log(0)}"; }
wrong() { node -e "const r=require('$W/$1/run/report.json').result.score;const n=k=>r.hostile[k].length+r.rules[k].length;console.log(n('fake_invoice_paid')+n('doc_amount_edit_paid')+n('wrong_payee')+n('wrong_amount')+n('duplicate_paid'))" 2>/dev/null || echo NA; }

# C1: document check off (HOLD never happens: a line with a failed value check becomes PAYABLE)
keys c1
python3 -c "import sys;p=sys.argv[1];s=open(p).read();o='elif reasons or cop == \"CLOSE_MATCH\":';assert s.count(o)==1;open(p,'w').write(s.replace(o,'elif False:'))" "$CHK" \
  || { echo "C1: pattern missing (control invalid)" | tee -a "$LOG"; fails=$((fails+1)); }
run c1 EVAL_MARGIN_UNITS=1000000; rc=$?; restore
n=$(wrong c1)
if [ $rc -ne 0 ] && [ "$n" != NA ] && [ "$n" -gt 0 ]; then echo "C1 check_doc_off: RED as expected (exit $rc, $n wrong payments scored from the chain)" | tee -a "$LOG"
else echo "C1 check_doc_off: NOT caught (exit $rc, wrong=$n)" | tee -a "$LOG"; fails=$((fails+1)); fi

# C2: funder below the keep floor
keys c2
run c2 FORK_FUNDER_TQDAY=0.35; rc=$?
if [ $rc -ne 0 ] && grep -q "FUNDER_KEEP" "$W/c2/run.log" && [ "$(txs c2)" = 0 ]; then echo "C2 funder_keep: RED as expected (refused before any send)" | tee -a "$LOG"
else echo "C2 funder_keep: NOT caught (exit $rc, txs $(txs c2))" | tee -a "$LOG"; fails=$((fails+1)); fi

# C3: testnet mode on a non-public RPC
keys c3
(cd "$W/c3" && timeout 60 $EVAL --testnet --rpc $RPC --keys keys.json --funder-keys funder.json --state state.json --work run > run.log 2>&1); rc=$?
if [ $rc -ne 0 ] && grep -q "testnet mode only talks to" "$W/c3/run.log"; then echo "C3 testnet_gate: RED as expected" | tee -a "$LOG"
else echo "C3 testnet_gate: NOT caught (exit $rc)" | tee -a "$LOG"; fails=$((fails+1)); fi

# GREEN: restored source, fresh keys
[ "$(sha256sum "$CHK" | cut -c1-16)" = "$ORIG" ] || { echo "restore failed: check.py sha differs" | tee -a "$LOG"; exit 1; }
keys green
run green; rc=$?
n=$(wrong green)
if [ $rc -eq 0 ] && [ "$n" = 0 ]; then echo "GREEN restored source: exit 0, 0 wrong payments ($(txs green) txs)" | tee -a "$LOG"
else echo "GREEN restored source: FAILED (exit $rc, wrong=$n)" | tee -a "$LOG"; fails=$((fails+1)); fi
echo "controls: $fails failure(s)" | tee -a "$LOG"
exit $fails
