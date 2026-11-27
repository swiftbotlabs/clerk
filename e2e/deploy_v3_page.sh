#!/usr/bin/env bash
# The approval page on PayRunV3 (vendor-signed invoices) with our own VendorRegistry, on Aevum TESTNET (or a local fork of it):
#   1) forge create PayRunV3(tUSD8, VendorRegistry 0x4289...46a1, owner = treasury = the Kernel smart account from testnet.json)
#   2) ONE Kernel UserOperation: tUSD8.approve(V3, 0.15), grantSession(clerk, 30 days, 0.10 per run, 0.20 per day),
#      setSignedOnly(Acme #1, true)
#   3) Acme (registry vendor #1; its registered wallet = the V3 eval's vendor1 key, which only SIGNS here) signs INV-3001
#      (sandbox/sign_invoice.mjs: EIP-712 over the line the clerk will extract; checkInvoice must say valid)
#   4) the clerk stages it with agent/stage.py --signed (stageSigned). Acme is new to this contract, so the run is HELD:
#      the page shows "Held: confirm the payee or reject"; the owner confirms and pays from the page (Demo Day, live).
# Gas: owner EOA ~0.004 tQDAY (deploy) + ~0.002 (handleOps, it is its own bundler); clerk ~0.0005. No tUSD8 moves until the owner pays.
#   KEYS=~/agent/secrets/aevum_testnet_keys.json VKEYS=~/agent/secrets/aevum_eval_keys_v3.json e2e/deploy_v3_page.sh
#   fork rehearsal: AEVUM_RPC=http://127.0.0.1:<port> [CHAIN=440050] ST=work/v3page-fork.json KEYS=... VKEYS=... e2e/deploy_v3_page.sh
# Keys are read in-process (never printed). Idempotent: every step's result is in $ST (default testnet_v3page.json); a re-run skips it.
set -euo pipefail
cd "$(dirname "$0")"
R=${AEVUM_RPC:-https://rpc-test.qday.info}; REG=${REG:-0x428981983c3aa672c27ea5a469e2d0e37dc646a1}; TUSD=0x456569838f1d43009A91ebA4263147Afd7233483
KEYS=${KEYS:?set KEYS to the testnet key file (owner = the Kernel signer, clerk)}; VKEYS=${VKEYS:?set VKEYS to the V3 eval key file (vendor1)}
ST=${ST:-testnet_v3page.json}; [ -f "$ST" ] || echo '{}' > "$ST"
ACME_ID=1; VROLE=vendor1
case "$R" in https://rpc-test.qday.info|http://127.0.0.1:*) ;; *) echo "RPC must be the public testnet RPC or a local fork"; exit 1;; esac
for f in "$KEYS" "$VKEYS"; do [ -f "$f" ] && [ ! -L "$f" ] || { echo "$f missing or a symlink"; exit 1; }; done
k() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['private_key'])" "$KEYS" "$1"; }
addr() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['address'])" "$KEYS" "$1"; }
get() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$ST" "$1"; }
put() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));d[sys.argv[2]]=sys.argv[3];json.dump(d,open(sys.argv[1],'w'),indent=1)" "$ST" "$1" "$2"; }
lc() { tr 'A-F' 'a-f'; }
[ "$(cast chain-id --rpc-url "$R")" = "${CHAIN:-44005}" ] || { echo "wrong chain"; exit 1; }   # CHAIN=440050: the page-check fork
OWNER=$(addr owner); CLERK=$(addr clerk)
TREAS=$(python3 -c "import json;print(json.load(open('testnet.json'))['kernel_account'])")
[ "$(cast call $REG 'getAgentWallet(uint256)(address)' $ACME_ID --rpc-url "$R" | lc)" != 0x0000000000000000000000000000000000000000 ] || { echo "Acme #$ACME_ID not in $REG"; exit 1; }
[ "$(cast call $REG 'tokenURI(uint256)(string)' $ACME_ID --rpc-url "$R" | wc -c)" -gt 20 ] || { echo "no registration file for #$ACME_ID"; exit 1; }
echo "owner EOA $OWNER tQDAY $(cast balance $OWNER --ether --rpc-url "$R"); treasury (Kernel) $TREAS tUSD8 $(cast call $TUSD 'balanceOf(address)(uint256)' $TREAS --rpc-url "$R"); registry $REG"

# 1) deploy
if [ -z "$(get payrun_v3)" ]; then
  out=$(cd ../contracts && forge create --legacy --broadcast --json --private-key "$(k owner)" --rpc-url "$R" src/PayRunV3.sol:PayRunV3 --constructor-args $TUSD $REG $TREAS $TREAS)
  put payrun_v3 "$(echo "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("data") or r; print(r["deployedTo"])')"
  put payrun_v3_deploy_tx "$(echo "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("data") or r; print(r["transactionHash"])')"
  put payrun_v3_block "$(cast receipt "$(get payrun_v3_deploy_tx)" blockNumber --rpc-url "$R")"
  put registry $REG
