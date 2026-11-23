#!/usr/bin/env bash
# Demo Day "one attack, live on testnet": the clerk's own session key tries to stage a payment of a REAL vendor's invoice to an
# ATTACKER wallet (the "we have new bank details" fraud, as a fully compromised clerk would do it). PayRun checks every payee against
# the wallet the vendor registered for its ERC-8004 identity, so the chain refuses: PayeeNotRegistered. The failed tx is sent on purpose
# (explicit gas limit, no estimate) so the refusal is on the explorer, not just in a simulation. Testnet gas only; no tUSD8 can move.
# Usage (testnet, local agent):  KEYS=<testnet keys json> PAYRUN=<demo contract> e2e/attack_live.sh
#        (rehearsal on a local fork): RPC=http://127.0.0.1:18545 FORK=1 CLERK=<addr with a session on the fork> PAYRUN=... e2e/attack_live.sh
set -euo pipefail
cd "$(dirname "$0")"
R=${RPC:-https://rpc-test.qday.info}; REG=0xF45E7f39Caba1d2055f613970575a7e7069636Be; TUSD=0x456569838f1d43009A91ebA4263147Afd7233483
X=https://explorer-test.qday.info
PAYRUN=${PAYRUN:-0x89d14Bf88D8dF1AB8b0F520414fbbC9e1d69F541}
VENDOR_ID=${VENDOR_ID:-1698}           # Acme Supplies Ltd (registered in run_testnet.sh)
AMOUNT=${AMOUNT:-100000}               # 0.10 tUSD8
[ "$(cast chain-id --rpc-url $R)" = 44005 ] || { echo "wrong chain"; exit 1; }
if [ "${FORK:-0}" = 1 ]; then CLERK=${CLERK:?}; AUTH=(--unlocked --from $CLERK)
else KEYS=${KEYS:?set KEYS}; CK=$(python3 -c "import json;print(json.load(open('$KEYS'))['clerk']['private_key'])"); CLERK=$(cast wallet address --private-key "$CK"); AUTH=(--private-key "$CK"); fi
REGISTERED=$(cast call $REG "getAgentWallet(uint256)(address)" $VENDOR_ID --rpc-url $R)
ATTACKER=${ATTACKER:-$(cast wallet new --json | python3 -c 'import json,sys;d=json.load(sys.stdin);d=d.get("data",d);d=d[0] if isinstance(d,list) else d;print(d["address"])')}
N=$(date -u +%m%d%H%M%S)
HASH=$(cast keccak "attack-demo-$N"); REF=$(cast format-bytes32-string "INV-$N")
LINES="[($VENDOR_ID,$ATTACKER,$AMOUNT,$HASH,$REF)]"
SIG="stage((uint256,address,uint128,bytes32,bytes32)[])"
echo "vendor #$VENDOR_ID registered wallet: $REGISTERED"
echo "invoice asks to pay:          $ATTACKER   (attacker, $(python3 -c "print($AMOUNT/1e6)") tUSD8)"
echo "staged by the clerk's key:    $CLERK"
# 1) what the chain will say (simulation from the clerk's address)
SIM=$(cast call $PAYRUN "$SIG" "$LINES" --from $CLERK --rpc-url $R 2>&1 || true)
ERR=$(grep -o '0x[0-9a-fA-F]\{8,\}' <<<"$SIM" | tail -1 || true)
DEC=$(cast decode-error --sig "PayeeNotRegistered(uint256,uint256,address,address)" "$ERR" 2>/dev/null | tr '\n' ' ' || true)
echo "simulation: ${DEC:+PayeeNotRegistered(}${DEC:-$SIM}${DEC:+)}"
grep -qi "$(echo ${REGISTERED#0x} | cut -c1-8)" <<<"$DEC$SIM" || { echo "UNEXPECTED: the refusal is not PayeeNotRegistered with the registered wallet; stop and read it"; exit 2; }
before=$(cast call $TUSD "balanceOf(address)(uint256)" $ATTACKER --rpc-url $R | cut -d' ' -f1)
# 2) send it anyway, so the refusal is on chain
TX=$(cast send $PAYRUN "$SIG" "$LINES" "${AUTH[@]}" --rpc-url $R --legacy --gas-limit 400000 --async)
for i in $(seq 1 30); do ST=$(cast receipt $TX status --rpc-url $R 2>/dev/null || true); [ -n "$ST" ] && break; sleep 1; done
after=$(cast call $TUSD "balanceOf(address)(uint256)" $ATTACKER --rpc-url $R | cut -d' ' -f1)
echo "attack tx:  $X/tx/$TX"
echo "status:     ${ST:-unknown} (expected 0 = reverted by PayRun)"
echo "attacker tUSD8 before/after: $before / $after"
[ "${ST:-}" = 0 ] || [ "${ST:-}" = false ] || [[ "${ST:-}" == *failed* ]] || { echo "CHECK: status is not 'failed'"; exit 3; }
[ "$after" = "$before" ] && echo "ATTACK REFUSED ON CHAIN: nothing paid, nothing staged" || { echo "ALERT: attacker balance changed"; exit 4; }
