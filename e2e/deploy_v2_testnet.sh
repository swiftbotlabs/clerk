#!/usr/bin/env bash
# Deploy PayRunV2 (payee-change hold) on Aevum TESTNET (chain 44005) next to the v1 PayRun, and prove one hold on chain:
#   1) forge create PayRunV2(token, registry, owner = treasury = the Kernel smart account from testnet.json)
#   2) observePayee(Acme #1698) from the owner EOA  -> HoldStarted (Acme's wallet is new to V2)
#   3) confirmPayee(1698, Acme wallet) as a Kernel UserOperation -> PayeeConfirmed + HoldReleased (the owner's logged early release)
# Testnet gas only (~0.03-0.05 tQDAY from the owner EOA). Keys from $KEYS (TESTNET-ONLY, never printed). Idempotent: state in testnet_v2.json.
# testnet.json (the v1 run record) is read, never written.
set -euo pipefail
cd "$(dirname "$0")"
R=${AEVUM_RPC:-https://rpc-test.qday.info}; REG=${REG:-0xF45E7f39Caba1d2055f613970575a7e7069636Be}; TUSD=${TUSD:-0x456569838f1d43009A91ebA4263147Afd7233483}
KEYS=${KEYS:?set KEYS to the JSON file of TESTNET-ONLY keys}; V1=${V1:-testnet.json}; ST=${ST:-testnet_v2.json}; [ -f $ST ] || echo '{}' > $ST
k() { python3 -c "import json;print(json.load(open('$KEYS'))['$1']['private_key'])"; }
addr() { python3 -c "import json;print(json.load(open('$KEYS'))['$1']['address'])"; }
v1() { python3 -c "import json;print(json.load(open('$V1')).get('$1',''))"; }
get() { python3 -c "import json;print(json.load(open('$ST')).get('$1',''))"; }
put() { python3 -c "import json;d=json.load(open('$ST'));d['$1']='$2';json.dump(d,open('$ST','w'),indent=1)"; }
send() { local key=$1; shift; cast send --legacy --json --private-key "$(k $key)" --rpc-url $R "$@" | python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("data") or r; assert r.get("status") in ("0x1",1,"1"), r; print(r["transactionHash"])'; }
OWNER=$(addr owner); TREAS=${TREAS:-$(v1 kernel_account)}; ACME_ID=${ACME_ID:-$(v1 acme_id)}
[ "$(cast chain-id --rpc-url $R)" = "${CHAIN:-44005}" ] || { echo "wrong chain"; exit 1; }
[ -n "$TREAS" ] && [ -n "$ACME_ID" ] || { echo "kernel_account / acme_id missing in $V1"; exit 1; }
echo "owner EOA $OWNER tQDAY $(cast balance $OWNER --ether --rpc-url $R); treasury (Kernel) $TREAS; Acme #$ACME_ID"
if [ -z "$(get payrun_v2)" ]; then
  out=$(cd ../contracts && forge create --legacy --broadcast --json --private-key "$(k owner)" --rpc-url $R src/PayRunV2.sol:PayRunV2 --constructor-args $TUSD $REG $TREAS $TREAS)
  put payrun_v2 $(echo "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("data") or r; print(r["deployedTo"])')
  put payrun_v2_deploy_tx $(echo "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("data") or r; print(r["transactionHash"])')
fi
V2=$(get payrun_v2); echo "PayRunV2 $V2 deploy tx $(get payrun_v2_deploy_tx)"
[ "$(cast code $V2 --rpc-url $R | wc -c)" -gt 100 ] || { echo "no code at $V2"; exit 1; }
[ "$(cast call $V2 'owner()(address)' --rpc-url $R | tr A-F a-f)" = "$(echo $TREAS | tr A-F a-f)" ] || { echo "owner mismatch"; exit 1; }
echo "holdWindow $(cast call $V2 'holdWindow()(uint64)' --rpc-url $R) s"
[ -n "$(get observe_tx)" ] || put observe_tx $(send owner $V2 'observePayee(uint256)' $ACME_ID)
echo "observePayee tx $(get observe_tx); payeeStatus: $(cast call $V2 'payeeStatus(uint256)(uint8,address,uint64,uint32)' $ACME_ID --rpc-url $R 2>/dev/null | tr '\n' ' ')"
if [ -z "$(get confirm_tx)" ] && [ "${SKIP_CONFIRM:-0}" != 1 ]; then
  W=$(cast call $REG 'getAgentWallet(uint256)(address)' $ACME_ID --rpc-url $R)   # the registered wallet right now
  source ./kernel.sh
  put confirm_tx $(kernel_op $R $(k owner) $TREAS "$(kernel_single $V2 "$(cast calldata 'confirmPayee(uint256,address)' $ACME_ID $W)")")
fi
if [ "${SKIP_CONFIRM:-0}" != 1 ]; then
  echo "confirmPayee (UserOp) tx $(get confirm_tx)"
  cast receipt $(get confirm_tx) --json --rpc-url $R | python3 -c '
import json,sys,subprocess; r=json.load(sys.stdin); t0=[l["topics"][0] for l in r["logs"]]
want={subprocess.check_output(["cast","keccak",s]).decode().strip():s for s in ["PayeeConfirmed(uint256,address,address,uint64)","HoldReleased(uint256,address,bool)"]}
seen=[want[t] for t in t0 if t in want]; print("events:", seen); assert len(seen)==2, "PayeeConfirmed/HoldReleased missing (UserOp may have failed inside: check UserOperationEvent success)"'
  echo "payeeStatus after confirm: $(cast call $V2 'payeeStatus(uint256)(uint8,address,uint64,uint32)' $ACME_ID --rpc-url $R | tr '\n' ' ')"
fi
echo "V2 DEPLOY OK"
