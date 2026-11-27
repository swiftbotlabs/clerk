#!/usr/bin/env bash
# r8 fork rehearsal: the approval page's PayRunV3 over time, and e2e/refresh_page_run.sh, on a LOCAL fork of Aevum testnet
# (anvil 127.0.0.1:8555, chain id 440050, the page's fork chain). No testnet sends: the refresh script only talks to the fork, and
# it works on COPIES of e2e/testnet_v3page.json and e2e/reports/report-v3page.json. docs/ is not touched (scratch build).
#   A  now                      run 1 Held (+ "can be paid until"), walkthrough runs to Paid
#   B  hold ended (+25 h)       run 1 still Held: waiting doesn't release it
#   C  past RUN_TTL             run 1 "Expired, not paid", nothing counted as held, walkthrough still runs to Paid
#      control C': app.js with the expiry check removed -> the page check must FAIL
#   D  control D': refresh dies while Acme is suspended -> the trap reinstates Acme; then the real refresh -> run 2 Held, run 1 Rejected
#   E  +25 h                    run 2 still Held
#   F  past run 2's TTL, refresh again -> run 3 Held, run 2 Rejected (an expired run is cleared too)
#      control G': refresh with the observe step skipped -> no new hold -> the refresh must FAIL ("not held")
#   KEYS=~/agent/secrets/aevum_testnet_keys.json EKEYS=~/agent/secrets/aevum_eval_keys_v3.json e2e/refresh_fork.sh
set -euo pipefail; cd "$(dirname "$0")/.."
KEYS=${KEYS:?testnet keys}; EKEYS=${EKEYS:?V3 eval keys}
for port in 8555 8097; do ! ss -ltn | grep -q ":$port " || { echo "port $port busy"; exit 1; }; done
W=$PWD/e2e/work/rfork; rm -rf "$W"; mkdir -p "$W"
RPC=http://127.0.0.1:8555
anvil --fork-url "${AEVUM_RPC_UPSTREAM:-https://rpc-test.qday.info}" --hardfork shanghai --chain-id 440050 --port 8555 --silent & AP=$!
HP=; trap 'kill $AP $HP 2>/dev/null || true' EXIT
for i in $(seq 1 100); do cast block-number --rpc-url $RPC >/dev/null 2>&1 && break; sleep 0.3; done
cast rpc anvil_mine 0x40 --rpc-url $RPC >/dev/null
cp e2e/testnet_v3page.json "$W/state.json"; cp e2e/reports/report-v3page.json "$W/report.json"
V3=$(python3 -c "import json;print(json.load(open('$W/state.json'))['payrun_v3'])")
REG=$(python3 -c "import json;print(json.load(open('$W/state.json'))['registry'])")
B=$W/build; mkdir -p "$B/e2e/film" "$B/web" && cp -r web/. "$B/web/" && cp e2e/build_pages.sh e2e/prerender.py e2e/report_v2.py e2e/testnet.json e2e/testnet_v2.json "$B/e2e/" && cp e2e/film/report3.json "$B/e2e/film/"
build() {
  (cd "$B" && AEVUM_RPC=$RPC PAGES_DEV=1 CLERK_V3PAGE="$W/state.json" V3_WITH="$W/report.json" bash e2e/build_pages.sh) | tail -1
  python3 -c "import sys;p=sys.argv[1]+'/index.html';s=open(p).read();o=\"connect-src 'self' https://rpc-test.qday.info\";assert o in s,'csp';s=s if '127.0.0.1:8555' in s else s.replace(o,o+' http://127.0.0.1:8555',1);open(p,'w').write(s)" "$B/docs"
}
build; python3 -m http.server 8097 --bind 127.0.0.1 --directory "$B/docs" >/dev/null 2>&1 & HP=$!
export NODE_PATH=${NODE_PATH:-/data/motion/node_modules:$PWD/sandbox/node_modules} CHROME_BIN=${CHROME_BIN:-/usr/bin/google-chrome} V3_ADDR=$V3 OUT=$W
check() { TAG=$1 EXPECT=$2 HEADLINE=$3 HELD_TEXT=${4:-} WALK=${5:-0} node e2e/video/page_state_check.cjs; }
static() { grep -q "$1" "$B/docs/index.html" || { echo "STATIC FAIL: no-JS page lacks: $1"; exit 1; }; echo "static OK: $1"; }
warp_to() { local now; now=$(cast block latest --field timestamp --rpc-url $RPC | tr -d '[:space:]'); [ "$1" -gt "$now" ] || return 0
  cast rpc evm_increaseTime $(( $1 - now )) --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null
  echo "-- warped to $(date -u -d @"$(cast block latest --field timestamp --rpc-url $RPC | tr -d '[:space:]')" +%FT%H:%MZ)"; }
