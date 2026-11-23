#!/usr/bin/env bash
# Read-only pre-flight for a live Clerk demo on Aevum testnet (Demo Day runbook, T-24h and T-1h). Sends nothing, needs no key.
# Exit 0 only if every check passes. Usage: e2e/demo_day_check.sh [CLERK_ADDRESS]
set -uo pipefail
R=https://rpc-test.qday.info
USD=0x456569838f1d43009A91ebA4263147Afd7233483
V1=0x2EE29a167CDDb964aAB9C899ea9Ae89847e3Da98; V2=0x89d14Bf88D8dF1AB8b0F520414fbbC9e1d69F541
OWNER=0xc0bC2ab048dCa250417bEaFf6B68A222a4ae2d1C
CLERK=${1:-}
fail=0; ok() { echo "OK    $*"; }; bad() { echo "FAIL  $*"; fail=1; }
num() { cut -d' ' -f1; }
B=$(cast block-number --rpc-url $R 2>/dev/null) && ok "RPC up, block $B" || bad "RPC $R not answering"
T=$(cast block --rpc-url $R -f timestamp 2>/dev/null); NOW=$(date +%s)
[ -n "$T" ] && [ $((NOW - T)) -lt 120 ] && ok "chain is live (last block $((NOW - T))s ago)" || bad "chain looks stalled (last block ${T:-?})"
bal=$(cast call $USD "balanceOf(address)(uint256)" $OWNER --rpc-url $R 2>/dev/null | num)
[ "${bal:-0}" -ge 1000000 ] && ok "treasury (Kernel account) holds $(python3 -c "print(${bal:-0}/1e6)") tUSD8" || bad "treasury below 1 tUSD8 (${bal:-0} units): top up before the demo"
gas=$(cast balance $OWNER --rpc-url $R 2>/dev/null)
[ "${gas:-0}" != 0 ] && ok "Kernel account has tQDAY for UserOperation gas ($gas wei)" || bad "Kernel account has no tQDAY for gas"
for c in $V1 $V2; do [ "$(cast code $c --rpc-url $R 2>/dev/null | wc -c)" -gt 10 ] && ok "contract $c deployed" || bad "no code at $c"; done
if [ -n "$CLERK" ]; then
  for c in $V1 $V2; do
    h=$(cast call $c "headroom(address)(uint256,uint256)" $CLERK --rpc-url $R 2>/dev/null | head -1 | num)
    [ "${h:-0}" -gt 0 ] && ok "clerk session on $c: per-run headroom $h" || bad "clerk $CLERK has no live session on $c (expired or never granted): the owner grants one before the demo"
  done
  cg=$(cast balance $CLERK --rpc-url $R 2>/dev/null); [ "${cg:-0}" != 0 ] && ok "clerk has tQDAY for gas" || bad "clerk has no tQDAY for gas"
else
  echo "SKIP  clerk session checks (pass the clerk's address)"
fi
code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 https://clerk.swiftbotlab.workers.dev/); [ "$code" = 200 ] && ok "approval page 200" || bad "approval page HTTP $code"
page=$(curl -s -m 20 https://clerk.swiftbotlab.workers.dev/); grep -q 'id="record"' <<<"$page" && ok "page is server-rendered (testnet record present without JS)" || bad "page has no server-rendered record (old deploy?)"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 https://bundler.qday.info/); [ "$code" != 000 ] && ok "QDay bundler reachable (HTTP $code)" || bad "QDay bundler unreachable: use self-bundled handleOps (e2e/kernel.sh)"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 'https://www.youtube.com/oembed?url=https://youtu.be/WpnxGX7nYnM'); [ "$code" = 200 ] && ok "demo video plays by link (fallback)" || bad "demo video oEmbed HTTP $code"
exit $fail