fi
V3=$(get payrun_v3); echo "PayRunV3 $V3 (deploy $(get payrun_v3_deploy_tx), block $(get payrun_v3_block))"
[ "$(cast code $V3 --rpc-url "$R" | wc -c)" -gt 100 ] || { echo "no code at $V3"; exit 1; }
[ "$(cast call $V3 'owner()(address)' --rpc-url "$R" | lc)" = "$(echo $TREAS | lc)" ] || { echo "owner is not the Kernel account"; exit 1; }
[ "$(cast call $V3 'registry()(address)' --rpc-url "$R" | lc)" = "$(echo $REG | lc)" ] || { echo "registry mismatch"; exit 1; }

# 2) one UserOperation from the owner's Kernel account: allowance, the clerk's session, Acme signs its invoices
if [ -z "$(get setup_tx)" ]; then
  source ./kernel.sh
  NOW=$(cast block latest --field timestamp --rpc-url "$R" | tr -d '[:space:]')
  put setup_tx "$(kernel_op "$R" "$(k owner)" $TREAS "$(kernel_batch \
    "$TUSD:$(cast calldata 'approve(address,uint256)' $V3 150000)" \
    "$V3:$(cast calldata 'grantSession(address,uint64,uint128,uint128)' $CLERK $((NOW + 30*86400)) 100000 200000)" \
    "$V3:$(cast calldata 'setSignedOnly(uint256,bool)' $ACME_ID true)")")"
fi
echo "setup (UserOperation) $(get setup_tx)"
[ "$(cast call $V3 'signedOnly(uint256)(bool)' $ACME_ID --rpc-url "$R")" = true ] || { echo "Acme is not signedOnly"; exit 1; }
[ "$(cast call $TUSD 'allowance(address,address)(uint256)' $TREAS $V3 --rpc-url "$R" | awk '{print $1}')" = 150000 ] || { echo "allowance is not 0.15"; exit 1; }
[ "$(cast call $V3 'sessions(address)(uint64,uint64,uint128,uint128,uint128,bool)' $CLERK --rpc-url "$R" | sed -n 3p | awk '{print $1}')" = 100000 ] || { echo "clerk session missing"; exit 1; }

# 3) the vendor signs its invoice; 4) the clerk stages it (stageSigned)
if [ -z "$(get stage_tx)" ]; then
  W=${WORK:-work/v3page}; rm -rf "$W" && mkdir -p "$W"
  ACME=$(cast call $REG 'getAgentWallet(uint256)(address)' $ACME_ID --rpc-url "$R")
  for f in invoices_v3page/*.txt; do sed "s/__ACME__/$ACME/" "$f" > "$W/$(basename "$f")"; done
  for f in "$W"/*.txt; do node ../sandbox/sign_invoice.mjs --keys "$VKEYS" --role $VROLE --payrun $V3 --agent $ACME_ID --invoice "$f" --rpc "$R"; done
  export AEVUM_RPC=$R AEVUM_REGISTRY=$REG CLERK_KEY=$(k clerk)
  python3 ../agent/stage.py stage --signed --invoices "$W" --vendors $ACME_ID --payrun $V3 --account env:CLERK_KEY --extractor rules --out "$W/report.json"
  unset CLERK_KEY
  RUN=$(python3 -c "import json,sys;r=json.load(open(sys.argv[1])).get('runs',[]);print(next((x['run_id'] for x in r if x.get('run_id')),''))" "$W/report.json")
  [ -n "$RUN" ] || { echo "nothing was staged (see $W/report.json)"; exit 1; }
  put stage_run "$RUN"; put stage_tx "$(python3 -c "import json,sys;r=json.load(open(sys.argv[1]))['runs'];print(next(x['tx'] for x in r if x.get('run_id')))" "$W/report.json")"
  RO=${REPORT_OUT:-reports/report-v3page.json}; mkdir -p "$(dirname "$RO")" && cp "$W/report.json" "$RO"   # build_pages.sh V3_WITH=e2e/$RO
fi
RUN=$(get stage_run); echo "run $RUN staged by the clerk (stageSigned) $(get stage_tx)"
CAN=$(cast call $V3 'canExecute(uint256)(bool,uint256,uint8,uint64)' $RUN --rpc-url "$R" | head -3 | tr '\n' ' ')
echo "canExecute($RUN): $CAN"
case "$CAN" in "false 0 1 "*|"false 0 2 "*) echo "V3 PAGE OK: run $RUN is HELD (new payee); confirm + pay from the approval page";;
  *) echo "V3 PAGE: run $RUN is not in the expected held state"; exit 1;; esac
