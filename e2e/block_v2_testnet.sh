#!/usr/bin/env bash
# Show a payment BLOCKED by the payee-change hold on Aevum TESTNET (chain 44005), with PayRunV2 from deploy_v2_testnet.sh:
#   1) one UserOperation from the Kernel owner (through QDay's bundler, bundler.qday.info): approve PayRunV2 for 1.00 tUSD8 + grant the clerk a staging-only session key on V2
#   2) the clerk stages one 0.10 tUSD8 line to Globex (#1699), a vendor V2 has never seen -> PayeeChanged + HoldStarted + StagedOnHold
#   3) the owner tries to pay it (UserOperation execute, also through the bundler) -> PaymentBlocked (reason 1 = BLOCK_HOLD); nothing is paid; the run stays staged
# Testnet gas only, no tUSD8 moves. Keys from $KEYS (TESTNET-ONLY, never printed). Idempotent: state in testnet_v2.json.
set -euo pipefail
cd "$(dirname "$0")"
R=${AEVUM_RPC:-https://rpc-test.qday.info}; REG=${REG:-0xF45E7f39Caba1d2055f613970575a7e7069636Be}; TUSD=${TUSD:-0x456569838f1d43009A91ebA4263147Afd7233483}
KEYS=${KEYS:?set KEYS to the JSON file of TESTNET-ONLY keys}; V1=${V1:-testnet.json}; ST=${ST:-testnet_v2.json}
k() { python3 -c "import json;print(json.load(open('$KEYS'))['$1']['private_key'])"; }
addr() { python3 -c "import json;print(json.load(open('$KEYS'))['$1']['address'])"; }
v1() { python3 -c "import json;print(json.load(open('$V1')).get('$1',''))"; }
get() { python3 -c "import json;print(json.load(open('$ST')).get('$1',''))"; }
put() { python3 -c "import json;d=json.load(open('$ST'));d['$1']='$2';json.dump(d,open('$ST','w'),indent=1)"; }
send() { local key=$1; shift; cast send --legacy --json --private-key "$(k $key)" --rpc-url $R "$@" | python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("data") or r; assert r.get("status") in ("0x1",1,"1"), r; print(r["transactionHash"])'; }
events() { cast receipt "$1" --json --rpc-url $R | python3 -c '
import json,sys,subprocess; r=json.load(sys.stdin)
sigs=["PayeeChanged(uint256,address,address,uint32)","HoldStarted(uint256,address,uint64)","StagedOnHold(uint256,uint256,uint256,address,uint64)",
 "Staged(uint256,address,uint256,uint256)","PaymentBlocked(uint256,uint256,uint256,address,uint8,uint64)","SessionGranted(address,uint64,uint128,uint128)",
 "UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)","Paid(uint256,uint256,bytes32,bytes32,uint256,address,uint256)"]
m={subprocess.check_output(["cast","keccak",s]).decode().strip():s.split("(")[0] for s in sigs}
out=[]
for l in r["logs"]:
    n=m.get(l["topics"][0])
    if n=="UserOperationEvent": n+=" success=%d"%int(l["data"][2+64:2+128],16)
    if n: out.append(n)
print(" ".join(out))'; }
CHAIN_OK=${CHAIN:-44005}; [ "$(cast chain-id --rpc-url $R)" = "$CHAIN_OK" ] || { echo "wrong chain"; exit 1; }
V2=$(get payrun_v2); [ -n "$V2" ] || { echo "run deploy_v2_testnet.sh first"; exit 1; }
TREAS=$(v1 kernel_account); GLOBEX_ID=${GLOBEX_ID:-$(v1 globex_id)}; CLERK=$(addr clerk); OWNER_KEY=$(k owner)
source ./kernel.sh
# The owner's UserOperations go through QDay's own bundler by default (BUNDLER= empty: the owner key submits handleOps itself).
BUNDLER=${BUNDLER-https://bundler.qday.info}
uop() { if [ -n "$BUNDLER" ]; then kernel_op_bundler $R $BUNDLER $OWNER_KEY $TREAS "$1"; else kernel_op $R $OWNER_KEY $TREAS "$1"; fi; }
NOW=$(cast block latest --field timestamp --rpc-url $R)
if [ -z "$(get block_grant_tx)" ]; then
  GRANT=$(cast calldata "grantSession(address,uint64,uint128,uint128)" $CLERK $((NOW+7*86400)) 500000 1000000)
  put block_grant_tx $(uop "$(kernel_batch "$TUSD:$(cast calldata 'approve(address,uint256)' $V2 1000000)" "$V2:$GRANT")")
fi
echo "grant (UserOp) $(get block_grant_tx): $(events $(get block_grant_tx))"
W=$(cast call $REG 'getAgentWallet(uint256)(address)' $GLOBEX_ID --rpc-url $R)
if [ -z "$(get block_stage_tx)" ]; then
  H=$(cast keccak "TESTNET-HOLD-DEMO G-80 Globex 0.10")
  REF=$(cast format-bytes32-string "G-80")
  put block_stage_tx $(send clerk $V2 'stage((uint256,address,uint128,bytes32,bytes32)[])' "[($GLOBEX_ID,$W,100000,$H,$REF)]")
  put block_run $(cast call $V2 'runCount()(uint256)' --rpc-url $R)
fi
RUN=$(get block_run); echo "stage $(get block_stage_tx) run $RUN: $(events $(get block_stage_tx))"
echo "canExecute($RUN): $(cast call $V2 'canExecute(uint256)(bool,uint256,uint8,uint64)' $RUN --rpc-url $R | tr '\n' ' ')"
if [ -z "$(get block_execute_tx)" ]; then
  B0=$(cast call $TUSD 'balanceOf(address)(uint256)' $W --rpc-url $R | awk '{print $1}')
  put block_execute_tx $(uop "$(kernel_single $V2 "$(cast calldata 'execute(uint256)' $RUN)")")
  B1=$(cast call $TUSD 'balanceOf(address)(uint256)' $W --rpc-url $R | awk '{print $1}')
  put block_globex_balance_change $((B1-B0))
fi
E=$(events $(get block_execute_tx)); echo "execute (UserOp) $(get block_execute_tx): $E"
echo "Globex balance change during execute: $(get block_globex_balance_change) (must be 0)"
echo "$E" | grep -q PaymentBlocked && ! echo "$E" | grep -q " Paid" && [ "$(get block_globex_balance_change)" = 0 ] && echo "BLOCK DEMO OK" || { echo "BLOCK DEMO FAILED"; exit 1; }
