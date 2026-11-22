#!/usr/bin/env bash
# Verify the three deployed Clerk contracts on the Aevum testnet explorer (Blockscout; its verifier lists solc 0.8.34 since ~22 Nov).
# Source settings come from foundry.toml (solc 0.8.34, Shanghai, optimizer 200). Constructor args below were read back from the
# deploy transactions (creation code identical to `forge inspect ... bytecode`, checked 22 Nov). No key needed.
set -euo pipefail
cd "$(dirname "$0")/.."
URL=https://explorer-test.qday.info/api/
ARGS=0x000000000000000000000000456569838f1d43009a91eba4263147afd7233483000000000000000000000000f45e7f39caba1d2055f613970575a7e7069636be000000000000000000000000c0bc2ab048dca250417beaff6b68a222a4ae2d1c000000000000000000000000c0bc2ab048dca250417beaff6b68a222a4ae2d1c
V=(--verifier blockscout --verifier-url "$URL" --chain 44005 --compiler-version v0.8.34+commit.80d5c536 --watch)
forge verify-contract 0x2EE29a167CDDb964aAB9C899ea9Ae89847e3Da98 src/PayRun.sol:PayRun --constructor-args "$ARGS" "${V[@]}"
forge verify-contract 0x89d14Bf88D8dF1AB8b0F520414fbbC9e1d69F541 src/PayRunV2.sol:PayRunV2 --constructor-args "$ARGS" "${V[@]}"
forge verify-contract 0x4Ea16B1bb18005344FC77491F3809a47C74c01a4 src/ClerkStagePolicy.sol:ClerkStagePolicy "${V[@]}"
