#!/usr/bin/env bash
# Keep a LIVE held run on the approval page's PayRunV3 (Aevum testnet), so judges never find only an expired one.
#
# Why this is needed: a staged run can be paid for RUN_TTL = 7 days only. A run staged while its payee was on hold stays held
# (canExecute reason 1, then 2 "needs your confirmation") until it expires. Every vendor in our VendorRegistry has already been
# seen by the page's PayRunV3, and Acme's first hold ran out, so a plain new stage for Acme would NOT be held. The contract starts a
# new hold only when it sees the registered wallet change. So each refresh does, in this order (all on testnet, ~0.001 tQDAY):
#   1. the owner's Kernel account rejects every run still open on the page's PayRunV3 (one UserOperation; frees nothing paid,
#      nothing was paid) - so the page shows ONE live held run, the older ones as "Rejected"
#   2. the registry owner (eval key 'owner' = VendorRegistry.owner) SUSPENDS Acme (#1): setAgentWallet(1, 0x0)
#   3. anyone calls observePayee(1) on the page's PayRunV3 (the clerk key pays): the contract records "no wallet"
#   4. the registry owner REINSTATES Acme's same wallet: setAgentWallet(1, <Acme wallet>). The registry ends exactly as it was;
#      the eval PayRunV3 contracts that share this registry never observed the 0x0 moment
#   5. Acme signs a fresh invoice INV-<3000+run> (sandbox/sign_invoice.mjs, EIP-712 checked by the contract's checkInvoice),
#      the clerk stages it with agent/stage.py --signed: the contract sees the reinstated wallet as a change -> new 24 h hold ->
#      the line is stagedOnHold -> the run needs the owner's confirmation until it expires 7 days later
#   6. e2e/reports/report-v3page.json gets the new run's invoice evidence; e2e/testnet_v3page.json records the txs;
#      docs/ is rebuilt (BUILD=0 skips); read-backs are printed. Deploying docs/ to Cloudflare is a separate step (TASK-r8).
#
#   KEYS=~/agent/secrets/aevum_testnet_keys.json EKEYS=~/agent/secrets/aevum_eval_keys_v3.json e2e/refresh_page_run.sh
#   fork: AEVUM_RPC=http://127.0.0.1:<port> CHAIN=440050 ST=<copy of testnet_v3page.json> REPORT=<copy> BUILD=0 ... (e2e/refresh_fork.sh)
# Keys are read in-process from the key files (never printed). Idempotent: an interrupted refresh resumes from the rf_* keys in
# $ST; if it dies while Acme is suspended, the EXIT trap reinstates Acme and the next run starts the hold restart again.
# Exit 0 only when the new run reads back HELD with stagedOnHold = true and the registry shows Acme's original wallet.
set -euo pipefail
cd "$(dirname "$0")"
R=${AEVUM_RPC:-https://rpc-test.qday.info}; TUSD=0x456569838f1d43009A91ebA4263147Afd7233483
KEYS=${KEYS:?set KEYS to the testnet key file (owner = the Kernel signer, clerk)}
EKEYS=${EKEYS:?set EKEYS to the V3 eval key file (owner = VendorRegistry owner, vendor1 = Acme)}
ST=${ST:-testnet_v3page.json}; REPORT=${REPORT:-reports/report-v3page.json}
ACME_ID=1; VROLE=vendor1; ZERO=0x0000000000000000000000000000000000000000
case "$R" in https://rpc-test.qday.info|http://127.0.0.1:*) ;; *) echo "RPC must be the public testnet RPC or a local fork"; exit 1;; esac
for f in "$KEYS" "$EKEYS" "$ST" "$REPORT"; do [ -f "$f" ] && [ ! -L "$f" ] || { echo "$f missing or a symlink"; exit 1; }; done
[ "$(cast chain-id --rpc-url "$R")" = "${CHAIN:-44005}" ] || { echo "wrong chain"; exit 1; }
k() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['private_key'])" "$KEYS" "$1"; }
ek() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['keys'][sys.argv[2]])" "$EKEYS" "$1"; }
addr() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['address'])" "$KEYS" "$1"; }
get() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$ST" "$1"; }
put() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));d[sys.argv[2]]=sys.argv[3];json.dump(d,open(sys.argv[1],'w'),indent=1)" "$ST" "$1" "$2"; }
lc() { tr 'A-F' 'a-f'; }
first() { awk 'NR==1{print $1}'; }
# send <key fn> <role> <to> <sig> [args]: legacy tx, waits for the receipt, fails unless status 1, prints the tx hash only
send() {
  local kf=$1 role=$2; shift 2
  cast send --legacy --json --private-key "$($kf "$role")" "$@" --rpc-url "$R" \
    | python3 -c 'import json,sys;r=json.load(sys.stdin);r=r.get("data") or r;assert r.get("status") in ("0x1",1,"1"),"tx failed";print(r["transactionHash"])'
}

