#!/usr/bin/env bash
# PayRunV2 payee-change hold, end to end on a LOCAL anvil chain (no fork, no network; chain id 440050 on :8555 so the
# approval page's local entry works). Mock tUSD8 + mock ERC-8004 registry from contracts/test/PayRun.t.sol.
#   1. Acme is onboarded (owner confirmPayee); run 1 pays Acme. Globex is never confirmed (a brand-new payee).
#   2. Acme's registered wallet changes ("new bank details"). The clerk stages run 2 (Acme, new wallet) and run 3 (Globex).
#   3. The owner executes both: each returns without paying, PaymentBlocked on chain; reconcile shows HELD + the audit trail.
#   4. A: Acme flips back to the OLD wallet: still held (A -> B -> A does not restore trust).
#   5. PAGE=1: the approval page shows the hold; Confirm payee then Approve and pay from the page (playwright, EIP-1193 shim).
# Exits non-zero on any unexpected result. KEEP_ANVIL=1 leaves the chain running.
set -euo pipefail
cd "$(dirname "$0")"
F=http://127.0.0.1:8555
WORK=${WORK:-$PWD/work/hold}; mkdir -p "$WORK"
# anvil's PUBLIC test keys (local chain only)
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # owner + treasury
K1=0x59c6995e998f97a5a0044966f0945389dc9c86dae88c7a8412f4603b6b78690d   # clerk session key
A() { cast wallet address "$1"; }
OWNER=$(A $K0); CLERK=$(A $K1)
ACME=$(A 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9802cec3f019d)
GLOBEX=$(A 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6)
ACME_NEW=$(A 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba)
fail() { echo "FAIL: $*"; exit 1; }
if ss -ltn | grep -q ':8555 '; then fail "port 8555 busy (another anvil?)"; fi
anvil --hardfork shanghai --port 8555 --chain-id 440050 --silent & AP=$!
[ "${KEEP_ANVIL:-0}" = 1 ] || trap 'kill $AP 2>/dev/null' EXIT
for i in $(seq 1 50); do cast block-number --rpc-url $F >/dev/null 2>&1 && break; sleep 0.2; done
for a in $OWNER $CLERK; do cast rpc anvil_setBalance $a 0x8AC7230489E80000 --rpc-url $F >/dev/null; done   # 10 ETH each (local chain)
S() { cast send --legacy --private-key "$1" "${@:2}" --rpc-url $F >/dev/null || fail "send ${*:2:2}"; }
deploy() { (cd ../contracts && forge create --legacy --broadcast --json --rpc-url $F --private-key $K0 "$@") | python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("data") or r; print(r["deployedTo"])'; }
USD=$(deploy test/PayRun.t.sol:MockUSD); REG=$(deploy test/PayRun.t.sol:MockRegistry)
PAYRUN=$(deploy src/PayRunV2.sol:PayRunV2 --constructor-args $USD $REG $OWNER $OWNER)
echo "PayRunV2 $PAYRUN  usd $USD  registry $REG"
S $K0 $USD "mint(address,uint256)" $OWNER 1000000000
S $K0 $USD "approve(address,uint256)" $PAYRUN 1000000000
S $K0 $REG "set(uint256,address)" 1 $ACME; S $K0 $REG "set(uint256,address)" 2 $GLOBEX
NOW=$(cast block --rpc-url $F -f timestamp)
S $K0 $PAYRUN "grantSession(address,uint64,uint128,uint128)" $CLERK $((NOW + 7*86400)) 500000000 800000000
S $K0 $PAYRUN "confirmPayee(uint256,address)" 1 $ACME
B32() { cast format-bytes32-string "$1"; }
H() { cast keccak "$1"; }
LINE='stage((uint256,address,uint128,bytes32,bytes32)[])'
bal() { cast call $USD "balanceOf(address)(uint256)" "$1" --rpc-url $F | cut -d' ' -f1; }
status() { cast call $PAYRUN "runs(uint256)(uint8,address,uint64,uint128,uint32)" "$1" --rpc-url $F | head -1; }
canx() { cast call $PAYRUN "canExecute(uint256)(bool,uint256,uint8,uint64)" "$1" --rpc-url $F | tr '\n' ' '; }
blocked_in() { cast receipt "$1" --json --rpc-url $F | python3 -c 'import json,sys; r=json.load(sys.stdin); print(sum(1 for l in r["logs"] if l["topics"][0]=="0xeccfe563df0552cce6bb5602228af8212d6b0abec81deed0180430dbc095511e"))'; }
exec_run() { cast send --legacy --json --private-key $K0 $PAYRUN "execute(uint256)" "$1" --rpc-url $F | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])'; }
FROM=$(cast block-number --rpc-url $F)

# 1. run 1 to the confirmed Acme wallet pays
S $K1 $PAYRUN "$LINE" "[(1,$ACME,120000000,$(H INV-1001),$(B32 INV-1001))]"
TX=$(exec_run 1); [ "$(blocked_in $TX)" = 0 ] || fail "run 1 blocked"; [ "$(bal $ACME)" = 120000000 ] || fail "Acme not paid"
echo "run 1: paid Acme 120.00 (confirmed payee)"

