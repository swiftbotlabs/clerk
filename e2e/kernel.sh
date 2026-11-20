#!/usr/bin/env bash
# ERC-4337 helpers (sourced by run_fork.sh / run_testnet.sh): the PayRun owner as a Kernel v3.1 smart account on Aevum.
# Uses only `cast`. Aevum's own deployments: EntryPoint v0.7, Kernel v3.1 factory, Kernel's ECDSA validator.
# The owner's key signs each UserOperation; the same key submits handleOps (it acts as its own bundler) and gets the gas refund.
EP=0x0000000071727De22E5E9d8BAf0edAc6f37da032
KFACTORY=0xaac5D4240AF87249B3f71BC8E4A2cae074A3E419
KECDSA=0x845ADb2C711129d4f3966735eD98a9F09fC4cE57
OP_T='(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)'

# kernel_init <owner address>: Kernel.initialize(root validator = 0x01 ++ ECDSA validator, no hook, owner, "", [])
kernel_init() { cast calldata "initialize(bytes21,address,bytes,bytes,bytes[])" "0x01${KECDSA#0x}" 0x0000000000000000000000000000000000000000 "$1" 0x "[]"; }

# kernel_create <rpc> <owner key> <salt>: deploys the account if needed (idempotent), prints its address on the last line
kernel_create() {
  local rpc=$1 key=$2 salt=$3 init addr
  init=$(kernel_init "$(cast wallet address "$key")")
  addr=$(cast call $KFACTORY "createAccount(bytes,bytes32)(address)" "$init" "$salt" --rpc-url "$rpc")
  if [ "$(cast code "$addr" --rpc-url "$rpc")" = "0x" ]; then
    cast send --legacy --private-key "$key" $KFACTORY "createAccount(bytes,bytes32)" "$init" "$salt" --rpc-url "$rpc" >/dev/null
  fi
  echo "$addr"
}

# kernel_single <to> <calldata>: Kernel.execute(mode 0 = single call, to ++ value 0 ++ data)
kernel_single() { cast calldata "execute(bytes32,bytes)" 0x0000000000000000000000000000000000000000000000000000000000000000 \
  "$(cast concat-hex "$1" "$(cast to-uint256 0)" "$2")"; }

# kernel_batch "<to>:<calldata>" ...: Kernel.execute(call type 0x01 = batch, abi.encode(Execution[]))
kernel_batch() {
  local items="" sep="" p
  for p in "$@"; do items="$items$sep(${p%%:*},0,${p#*:})"; sep=","; done
  cast calldata "execute(bytes32,bytes)" 0x0100000000000000000000000000000000000000000000000000000000000000 \
    "$(cast abi-encode "f((address,uint256,bytes)[])" "[$items]")"
}

# kernel_op <rpc> <owner key> <account> <account calldata>: one signed UserOperation through the EntryPoint; prints the tx hash
kernel_op() {
  local rpc=$1 key=$2 acct=$3 data=$4 nonce gas fees op hash sig
  nonce=$(cast call $EP "getNonce(address,uint192)(uint256)" "$acct" 0 --rpc-url "$rpc" | awk '{print $1}')
  gas=0x$(printf '%032x%032x' 600000 600000)
  fees=0x$(printf '%032x%032x' 1000000000 1000000000)
  op="($acct,$nonce,0x,$data,$gas,60000,$fees,0x,0x)"
  hash=$(cast call $EP "getUserOpHash($OP_T)(bytes32)" "$op" --rpc-url "$rpc")
  sig=$(cast wallet sign --private-key "$key" "$hash")   # EIP-191 personal_sign over the 32-byte hash
  op="($acct,$nonce,0x,$data,$gas,60000,$fees,0x,$sig)"
  cast send --legacy --json --private-key "$key" $EP "handleOps($OP_T[],address)" "[$op]" "$(cast wallet address "$key")" --rpc-url "$rpc" \
    | python3 -c '
import json,sys
r=json.load(sys.stdin); r=r.get("data") or r
assert r.get("status") in ("0x1",1,"1"), r
# UserOperationEvent(bytes32 indexed userOpHash, address indexed sender, address indexed paymaster, uint256 nonce, bool success, ...)
T="0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f"
ev=[l for l in r["logs"] if l["topics"][0]==T]
assert ev and int(ev[0]["data"][2+64:2+128],16)==1, "UserOperation reverted inside the account"
print(r["transactionHash"])'
}

