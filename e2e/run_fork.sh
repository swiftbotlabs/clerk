#!/usr/bin/env bash
# End-to-end on a LOCAL FORK of Aevum testnet (real ERC-8004 registry + real tUSD8; chain id 440050, nothing touches the real testnet).
set -euo pipefail
cd "$(dirname "$0")"
F=http://127.0.0.1:8555; REG=0xF45E7f39Caba1d2055f613970575a7e7069636Be; TUSD=0x456569838f1d43009A91ebA4263147Afd7233483
# anvil's PUBLIC test keys (fork only)
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # owner + treasury
K1=0x59c6995e998f97a5a0044966f0945389dc9c86dae88c7a8412f4603b6b78690d   # clerk session key
K2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9802cec3f019d   # Acme Supplies Ltd
K3=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6   # Globex Logistics
K4=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a   # mallory
A() { cast wallet address "$1"; }
OWNER=$(A $K0); CLERK=$(A $K1); ACME=$(A $K2); GLOBEX=$(A $K3); MALLORY=$(A $K4)
anvil --fork-url https://rpc-test.qday.info --hardfork shanghai --port 8555 --chain-id 440050 --silent & AP=$!
trap 'kill $AP 2>/dev/null' EXIT
until cast block-number --rpc-url $F >/dev/null 2>&1; do sleep 0.5; done
for a in $OWNER $CLERK $ACME $GLOBEX $MALLORY; do cast rpc anvil_setBalance $a 0x8AC7230489E80000 --rpc-url $F >/dev/null; done   # 10 tQDAY each (fork only)
reg() {  # register a vendor identity with an inline registration file; print its agentId (the minted tokenId)
  local uri="data:application/json;base64,$(printf '{"type":"https://eips.ethereum.org/EIPS/eip-8004#registration-v1","name":"%s","description":"vendor"}' "$2" | base64 -w0)"
  cast send --legacy --json --private-key "$1" $REG "register(string)" "$uri" --rpc-url $F \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("data") or r; print([int(l["topics"][3],16) for l in r["logs"] if len(l["topics"])==4][0])'
}
ACME_ID=$(reg $K2 "Acme Supplies Ltd"); GLOBEX_ID=$(reg $K3 "Globex Logistics")
echo "vendors: Acme #$ACME_ID $ACME, Globex #$GLOBEX_ID $GLOBEX"
cd ../contracts
PAYRUN=$(forge create --legacy --broadcast --json --rpc-url $F --private-key $K0 src/PayRun.sol:PayRun --constructor-args $TUSD $REG $OWNER $OWNER | python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("data") or r; print(r["deployedTo"])')
cd ../e2e
echo "PayRun $PAYRUN"
NOW=$(cast block latest --field timestamp --rpc-url $F | tr -d "[:space:]")
cast send --legacy --private-key $K0 $PAYRUN "grantSession(address,uint64,uint128,uint128)" $CLERK $((NOW+7*86400)) 500000000 800000000 --rpc-url $F >/dev/null
# fill the invoice fixtures with the fork's addresses
rm -rf work reports && mkdir work reports && for f in invoices/*.txt; do sed "s/__ACME__/$ACME/; s/__GLOBEX__/$GLOBEX/; s/__MALLORY__/$MALLORY/g" $f > work/$(basename $f); done
export AEVUM_RPC=$F CLERK_KEY=$K1
python3 ../agent/stage.py stage --invoices work --vendors $ACME_ID,$GLOBEX_ID --payrun $PAYRUN --account env:CLERK_KEY --out reports/report.json
echo "--- second pass (idempotency: nothing may be staged twice)"
python3 ../agent/stage.py stage --invoices work --vendors $ACME_ID,$GLOBEX_ID --payrun $PAYRUN --account env:CLERK_KEY --out reports/report2.json
echo "--- the clerk tries to execute its own run"
cast send --legacy --private-key $K1 $PAYRUN "execute(uint256)" 1 --rpc-url $F 2>&1 | grep -o "NotOwner\|0x30cd7471\|revert[^\n]*" | head -1 || true
echo "--- owner executes run 1 (treasury tUSD8 from a fork-only balance write)"
SLOT=""
for s in $(seq 0 20); do   # find tUSD8's balance mapping slot on the fork: write a probe value, read balanceOf back
  cast rpc anvil_setStorageAt $TUSD $(cast index address $OWNER $s) $(cast to-uint256 1000000000) --rpc-url $F >/dev/null
  if [ "$(cast call $TUSD 'balanceOf(address)(uint256)' $OWNER --rpc-url $F | awk '{print $1}')" = "1000000000" ]; then SLOT=$s; break; fi
  cast rpc anvil_setStorageAt $TUSD $(cast index address $OWNER $s) $(cast to-uint256 0) --rpc-url $F >/dev/null
done
echo "tUSD8 balance slot: ${SLOT:-not found}"
if [ -n "$SLOT" ]; then
  cast send --legacy --private-key $K0 $TUSD "approve(address,uint256)" $PAYRUN 1000000000 --rpc-url $F >/dev/null
  bal() { cast call $TUSD 'balanceOf(address)(uint256)' $1 --rpc-url $F | awk '{print $1}'; }
  a0=$(bal $ACME); g0=$(bal $GLOBEX); m0=$(bal $MALLORY)
  cast send --legacy --private-key $K0 $PAYRUN "execute(uint256)" 1 --rpc-url $F >/dev/null && echo executed
  echo "received (tUSD8 units): Acme +$(( $(bal $ACME) - a0 ))  Globex +$(( $(bal $GLOBEX) - g0 ))  Mallory +$(( $(bal $MALLORY) - m0 ))"
  echo "--- executing the same run again"
  cast send --legacy --private-key $K0 $PAYRUN "execute(uint256)" 1 --rpc-url $F 2>&1 | grep -o "custom error 0x[0-9a-f]*" | head -1 || true
fi