V3=$(get payrun_v3); REG=$(get registry)
[[ "$V3" =~ ^0x[0-9a-fA-F]{40}$ && "$REG" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "$ST has no payrun_v3/registry"; exit 1; }
TREAS=$(python3 -c "import json;print(json.load(open('testnet.json'))['kernel_account'])")
OWNER=$(addr owner); CLERK=$(addr clerk)
REGOWNER=$(cast wallet address --private-key "$(ek owner)")
ACME=$(cast wallet address --private-key "$(ek $VROLE)")
[ "$(cast call $REG 'owner()(address)' --rpc-url "$R" | lc)" = "$(echo $REGOWNER | lc)" ] || { echo "eval key 'owner' is not the VendorRegistry owner"; exit 1; }
[ "$(cast call $V3 'owner()(address)' --rpc-url "$R" | lc)" = "$(echo $TREAS | lc)" ] || { echo "page PayRunV3 owner is not the Kernel account"; exit 1; }
[ "$(cast call $V3 'registry()(address)' --rpc-url "$R" | lc)" = "$(echo $REG | lc)" ] || { echo "page PayRunV3 registry mismatch"; exit 1; }
wallet_now() { cast call $REG 'getAgentWallet(uint256)(address)' $ACME_ID --rpc-url "$R" | lc; }
pending_now() { cast call $V3 'payees(uint256)(address,address,uint64,uint64,uint32,bool)' $ACME_ID --rpc-url "$R" | sed -n 2p | lc; }
case "$(wallet_now)" in "$(echo $ACME | lc)"|$ZERO) ;; *) echo "Acme #$ACME_ID's registered wallet is neither its key's address nor 0x0: stop"; exit 1;; esac
echo "refresh: PayRunV3 $V3, registry $REG, Acme $ACME (now $(wallet_now)), runCount $(cast call $V3 'runCount()(uint256)' --rpc-url "$R" | first)"
echo "  gas: owner EOA $(cast balance $OWNER --ether --rpc-url "$R"), clerk $(cast balance $CLERK --ether --rpc-url "$R"), registry owner $(cast balance $REGOWNER --ether --rpc-url "$R") tQDAY"

# If anything fails while Acme is suspended, put its wallet back (and forget the half-done hold restart, so a re-run redoes it).
restore() {
  local rc=$?
  if [ "$(wallet_now 2>/dev/null)" = $ZERO ] && [ -n "$(get rf_suspend_tx)" ]; then
    echo "!! failed while Acme is suspended: reinstating its wallet"
    if send ek owner $REG 'setAgentWallet(uint256,address)' $ACME_ID $ACME >/dev/null; then
      put rf_suspend_tx ""; put rf_observe_tx ""; echo "   reinstated; re-run this script to restart the hold"
    else echo "   REINSTATE FAILED: Acme is suspended in $REG; re-run this script now"; fi
  fi
  exit $rc
}
trap restore EXIT

[ -n "$(get rf_open)" ] || { put rf_open "$(date -u +%FT%H:%MZ)"; for x in rf_reject_tx rf_suspend_tx rf_observe_tx rf_reinstate_tx rf_fund_tx; do put $x ""; done; }

# 0. the registry owner needs gas for 2 txs (~0.0001 tQDAY): top it up from the owner EOA when below 0.0005
if python3 -c "import sys;sys.exit(0 if int(sys.argv[1])<5*10**14 else 1)" "$(cast balance $REGOWNER --rpc-url "$R")"; then
  put rf_fund_tx "$(send k owner $REGOWNER --value 0.002ether)"; echo "0. funded the registry owner with 0.002 tQDAY: $(get rf_fund_tx)"
fi