# kernel_op_bundler <rpc> <bundler url> <owner key> <account> <account calldata>: the same UserOperation, but sent through a bundler
# (QDay's own: https://bundler.qday.info, EntryPoint v0.7) with eth_sendUserOperation instead of our own handleOps. Gas limits come
# from eth_estimateUserOperationGas (signed: Kernel rejects stub signatures), the owner key signs the final hash, and we wait for the bundler's receipt.
# Prints the transaction hash that included it. The account pays gas from its EntryPoint deposit or balance.
kernel_op_bundler() {
  local rpc=$1 bun=$2 key=$3 acct=$4 data=$5
  python3 - "$rpc" "$bun" "$key" "$acct" "$data" "$EP" "$OP_T" <<'PY'
import json, subprocess, sys, time, urllib.request
rpc, bun, key, acct, data, ep, opt = sys.argv[1:8]
def call(url, method, params):
    r = urllib.request.Request(url, data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                               headers={"content-type": "application/json", "user-agent": "clerk-e2e/1"})
    out = json.load(urllib.request.urlopen(r, timeout=60))
    if "error" in out: raise SystemExit(f"{method}: {out['error']}")
    return out["result"]
cast = lambda *a: subprocess.check_output(["cast", *a]).decode().strip()
nonce = int(cast("call", ep, "getNonce(address,uint192)(uint256)", acct, "0", "--rpc-url", rpc).split()[0])
prio = int(int(call(bun, "rundler_maxPriorityFeePerGas", []), 16) * 11 // 10)   # the bundler's floor + 10%
base = int(call(rpc, "eth_getBlockByNumber", ["latest", False]).get("baseFeePerGas") or "0x0", 16)
fee = max(2 * base + prio, prio)
op = {"sender": acct, "nonce": hex(nonce), "callData": data, "callGasLimit": "0x0", "verificationGasLimit": "0x0",
      "preVerificationGas": "0x0", "maxFeePerGas": hex(fee), "maxPriorityFeePerGas": hex(prio),
      "signature": "0x"}
def sign(op):   # Kernel's ECDSA validator reverts on a bad signature (AA23), so even the estimate needs a real one
    packed = (f"({acct},{nonce},0x,{data},0x{int(op['verificationGasLimit'],16):032x}{int(op['callGasLimit'],16):032x},"
              f"{int(op['preVerificationGas'],16)},0x{prio:032x}{fee:032x},0x,0x)")
    op["signature"] = cast("wallet", "sign", "--private-key", key, cast("call", ep, f"getUserOpHash({opt})(bytes32)", packed, "--rpc-url", rpc))
sign(op)
est = call(bun, "eth_estimateUserOperationGas", [op, ep])
for k in ("callGasLimit", "verificationGasLimit", "preVerificationGas"):
    op[k] = hex(int(int(est[k], 16) * 13 // 10))            # 30% headroom over the bundler's estimate
sign(op)
if len(sys.argv) > 8 or __import__("os").environ.get("BUNDLER_DRY"):
    print("DRY estimate ok", json.dumps(est)); sys.exit(0)
uoh = call(bun, "eth_sendUserOperation", [op, ep])
for _ in range(60):
    rc = call(bun, "eth_getUserOperationReceipt", [uoh])
    if rc:
        assert rc.get("success") in (True, "0x1", 1), f"UserOperation reverted inside the account: {uoh}"
        print(rc["receipt"]["transactionHash"]); break
    time.sleep(3)
else:
    raise SystemExit(f"no receipt for {uoh} after 180 s")
PY
}