# 2. Acme's wallet changes; Globex has never been confirmed
S $K0 $REG "set(uint256,address)" 1 $ACME_NEW
S $K1 $PAYRUN "$LINE" "[(1,$ACME_NEW,50000000,$(H INV-1002),$(B32 INV-1002))]"
S $K1 $PAYRUN "$LINE" "[(2,$GLOBEX,80000000,$(H G-77),$(B32 G-77))]"
echo "canExecute(2) = $(canx 2)"; echo "canExecute(3) = $(canx 3)"
# 3. the owner tries to pay both: blocked, nothing moves, runs stay staged
TX2=$(exec_run 2); TX3=$(exec_run 3)
[ "$(blocked_in $TX2)" = 1 ] && [ "$(blocked_in $TX3)" = 1 ] || fail "execute was not blocked"
[ "$(bal $ACME_NEW)" = 0 ] && [ "$(bal $GLOBEX)" = 0 ] || fail "a held payee was paid"
[ "$(status 2)" = 1 ] && [ "$(status 3)" = 1 ] || fail "held runs should stay staged"
echo "runs 2 and 3: execute blocked (PaymentBlocked), nothing paid, still staged"
# 4. A -> B -> A: back to the old wallet is not 'known' again
S $K0 $REG "set(uint256,address)" 1 $ACME
S $K1 $PAYRUN "$LINE" "[(1,$ACME,10000000,$(H INV-1003),$(B32 INV-1003))]"
TX4=$(exec_run 4); [ "$(blocked_in $TX4)" = 1 ] || fail "A->B->A paid without a hold"; [ "$(bal $ACME)" = 120000000 ] || fail "A->B->A paid"
echo "run 4: Acme back on its OLD wallet is held too (A -> B -> A)"
S $K0 $PAYRUN "reject(uint256,string)" 4 "test: A-B-A"
S $K0 $REG "set(uint256,address)" 1 $ACME_NEW   # the real new wallet again (run 2 can no longer pay: changed since staging)
S $K0 $PAYRUN "reject(uint256,string)" 2 "payee changed since staging"
S $K1 $PAYRUN "$LINE" "[(1,$ACME_NEW,50000000,$(H INV-1002),$(B32 INV-1002))]"   # run 5, held
echo "run 5: INV-1002 restaged to Acme's new wallet: $(canx 5)"

printf 'reference,agent_id,amount\nINV-1001,1,120.00\nINV-1002,1,50.00\nG-77,2,80.00\n' > "$WORK/ledger.csv"
set +e
AEVUM_RPC=$F python3 -u ../agent/reconcile.py --payrun $PAYRUN --from-block $FROM --to-block $(cast block-number --rpc-url $F) --ledger "$WORK/ledger.csv" --out "$WORK/recon.json" | tee "$WORK/recon.txt"
set -e
grep -q '^PAID_OK *INV-1001' "$WORK/recon.txt" && grep -q '^HELD *G-77' "$WORK/recon.txt" && grep -q '^ALERT PaymentBlocked' "$WORK/recon.txt" \
  && grep -q '^ALERT PayeeConfirmed' "$WORK/recon.txt" && grep -q '^ALERT PayeeChanged' "$WORK/recon.txt" || fail "reconcile did not show the holds"
python3 -c "import json,sys; r=json.load(open(sys.argv[1])); n=len(r['payee_audit']); assert n>=8, n; print('payee audit entries:', n)" "$WORK/recon.json"

# report for the approval page: runs 5 (Acme, new wallet) and 3 (Globex, new payee)
python3 - "$PAYRUN" "$WORK/report.json" <<EOF
import json, sys
def it(run, agent, name, wallet, amt, ref):
    return {"file": ref + ".txt", "run_id": run, "agent_id": agent, "registered_name": name, "decision": "PAYABLE", "cop": "MATCH",
            "units": str(int(float(amt) * 1e6)), "proposed": {"vendor": name, "wallet": wallet, "amount": amt, "currency": "tUSD8",
            "reference": ref, "due_date": "2026-12-06"}, "evidence": {"amount": "Amount due: " + amt + " tUSD8",
            "reference": "Invoice No: " + ref, "due_date": "Due date: 2026-12-06"}, "reasons": [], "warnings": []}
json.dump({"payrun": sys.argv[1], "items": [it(5, 1, "Acme Supplies Ltd", "$ACME_NEW", "50.00", "INV-1002"),
                                            it(3, 2, "Globex Logistics", "$GLOBEX", "80.00", "G-77")]}, open(sys.argv[2], "w"), indent=1)
EOF
if [ "${PAGE:-0}" = 1 ]; then
  python3 -m http.server 8099 --bind 127.0.0.1 --directory .. >/dev/null 2>&1 & HP=$!; sleep 1
  cp "$WORK/report.json" reports/hold_report.json
  set +e; OWNER=$OWNER OUT="$WORK" node video/hold_page_check.cjs; prc=$?; set -e
  kill $HP 2>/dev/null; rm -f reports/hold_report.json
  [ $prc = 0 ] || fail "page check"
  [ "$(bal $ACME_NEW)" = 50000000 ] || fail "page did not pay Acme's confirmed new wallet"
  [ "$(bal $GLOBEX)" = 0 ] || fail "Globex paid without confirmation"
  echo "page: hold shown, payee confirmed and run 5 paid from the page; Globex still held"
fi
echo "HOLD E2E OK (PayRunV2 $PAYRUN)"
