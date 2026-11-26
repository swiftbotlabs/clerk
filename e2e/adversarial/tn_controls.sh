#!/usr/bin/env bash
# Planted positive controls (P10) for the testnet eval (sandbox/testnet_eval.mjs). LOCAL anvil fork only.
# Needs: anvil --fork-url https://rpc-test.qday.info --port 18547 --chain-id 44005 --hardfork shanghai
# Usage: e2e/adversarial/tn_controls.sh WORKDIR        (log: WORKDIR/controls.log)
#   SET=full (default) or SET=subset picks the invoice set; ONLY="C1 C4" runs a selection.
#   C1 check_doc_off   the document check in agent/check.py is disabled -> the eval must go RED, scored from the chain
#                      (a fake or edited invoice paid), not from a crash
#   C2 funder_keep     the funder holds too little -> the eval must refuse BEFORE any send (0 txs)
#   C3 testnet_gate    --testnet with a non-public RPC -> refused
#   C4 redirect_rule_off  the registered-wallet rule in check.py always passes and the purchase-order book is off ->
#                      'new bank details' redirects get paid (to the vendor's wallet, for invoices nobody owes): RED, scored
#                      from the chain as fake invoices paid
#   C5 pay_once_off    stage.py's paid-on-chain lookup is off AND PayRunV2 is built without its AlreadyPaid check
#                      (mutant artifact) -> re-sent copies are paid twice: RED, scored from the chain as duplicates
#   GREEN              the restored source (sha checked) on fresh keys -> exit 0, 0 wrong outcomes
set -uo pipefail
APP=$(cd "$(dirname "$0")/../.." && pwd)
W=${1:?workdir}; mkdir -p "$W"; LOG="$W/controls.log"; : > "$LOG"
SET=${SET:-full}; ONLY=${ONLY:-"C1 C2 C3 C4 C5 GREEN"}
RPC=http://127.0.0.1:18547
EVAL="node $APP/sandbox/testnet_eval.mjs"
CHK="$APP/agent/check.py"; STG="$APP/agent/stage.py"
ORIG=$(cat "$CHK" "$STG" | sha256sum | cut -c1-16); cp "$CHK" "$W/check.py.orig"; cp "$STG" "$W/stage.py.orig"
restore() { cp "$W/check.py.orig" "$CHK"; cp "$W/stage.py.orig" "$STG"; }
trap restore EXIT
cast chain-id --rpc-url $RPC >/dev/null 2>&1 || { echo "no fork on $RPC" | tee -a "$LOG"; exit 2; }
echo "set=$SET only=$ONLY $(date -u +%FT%TZ)" | tee -a "$LOG"
fails=0
on() { [[ " $ONLY " == *" $1 "* ]]; }
keys() { rm -rf "$W/$1"; mkdir -p "$W/$1"; $EVAL --gen-keys "$W/$1/keys.json" >/dev/null
  node -e "const {generatePrivateKey}=require('$APP/sandbox/node_modules/viem/_cjs/accounts/index.js');require('fs').writeFileSync('$W/$1/funder.json',JSON.stringify({keys:{funder:generatePrivateKey()}}),{mode:0o600})"; }
run() { local d=$1; shift; (cd "$W/$d" && env FORK_FUNDER_TQDAY=${FORK_FUNDER_TQDAY_ALL:-0.4144} FORK_FUNDER_TUSD=3.3 "$@" timeout 3000 $EVAL --fork --set $SET --rpc $RPC --keys keys.json --funder-keys funder.json --state state.json --work run > run.log 2>&1); }
txs() { node -e "try{const s=require('$W/$1/state.json');console.log(s.txs.length)}catch{console.log(0)}"; }
cnt() { node -e "const r=require('$W/$1/run/report.json').result.score;const n=k=>r.hostile[k].length+r.rules[k].length;console.log(${2})" 2>/dev/null || echo NA; }
WRONG="n('fake_invoice_paid')+n('doc_amount_edit_paid')+n('wrong_payee')+n('wrong_amount')+n('duplicate_paid')+n('over_cap_paid')"
patch() { python3 -c "import sys;p,o,n=sys.argv[1:4];s=open(p).read();assert s.count(o)==1,'pattern';open(p,'w').write(s.replace(o,n))" "$@"; }
red() {   # name rc count what
  if [ "$2" -ne 0 ] && [ "$3" != NA ] && [ "$3" -gt 0 ]; then echo "$1: RED as expected (exit $2, $3 $4 scored from the chain)" | tee -a "$LOG"
  else echo "$1: NOT caught (exit $2, $4=$3)" | tee -a "$LOG"; fails=$((fails+1)); fi; }

