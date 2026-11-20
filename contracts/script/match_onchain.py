#!/usr/bin/env python3
"""Show that the PayRun deployed on Aevum testnet runs exactly this repository's source.

The testnet explorer cannot verify contracts yet (its verifier lists no compiler versions), so this script does the check itself:
it compiles src/PayRun.sol with the pinned compiler (forge build), reads the deployed runtime bytecode with eth_getCode, fills the two
immutables (token, registry) with the values the deployed contract reports, and compares byte for byte, metadata hash included.
The metadata hash commits to the exact source text and compiler settings, so a full match means: this source, this compiler.

  python3 script/match_onchain.py [address] [--rpc https://rpc-test.qday.info]
"""
import json, subprocess, sys, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
args = [a for a in sys.argv[1:] if not a.startswith("--")]
rpc = sys.argv[sys.argv.index("--rpc") + 1] if "--rpc" in sys.argv else "https://rpc-test.qday.info"
if "--rpc" in sys.argv: args.remove(rpc)
addr = args[0] if args else json.load(open(HERE.parent / "e2e/testnet.json"))["payrun"]

def call(method, params):
    req = urllib.request.Request(rpc, data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                                 headers={"content-type": "application/json", "user-agent": "clerk-match/1"})
    r = json.load(urllib.request.urlopen(req, timeout=30))
    if "error" in r: raise SystemExit(f"RPC error: {r['error']}")
    return r["result"]

subprocess.run(["forge", "build", "--silent"], cwd=HERE, check=True)
art = json.load(open(HERE / "out/PayRun.sol/PayRun.json"))
local = bytearray.fromhex(art["deployedBytecode"]["object"][2:])
onchain = bytes.fromhex(call("eth_getCode", [addr, "latest"])[2:])
if not onchain: raise SystemExit(f"FAIL: no code at {addr}")
# immutables: token() = 0xfc0c546a, registry() = 0x7b103999; ids in immutableReferences follow the declaration order in the AST
# the artifact has no AST; immutable ids follow declaration order (token is declared before registry in PayRun.sol)
names = dict(zip(sorted(int(k) for k in art["deployedBytecode"]["immutableReferences"]), ["token", "registry"]))
sel = {"token": "0xfc0c546a", "registry": "0x7b103999"}
for ref, spots in art["deployedBytecode"]["immutableReferences"].items():
    name = names[int(ref)]
    val = bytes.fromhex(call("eth_call", [{"to": addr, "data": sel[name]}, "latest"])[2:])
    for s in spots: local[s["start"]:s["start"] + s["length"]] = val
    print(f"immutable {name:8s} = 0x{val[-20:].hex()}")
meta_len = int.from_bytes(onchain[-2:], "big") + 2
same_code = bytes(local[:-meta_len]) == onchain[:-meta_len]
same_all = bytes(local) == onchain
print(f"address   {addr}\ncompiler  solc {art['metadata']['compiler']['version']}, evm {art['metadata']['settings']['evmVersion']}, "
      f"optimizer {art['metadata']['settings']['optimizer']['runs']} runs\nruntime   {len(onchain)} bytes on chain, {len(local)} bytes from source")
print("MATCH: identical runtime bytecode, metadata hash included (same source, same settings)" if same_all else
      "MATCH (code only): identical except the metadata hash" if same_code else "FAIL: runtime bytecode differs")
sys.exit(0 if same_code else 1)
