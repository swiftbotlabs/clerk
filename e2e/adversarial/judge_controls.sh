#!/usr/bin/env bash
# Planted positive controls (P10) for sandbox/judge_rerun.mjs: each mutant copy of a report must make the judge rerun exit 1
# (MISMATCH), and the untouched report must exit 0. Read-only against the RPC the report was made on.
#   e2e/adversarial/judge_controls.sh WORKDIR [REPORT.json] [RPC]     (log: WORKDIR/judge-controls.log)
set -uo pipefail
APP=$(cd "$(dirname "$0")/../.." && pwd)
W=${1:?workdir}; REP=${2:-$APP/e2e/adversarial/testnet-eval.json}; RPC=${3:-https://rpc-test.qday.info}
mkdir -p "$W"; LOG="$W/judge-controls.log"; : > "$LOG"
J="node $APP/sandbox/judge_rerun.mjs --rpc $RPC"
fails=0
mutant() {   # name, node expression mutating `r`
  local name=$1 expr=$2 out="$W/mut-$1.json"
  node -e "const fs=require('fs');const r=JSON.parse(fs.readFileSync(process.argv[1]));$expr;fs.writeFileSync(process.argv[2],JSON.stringify(r))" "$REP" "$out" \
    || { echo "$name: mutation failed (control invalid)" | tee -a "$LOG"; fails=$((fails+1)); return; }
  cmp -s "$REP" "$out" && { echo "$name: mutant identical (control invalid)" | tee -a "$LOG"; fails=$((fails+1)); return; }
  local rc=2 try
  for try in 1 2 3; do $J --report "$out" > "$W/mut-$name.log" 2>&1; rc=$?; [ $rc -ne 2 ] && break; sleep 10; done   # 2 = RPC error, not a verdict
  if [ $rc -eq 1 ] && grep -q "JUDGE RERUN MISMATCH" "$W/mut-$name.log"; then echo "$name: RED as expected ($(grep -c '  MISMATCH' "$W/mut-$name.log") mismatch line(s))" | tee -a "$LOG"
  else echo "$name: NOT caught (exit $rc)" | tee -a "$LOG"; fails=$((fails+1)); fi
}
mutant J1_score_genuine  "r.result.score.rules.genuine_paid=Number(r.result.score.rules.genuine_paid)+1"
mutant J2_score_wrong    "r.result.score.hostile.wrong_payee=[{tx:'0x0',payee:'0x0'}]"
mutant J3_tx_status      "const t=r.txs.find(x=>x.status==='reverted');t.status='success'"
mutant J4_tx_sender      "const t=r.txs.find(x=>x.from==='clerk');t.from='owner'"
mutant J5_bypass_error   "const b=r.result.B.find(x=>x.hash);b.error.name=b.error.name==='AlreadyPaid'?'PayeeNotRegistered':'AlreadyPaid'"
mutant J6_payrun_swap    "const h=r.payruns.hostile;r.payruns.hostile=r.payruns.rules;r.payruns.rules=h"
mutant J7_swap_paid      "r.result.C[0].paid=1"
mutant J8_tx_dropped_paid "const t=r.result.A.rules.batch1.runs.find(x=>x.execute);t.paid=t.paid+1"
mutant J9_corpus_sha     "r.corpusSha='0'.repeat(64)"
mutant J10_attacker_bal  "const k=Object.keys(r.result.score.attacker_balances)[0];r.result.score.attacker_balances[k]='1'"
for try in 1 2 3; do $J --report "$REP" > "$W/green.log" 2>&1; rc=$?; [ $rc -ne 2 ] && break; sleep 10; done
if [ $rc -eq 0 ] && grep -q "JUDGE RERUN MATCH" "$W/green.log"; then echo "GREEN untouched report: exit 0, $(grep 'JUDGE RERUN' "$W/green.log")" | tee -a "$LOG"
else echo "GREEN untouched report: FAILED (exit $rc)" | tee -a "$LOG"; fails=$((fails+1)); fi
echo "judge controls: $fails failure(s)" | tee -a "$LOG"
exit $fails
