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