if on C1; then   # document check off (HOLD never happens: a line with a failed value check becomes PAYABLE)
  keys c1
  if patch "$CHK" 'elif reasons or cop == "CLOSE_MATCH":' 'elif False:'; then run c1 EVAL_MARGIN_UNITS=100000000; rc=$?; restore; red "C1 check_doc_off" $rc "$(cnt c1 "$WRONG")" "wrong payments"
  else echo "C1: pattern missing (control invalid)" | tee -a "$LOG"; fails=$((fails+1)); fi
fi
if on C2; then   # funder below the keep floor
  keys c2
  run c2 FORK_FUNDER_TQDAY=0.35; rc=$?
  if [ $rc -ne 0 ] && grep -q "FUNDER_KEEP" "$W/c2/run.log" && [ "$(txs c2)" = 0 ]; then echo "C2 funder_keep: RED as expected (refused before any send)" | tee -a "$LOG"
  else echo "C2 funder_keep: NOT caught (exit $rc, txs $(txs c2))" | tee -a "$LOG"; fails=$((fails+1)); fi
fi
if on C3; then   # testnet mode on a non-public RPC
  keys c3
  (cd "$W/c3" && timeout 60 $EVAL --testnet --rpc $RPC --keys keys.json --funder-keys funder.json --state state.json --work run > run.log 2>&1); rc=$?
  if [ $rc -ne 0 ] && grep -q "testnet mode only talks to" "$W/c3/run.log"; then echo "C3 testnet_gate: RED as expected" | tee -a "$LOG"
  else echo "C3 testnet_gate: NOT caught (exit $rc)" | tee -a "$LOG"; fails=$((fails+1)); fi
fi
if on C4; then   # registered-wallet rule off + PO book off -> a redirect is paid
  keys c4
  if patch "$CHK" 'checks["wallet_is_registered_for_vendor"] = bool(reg_wallet) and wallet.lower() == reg_wallet.lower()' 'checks["wallet_is_registered_for_vendor"] = True'; then
    run c4 EVAL_MARGIN_UNITS=100000000 EVAL_NO_PO=1; rc=$?; restore
    red "C4 redirect_rule_off" $rc "$(cnt c4 "n('fake_invoice_paid')")" "fake invoices paid"
    node -e "const r=require('$W/c4/run/report.json');const t=require('$W/c4/run/subset/truth.json').files;const f=[...r.result.score.rules.fake_invoice_paid,...r.result.score.hostile.fake_invoice_paid].map(x=>x.file&&t[x.file]?.cls).filter(Boolean);const c={};f.forEach(x=>c[x]=(c[x]||0)+1);console.log('   C4 fake invoices paid by family:',JSON.stringify(c))" 2>/dev/null | tee -a "$LOG"
  else echo "C4: pattern missing (control invalid)" | tee -a "$LOG"; fails=$((fails+1)); fi
fi
if on C5; then   # pay-once off off-chain AND on-chain (mutant PayRunV2 without the AlreadyPaid check)
  keys c5
  MUT="$W/mut-alreadypaid"; rm -rf "$MUT"; mkdir -p "$MUT/lib"; cp -r "$APP/contracts/src" "$APP/contracts/foundry.toml" "$MUT/"
  if patch "$MUT/src/PayRunV2.sol" 'if (paid != 0) revert AlreadyPaid(i, l.invoiceHash, paid);' 'paid; // MUTANT' \
     && (cd "$MUT" && forge build --skip test --skip script >/dev/null 2>&1) \
     && patch "$STG" 'if int(chain.call(payrun, "paidInRun(bytes32)(uint256)", h).split()[0]) != 0:' 'if False:'; then
    run c5 EVAL_MARGIN_UNITS=100000000 EVAL_PAYRUN_ARTIFACT="$MUT/out/PayRunV2.sol/PayRunV2.json"; rc=$?; restore
    red "C5 pay_once_off" $rc "$(cnt c5 "n('duplicate_paid')")" "invoices paid twice"
  else restore; echo "C5: mutant build or pattern failed (control invalid)" | tee -a "$LOG"; fails=$((fails+1)); fi
fi
if on GREEN; then   # restored source, fresh keys
  [ "$(cat "$CHK" "$STG" | sha256sum | cut -c1-16)" = "$ORIG" ] || { echo "restore failed: check.py/stage.py sha differs" | tee -a "$LOG"; exit 1; }
  keys green
  run green; rc=$?
  n=$(cnt green "$WRONG")
  if [ $rc -eq 0 ] && [ "$n" = 0 ]; then echo "GREEN restored source: exit 0, 0 wrong payments ($(txs green) txs) $(grep -o 'DONE:.*' "$W/green/run.log")" | tee -a "$LOG"
  else echo "GREEN restored source: FAILED (exit $rc, wrong=$n)" | tee -a "$LOG"; fails=$((fails+1)); fi
fi
echo "controls: $fails failure(s)" | tee -a "$LOG"
exit $fails
