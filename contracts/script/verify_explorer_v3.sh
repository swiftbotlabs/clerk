#!/usr/bin/env bash
# Verify the PayRunV3 eval deployments (hostile + rules), our VendorRegistry and the sandbox PayRunV2 on the Aevum testnet explorer (Blockscout).
# Same command shape as verify_explorer.sh (which verified PayRun, PayRunV2 and ClerkStagePolicy on 22 Nov).
# Settings come from foundry.toml (solc 0.8.34, Shanghai, optimizer 200, ipfs metadata). Constructor args were read back from
# the deploy transactions (27 Nov): input = `forge inspect <c> bytecode` + args, metadata hash included. No key needed.
#
#   script/verify_explorer_v3.sh --check   # read-only: rebuild the standard JSON forge would submit, compile it with solc 0.8.34,
#                                          # compare with each deploy transaction's input (no explorer write)
#   script/verify_explorer_v3.sh           # --check, then submit the verifications (explorer API write; no key)
#   script/verify_explorer_v3.sh --status  # read-only: print the explorer's is_verified for each address
#   STATE=<deploy state json> script/verify_explorer_v3.sh [--check|--status]
#        the r7 deployments instead: sandbox/sandbox-testnet-v3.json (VendorRegistry + PayRunV3) or e2e/testnet_v3page.json
#        (the page's PayRunV3), or a testnet_eval.mjs --payrun v3 state (its registry + both PayRunV3, r9b). Constructor args = the deploy tx input minus the repo's creation code, which must be its prefix.
set -euo pipefail
cd "$(dirname "$0")/.."
RPC=${AEVUM_RPC:-https://rpc-test.qday.info}
EXPL=https://explorer-test.qday.info
URL=$EXPL/api/
SOLC_VER=v0.8.34+commit.80d5c536
TUSD8=000000000000000000000000456569838f1d43009a91eba4263147afd7233483
REG=000000000000000000000000428981983c3aa672c27ea5a469e2d0e37dc646a1
OWNER=000000000000000000000000f9eb6218011d8b0e9fce907f2ff8a5fb96ba9dd4
TREAS=0000000000000000000000004a0897e2a2ea489aa93ba7ca107b128f37145047
V3ARGS=0x${TUSD8}${REG}${OWNER}${TREAS}
REGARGS=0x${OWNER}
# the public sandbox's PayRunV2 (deployed 25 Nov by sandbox/deploy.mjs; QDay registry, sandbox owner + treasury). The explorer shows
# its source only through a verified twin (0x89d1...F541), it is not verified itself.
SBXARGS=0x${TUSD8}000000000000000000000000f45e7f39caba1d2055f613970575a7e7069636be0000000000000000000000004425bf594260d534e14eafa940fee340aaccf4dc000000000000000000000000527b1c201ea07eb955fa265094e4231daf28d5a2
# address | contract | constructor args | deploy tx
ROWS=(
  "0x428981983c3aa672c27ea5a469e2d0e37dc646a1|src/VendorRegistry.sol:VendorRegistry|$REGARGS|0xc057ec82420f0d63e30c3a26bbb53c65dbb5819746e9f80f1d20e6aa8007db0d"
  "0x94161dd3ce5bebd21c599933e64c95c69dbc9f38|src/PayRunV3.sol:PayRunV3|$V3ARGS|0x60a3ee8bbdeba84699f80cd85de68ff489fa6ec791b510e244ea05f4d6545827"
  "0x4b94960192749d5f06031dc3b588762f79a956b9|src/PayRunV3.sol:PayRunV3|$V3ARGS|0x2f1f0986d230515f0002ff0c264085c8bd6423cf895319b6d67018e80c1cd9c6"
  "0x8034c01ba98d882abd30118235d648183d3fae52|src/PayRunV2.sol:PayRunV2|$SBXARGS|0x43691c85f9da1c958c377c3c5dc5b05834c9ad137c75e8d2269993fd57242685"
)
if [ -n "${STATE:-}" ]; then
  [ -f "$STATE" ] && [ ! -L "$STATE" ] || { echo "STATE $STATE missing or a symlink"; exit 1; }
  mapfile -t ROWS < <(python3 - "$STATE" "$RPC" <<'PY'
import json, re, subprocess, sys
st = json.load(open(sys.argv[1])); rpc = sys.argv[2]
def row(addr, ctr, tx):
    if not (re.fullmatch(r"0x[0-9a-fA-F]{40}", addr or "") and re.fullmatch(r"0x[0-9a-fA-F]{64}", tx or "")): return
    bc = subprocess.run(["forge", "inspect", ctr, "bytecode"], capture_output=True, text=True, check=True).stdout.strip().lower()
    inp = subprocess.run(["cast", "tx", tx, "input", "--rpc-url", rpc], capture_output=True, text=True, check=True).stdout.strip().lower()
    if not inp.startswith(bc): sys.exit(f"FAIL {addr}: deploy input does not start with the repo's {ctr} creation code")
    print(f"{addr}|{ctr}|0x{inp[len(bc):]}|{tx}")
row(st.get("registry") if st.get("registry_deploy_tx") else None, "src/VendorRegistry.sol:VendorRegistry", st.get("registry_deploy_tx"))
if st.get("version") == "v3": row(st.get("payrun"), "src/PayRunV3.sol:PayRunV3", st.get("payrun_deploy_tx"))
row(st.get("payrun_v3"), "src/PayRunV3.sol:PayRunV3", st.get("payrun_v3_deploy_tx"))
# r9b: a testnet_eval.mjs --payrun v3 state file (steps.deploy_registry / deploy_hostile / deploy_rules)
for k, c in (("deploy_registry", "src/VendorRegistry.sol:VendorRegistry"), ("deploy_hostile", "src/PayRunV3.sol:PayRunV3"), ("deploy_rules", "src/PayRunV3.sol:PayRunV3")):
    d = (st.get("steps") or {}).get(k) or {}
    row(d.get("contractAddress"), c, d.get("hash"))
PY
)
  [ "${#ROWS[@]}" -gt 0 ] || { echo "FAIL: no contract found in $STATE"; exit 1; }
fi
V=(--verifier blockscout --verifier-url "$URL" --chain 44005 --compiler-version "$SOLC_VER")

status() {
  for row in "${ROWS[@]}"; do IFS='|' read -r addr _ _ _ <<<"$row"
    curl -sS -m 20 "$EXPL/api/v2/smart-contracts/$addr" | python3 -c '
import json,sys
d=json.load(sys.stdin); print(sys.argv[1], "is_verified=%s name=%s compiler=%s verified_at=%s" % (d.get("is_verified"), d.get("name"), d.get("compiler_version"), d.get("verified_at")))' "$addr"
  done
}

check() {
  local solc tmp n=0
  solc=${SOLC:-$(ls ~/.local/share/svm/0.8.34/solc-0.8.34 ~/.svm/0.8.34/solc-0.8.34 2>/dev/null | head -1 || true)}
  [ -x "$solc" ] || { echo "FAIL: solc 0.8.34 not found (set SOLC=)"; return 1; }
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  for row in "${ROWS[@]}"; do IFS='|' read -r addr ctr args tx <<<"$row"
    forge verify-contract "$addr" "$ctr" --constructor-args "$args" "${V[@]}" --show-standard-json-input > "$tmp/sji.json"
    "$solc" --standard-json "$tmp/sji.json" > "$tmp/out.json"
    cast tx "$tx" input --rpc-url "$RPC" > "$tmp/in.hex"
    python3 - "$tmp" "$ctr" "$args" "$addr" <<'EOF'
import json,sys
tmp,ctr,args,addr=sys.argv[1:]
path,name=ctr.split(':')
o=json.load(open(f'{tmp}/out.json'))
errs=[e for e in o.get('errors',[]) if e.get('severity')=='error']
if errs: sys.exit(f'FAIL {addr}: compile errors {len(errs)}')
bc=o['contracts'][path][name]['evm']['bytecode']['object'].lower()
inp=open(f'{tmp}/in.hex').read().strip().lower()
if not bc or inp != '0x'+bc+args[2:].lower():
    sys.exit(f'FAIL {addr}: deploy input != standard JSON creation code + constructor args')
print(f'MATCH {addr} {name}: deploy input == creation code ({len(bc)//2} bytes, metadata hash included) + args')
EOF
    n=$((n+1))
  done
  [ "$n" -eq "${#ROWS[@]}" ] || { echo "FAIL: checked $n of ${#ROWS[@]}"; return 1; }
  echo "CHECK OK ($n/${#ROWS[@]})"
}

case "${1:-}" in
  --status) status ;;
  --check) check ;;
  "") check
      for row in "${ROWS[@]}"; do IFS='|' read -r addr ctr args _ <<<"$row"
        forge verify-contract "$addr" "$ctr" --constructor-args "$args" "${V[@]}" --watch
      done
      status ;;
  *) echo "usage: $0 [--check|--status]"; exit 2 ;;
esac