# 1. reject every run still open (status Staged) on the page's PayRunV3, in one UserOperation from the owner's Kernel account
N=$(cast call $V3 'runCount()(uint256)' --rpc-url "$R" | first)
OPEN=(); for ((i=1;i<=N;i++)); do [ "$(cast call $V3 'runs(uint256)(uint8,address,uint64,uint128,uint32)' $i --rpc-url "$R" | first)" = 1 ] && OPEN+=($i); done
if [ ${#OPEN[@]} -gt 0 ]; then
  source ./kernel.sh
  CALLS=(); for i in "${OPEN[@]}"; do CALLS+=("$V3:$(cast calldata 'reject(uint256,string)' $i 'superseded: a fresh demo run was staged')"); done
  put rf_reject_tx "$(kernel_op "$R" "$(k owner)" $TREAS "$(kernel_batch "${CALLS[@]}")")"
  echo "1. rejected open run(s) ${OPEN[*]} (UserOperation): $(get rf_reject_tx)"
else echo "1. no open run to reject"; fi
for ((i=1;i<=N;i++)); do [ "$(cast call $V3 'runs(uint256)(uint8,address,uint64,uint128,uint32)' $i --rpc-url "$R" | first)" != 1 ] || { echo "run $i is still open"; exit 1; }; done

# 2-4. hold restart: suspend Acme, let the page's PayRunV3 see it, reinstate the same wallet
if [ -z "$(get rf_reinstate_tx)" ]; then
  if [ -z "$(get rf_suspend_tx)" ]; then
    [ "$(wallet_now)" = "$(echo $ACME | lc)" ] || { echo "Acme is already suspended but this refresh did not do it: stop"; exit 1; }
    put rf_suspend_tx "$(send ek owner $REG 'setAgentWallet(uint256,address)' $ACME_ID $ZERO)"
  fi
  echo "2. Acme suspended in the registry: $(get rf_suspend_tx)"
  if [ "${REFRESH_FAIL_AFTER_SUSPEND:-0}" = 1 ] && [ "$R" != https://rpc-test.qday.info ]; then echo "   (fork control: failing on purpose while Acme is suspended)"; false; fi
  [ "$(wallet_now)" = $ZERO ] || { echo "Acme is not suspended"; exit 1; }
  if [ -z "$(get rf_observe_tx)" ]; then
    [ "${REFRESH_SKIP_OBSERVE:-0}" = 1 ] && [ "$R" != https://rpc-test.qday.info ] && echo "   (fork control: observe step SKIPPED)" \
      || put rf_observe_tx "$(send k clerk $V3 'observePayee(uint256)' $ACME_ID)"
  fi
  echo "3. the page's PayRunV3 observed the suspension: $(get rf_observe_tx)"
  [ "${REFRESH_SKIP_OBSERVE:-0}" = 1 ] || [ "$(pending_now)" = $ZERO ] || { echo "PayRunV3 did not record the suspension"; exit 1; }
  put rf_reinstate_tx "$(send ek owner $REG 'setAgentWallet(uint256,address)' $ACME_ID $ACME)"
fi
echo "4. Acme reinstated (same wallet): $(get rf_reinstate_tx)"
[ "$(wallet_now)" = "$(echo $ACME | lc)" ] || { echo "Acme's wallet is not back"; exit 1; }
trap - EXIT

# 5. Acme signs a fresh invoice, the clerk stages it (stageSigned)
NEXT=$(( $(cast call $V3 'runCount()(uint256)' --rpc-url "$R" | first) + 1 ))
NOW=$(cast block latest --field timestamp --rpc-url "$R" | tr -d '[:space:]')
W=${WORK:-work/refresh}; rm -rf "$W" && mkdir -p "$W"
INV="$W/inv-acme-$((3000 + NEXT)).txt"
python3 - "$INV" "$((3000 + NEXT))" "$NOW" "$ACME" <<'PY'
import sys, datetime as d
p, num, now, acme = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
day = d.datetime.fromtimestamp(now, d.timezone.utc).date()
open(p, "w").write(f"""ACME SUPPLIES LTD
Invoice No: INV-{num}
From: Acme Supplies Ltd
Bill to: Swift Bot Labs
Date: {day.isoformat()}
Due date: {(day + d.timedelta(days=21)).isoformat()}
Item: 1 x label printer ribbon, 0.05
Amount due: 0.05 tUSD8
Pay to: {acme}
""")
PY
node ../sandbox/sign_invoice.mjs --keys "$EKEYS" --role $VROLE --payrun $V3 --agent $ACME_ID --invoice "$INV" --rpc "$R"
export AEVUM_RPC=$R AEVUM_REGISTRY=$REG CLERK_KEY=$(k clerk)
python3 ../agent/stage.py stage --signed --invoices "$W" --vendors $ACME_ID --payrun $V3 --account env:CLERK_KEY --extractor rules --out "$W/report.json"
unset CLERK_KEY
RUN=$(python3 -c "import json,sys;r=json.load(open(sys.argv[1])).get('runs',[]);print(next((x['run_id'] for x in r if x.get('run_id')),''))" "$W/report.json")
TX=$(python3 -c "import json,sys;r=json.load(open(sys.argv[1]))['runs'];print(next(x['tx'] for x in r if x.get('run_id')))" "$W/report.json")
[ "$RUN" = "$NEXT" ] || { echo "nothing (or an unexpected run) was staged: see $W/report.json"; exit 1; }
echo "5. run $RUN staged by the clerk (stageSigned): $TX"

# 6. record it: state file, cumulative clerk report for the page
python3 - "$ST" "$RUN" "$TX" <<'PY'
import json, sys
p, run, tx = sys.argv[1], int(sys.argv[2]), sys.argv[3]
d = json.load(open(p))
rec = {k[3:]: d.pop(k) for k in list(d) if k.startswith("rf_")}
rec.update(run=run, stage_tx=tx)
d.setdefault("refreshes", []).append(rec)
d["last_refresh"] = rec
d["stage_run"], d["stage_tx"] = str(run), tx
json.dump(d, open(p, "w"), indent=1)
PY
python3 - "$REPORT" "$W/report.json" <<'PY'
import json, sys
dst, new = sys.argv[1], json.load(open(sys.argv[2]))
d = json.load(open(dst))
assert d["payrun"].lower() == new["payrun"].lower(), "report for another contract"
runs = {i["run_id"] for i in new["items"] if i.get("run_id")}
d["items"] = [i for i in d["items"] if i.get("run_id") not in runs] + [i for i in new["items"] if i.get("run_id")]
d["runs"] = [r for r in d.get("runs", []) if r.get("run_id") not in runs] + [r for r in new.get("runs", []) if r.get("run_id")]
d["headroom"] = new.get("headroom", d.get("headroom"))
json.dump(d, open(dst, "w"), indent=1)
print(f"report: {dst}: runs {sorted(i['run_id'] for i in d['items'] if i.get('run_id'))}")
PY

# read-backs (the gate)
RUNROW=$(cast call $V3 'runs(uint256)(uint8,address,uint64,uint128,uint32)' $RUN --rpc-url "$R")
STAGED_AT=$(echo "$RUNROW" | sed -n 3p | first)
CAN=$(cast call $V3 'canExecute(uint256)(bool,uint256,uint8,uint64)' $RUN --rpc-url "$R" | awk '{print $1}' | tr '\n' ' ')
META=$(cast call $V3 'lineMeta(uint256,uint256)(uint32,bool)' $RUN 0 --rpc-url "$R" | sed -n 2p)
PS=$(cast call $V3 'payeeStatus(uint256)(uint8,address,uint64,uint32)' $ACME_ID --rpc-url "$R" | awk '{print $1}' | tr '\n' ' ')
utc() { python3 -c "import sys,datetime as d;print(d.datetime.fromtimestamp(int(sys.argv[1]),d.timezone.utc).strftime('%Y-%m-%d %H:%MZ'))" "$1"; }
echo "read-back: run $RUN status $(echo "$RUNROW" | first) (1 = staged) stagedAt $(utc $STAGED_AT) -> payable until $(utc $((STAGED_AT + 7*86400)))"
echo "read-back: canExecute($RUN) = $CAN(want: false 0 1 <hold end>, later false 0 2)"
echo "read-back: lineMeta($RUN,0).stagedOnHold = $META; payeeStatus(Acme) = $PS(2 = held); registry wallet $(wallet_now)"
echo "read-back: open runs: $(for ((i=1;i<=RUN;i++)); do [ "$(cast call $V3 'runs(uint256)(uint8,address,uint64,uint128,uint32)' $i --rpc-url "$R" | first)" = 1 ] && printf '%s ' $i; done)(want: $RUN only)"
case "$CAN" in "false 0 1 "*|"false 0 2 "*) ;; *) echo "REFRESH FAIL: run $RUN is not held (reject it from the page and re-run)"; exit 1;; esac
[ "$META" = true ] || { echo "REFRESH FAIL: run $RUN was not staged on hold"; exit 1; }
[ "$(wallet_now)" = "$(echo $ACME | lc)" ] || { echo "REFRESH FAIL: registry wallet changed"; exit 1; }
if [ "${BUILD:-1}" = 1 ]; then
  (cd .. && V3_WITH=e2e/$REPORT e2e/build_pages.sh | tail -2)
  grep -q "PayRunV3 run $RUN: Held: confirm the payee or reject" ../docs/index.html || { echo "REFRESH FAIL: docs/index.html does not show run $RUN held"; exit 1; }
  echo "read-back: docs/index.html shows 'PayRunV3 run $RUN: Held'; $(grep -o '<h1 id="headline">[^<]*' ../docs/index.html | sed 's/.*>//')"
fi
echo "REFRESH OK: PayRunV3 run $RUN is HELD (Acme re-held after suspend/reinstate); payable until $(utc $((STAGED_AT + 7*86400))); next refresh before $(utc $((STAGED_AT + 6*86400)))"