run_field() { cast call $V3 'runs(uint256)(uint8,address,uint64,uint128,uint32)' $1 --rpc-url $RPC | sed -n "$2p" | awk '{print $1}'; }
release() { cast call $V3 'canExecute(uint256)(bool,uint256,uint8,uint64)' $1 --rpc-url $RPC | sed -n 4p | awk '{print $1}'; }
refresh() { (cd e2e && AEVUM_RPC=$RPC CHAIN=440050 ST="$W/state.json" REPORT="$W/report.json" WORK="$W/refresh" BUILD=0 KEYS="$KEYS" EKEYS="$EKEYS" "$@" ./refresh_page_run.sh); }
acme() { cast call $REG 'getAgentWallet(uint256)(address)' 1 --rpc-url $RPC; }

echo "== A: now"; S1=$(run_field 1 3)
check A '1=^PayRunV3 run 1: Held' 'held payment' 'can be paid until' 1; static 'PayRunV3 run 1: Held'

echo "== B: the hold has ended"; warp_to $(( $(release 1) + 3600 )); build
check B '1=^PayRunV3 run 1: Held' 'held payment' "waiting won't release it.*can be paid until"; static 'PayRunV3 run 1: Held'

echo "== C: past RUN_TTL"; warp_to $(( S1 + 7*86400 + 3600 )); build
check C '1=^PayRunV3 run 1: Expired, not paid' 'can no longer pay' '' 1; static 'PayRunV3 run 1: Expired, not paid'
grep -q 'held payment' <(grep -o '<h1 id="headline">[^<]*' "$B/docs/index.html") && { echo "STATIC FAIL: expired run counted as held"; exit 1; }
echo "== C' control: expiry check removed from app.js -> must FAIL"
cp "$B/docs/app.js" "$W/app.js.good"
python3 -c "import sys;p=sys.argv[1];s=open(p).read();a='const expired = st === 1 && now > stagedAt + RUN_TTL;';assert s.count(a)==1;open(p,'w').write(s.replace(a,'const expired = false;'))" "$B/docs/app.js"
if check Cctl '1=^PayRunV3 run 1: Expired, not paid' 'can no longer pay'; then echo "CONTROL C' NOT CAUGHT"; exit 1; else echo "CONTROL C' RED (as it must be)"; fi
cp "$W/app.js.good" "$B/docs/app.js"

echo "== D' control: the refresh dies while Acme is suspended -> Acme must be reinstated"
if refresh env REFRESH_FAIL_AFTER_SUSPEND=1; then echo "CONTROL D' did not fail"; exit 1; fi
ACME=$(python3 -c "import json;print(json.load(open('$W/report.json'))['items'][0]['proposed']['wallet'].lower())")
[ "$(acme | tr 'A-F' 'a-f')" = "$ACME" ] \
  && echo "CONTROL D' OK: Acme reinstated after the failure ($(acme))" || { echo "CONTROL D' FAIL: Acme is $(acme)"; exit 1; }
echo "== D: refresh"; refresh env; build
check D '1=^PayRunV3 run 1: Rejected;2=^PayRunV3 run 2: Held' '^1 held payment to confirm or reject(, 1 invoice to check)?$' 'can be paid until' 1; static 'PayRunV3 run 2: Held'; static 'Hold restart: Acme suspended'; static 'only your confirmation does'
S2=$(run_field 2 3)
echo "== E: run 2's hold has ended"; warp_to $(( $(release 2) + 3600 )); build
check E '2=^PayRunV3 run 2: Held' 'held payment' "waiting won't release it"; static "waiting won't release it"
echo "== F: run 2 expired, refresh again"; warp_to $(( S2 + 7*86400 + 3600 )); build
check F0 '2=^PayRunV3 run 2: Expired, not paid' 'can no longer pay'
refresh env; build
check F '1=^PayRunV3 run 1: Rejected;2=^PayRunV3 run 2: Rejected;3=^PayRunV3 run 3: Held' '^1 held payment to confirm or reject(, 1 invoice to check)?$' 'can be paid until' 1; static 'PayRunV3 run 3: Held'
echo "== G' control: once run 3's hold has ended, a refresh without the observe step -> no new hold -> must FAIL"
warp_to $(( $(release 3) + 3600 ))
if refresh env REFRESH_SKIP_OBSERVE=1 > "$W/control-g.log" 2>&1; then tail -5 "$W/control-g.log"; echo "CONTROL G' NOT CAUGHT"; exit 1; fi
grep -E "canExecute|REFRESH FAIL" "$W/control-g.log"; grep -q "REFRESH FAIL: run .* is not held" "$W/control-g.log" || { echo "CONTROL G' failed for another reason"; exit 1; }; echo "CONTROL G' RED (as it must be)"
echo "REFRESH FORK REHEARSAL OK (gas used by the refresh keys: see $W/state.json refreshes)"
