#!/usr/bin/env bash
# The real Clerk flow on Aevum TESTNET (chain 44005). Keys: TESTNET-ONLY wallets from $KEYS (never printed).
# Every step records its tx hash in testnet.json; re-running skips steps already done.
set -euo pipefail
cd "$(dirname "$0")"
R=${AEVUM_RPC:-https://rpc-test.qday.info}; REG=0xF45E7f39Caba1d2055f613970575a7e7069636Be; TUSD=0x456569838f1d43009A91ebA4263147Afd7233483
KEYS=${KEYS:-/home/agent/agent/secrets/aevum_testnet_keys.json}; ST=testnet.json; [ -f $ST ] || echo '{}' > $ST
k() { python3 -c "import json;print(json.load(open('$KEYS'))['$1']['private_key'])"; }
addr() { python3 -c "import json;print(json.load(open('$KEYS'))['$1']['address'])"; }
get() { python3 -c "import json;print(json.load(open('$ST')).get('$1',''))"; }
put() { python3 -c "import json;d=json.load(open('$ST'));d['$1']='$2';json.dump(d,open('$ST','w'),indent=1)"; }
send() { local key=$1; shift; ETH_PRIVATE_KEY=$(k $key) cast send --legacy --json --rpc-url $R "$@" | python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("data") or r; assert r.get("status") in ("0x1",1,"1"), r; print(r["transactionHash"])'; }
OWNER=$(addr owner); CLERK=$(addr clerk); ACME=$(addr vendor_acme); GLOBEX=$(addr vendor_globex)
echo "owner $OWNER tQDAY $(cast balance $OWNER --ether --rpc-url $R) tUSD8 $(cast call $TUSD 'balanceOf(address)(uint256)' $OWNER --rpc-url $R)"
for who in clerk:$CLERK:0.15 vendor_acme:$ACME:0.05 vendor_globex:$GLOBEX:0.05; do IFS=: read n a v <<< "$who"
  [ -n "$(get gas_$n)" ] || put gas_$n $(send owner $a --value ${v}ether); done
reg() { local uri="data:application/json;base64,$(printf '{"type":"https://eips.ethereum.org/EIPS/eip-8004#registration-v1","name":"%s","description":"Clerk demo vendor"}' "$2" | base64 -w0)"
  ETH_PRIVATE_KEY=$(k $1) cast send --legacy --json --rpc-url $R $REG "register(string)" "$uri" \
  | python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("data") or r; print(r["transactionHash"], [int(l["topics"][3],16) for l in r["logs"] if len(l["topics"])==4][0])'; }
if [ -z "$(get acme_id)" ]; then read tx id <<< "$(reg vendor_acme 'Acme Supplies Ltd')"; put acme_register $tx; put acme_id $id; fi
if [ -z "$(get globex_id)" ]; then read tx id <<< "$(reg vendor_globex 'Globex Logistics')"; put globex_register $tx; put globex_id $id; fi
ACME_ID=$(get acme_id); GLOBEX_ID=$(get globex_id); echo "vendors: Acme #$ACME_ID, Globex #$GLOBEX_ID"
if [ -z "$(get payrun)" ]; then
  out=$(cd ../contracts && ETH_PRIVATE_KEY=$(k owner) forge create --legacy --broadcast --json --rpc-url $R src/PayRun.sol:PayRun --constructor-args $TUSD $REG $OWNER $OWNER)
  put payrun $(echo "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("data") or r; print(r["deployedTo"])')
  put payrun_deploy_tx $(echo "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("data") or r; print(r["transactionHash"])')
  put payrun_block $(cast receipt $(get payrun_deploy_tx) blockNumber --rpc-url $R)
fi
PAYRUN=$(get payrun); echo "PayRun $PAYRUN (block $(get payrun_block))"
NOW=$(cast block latest --field timestamp --rpc-url $R | tr -d '[:space:]')
[ -n "$(get grant_tx)" ] || put grant_tx $(send owner $PAYRUN "grantSession(address,uint64,uint128,uint128)" $CLERK $((NOW+7*86400)) 2500000 3000000)
[ -n "$(get approve_tx)" ] || put approve_tx $(send owner $TUSD "approve(address,uint256)" $PAYRUN 5000000)
rm -rf work reports && mkdir work reports
for f in invoices_testnet/*.txt; do sed "s/__ACME__/$ACME/; s/__GLOBEX__/$GLOBEX/; s/__MALLORY__/0x000000000000000000000000000000000000dEaD/g" $f > work/$(basename $f); done
export AEVUM_RPC=$R CLERK_KEY=$(k clerk)
python3 ../agent/stage.py stage --invoices work --vendors $ACME_ID,$GLOBEX_ID --payrun $PAYRUN --account env:CLERK_KEY --extractor ${EXTRACTOR:-rules} --out reports/report.json
unset CLERK_KEY
RUN=$(python3 -c "import json;r=json.load(open('reports/report.json')).get('runs',[]);print(next((x['run_id'] for x in r if x.get('run_id')),''))")
[ -n "$RUN" ] && put stage_run $RUN && put stage_tx $(python3 -c "import json;r=json.load(open('reports/report.json'))['runs'];print(next(x['tx'] for x in r if x.get('run_id')))")
[ -n "${STOP_BEFORE_EXEC:-}" ] && { echo "staged run ${RUN:-none}; stopped before execution (open web/index.html?report=... to approve)"; exit 0; }
RUN=${RUN:-$(get stage_run)}
[ -n "$(get execute_tx)" ] || put execute_tx $(send owner $PAYRUN "execute(uint256)" $RUN)
printf 'reference,agent_id,amount\nINV-1001,%s,1.20\nG-77,%s,0.80\nINV-1002,%s,0.95\n' $ACME_ID $GLOBEX_ID $ACME_ID > reports/ledger.csv
python3 ../agent/reconcile.py --payrun $PAYRUN --from-block $(get payrun_block) --ledger reports/ledger.csv --out reports/recon.json || true
cat $ST
