#!/usr/bin/env bash
# Fork rehearsal of the approval page on PayRunV3 (r7): a LOCAL fork (anvil 127.0.0.1:8555, chain id 440050), e2e/deploy_v3_page.sh
# against it (deploy, one Kernel UserOperation, Acme signs INV-3001, the clerk stages it -> held), the page built for that
# PayRunV3 into e2e/work/docs-v3 (docs/ is NOT touched), then the browser check: a stranger can't release the hold, the owner's
# signer confirms the payee and pays through the Kernel account. No testnet sends.
#   KEYS=~/agent/secrets/aevum_testnet_keys.json VKEYS=~/agent/secrets/aevum_eval_keys_v3.json e2e/page_fork_v3.sh
set -euo pipefail; cd "$(dirname "$0")/.."
KEYS=${KEYS:?testnet keys (owner, clerk)}; VKEYS=${VKEYS:?V3 eval keys (vendor1)}
for port in 8555 8097; do ! ss -ltn | grep -q ":$port " || { echo "port $port busy"; exit 1; }; done
W=e2e/work/v3fork; rm -rf "$W"; mkdir -p "$W"
anvil --fork-url "${AEVUM_RPC_UPSTREAM:-https://rpc-test.qday.info}" --hardfork shanghai --chain-id 440050 --port 8555 --silent & AP=$!
HP=; trap 'kill $AP $HP 2>/dev/null' EXIT
for i in $(seq 1 100); do cast block-number --rpc-url http://127.0.0.1:8555 >/dev/null 2>&1 && break; sleep 0.3; done
cast rpc anvil_mine 0x40 --rpc-url http://127.0.0.1:8555 >/dev/null     # anvil's gas oracle down to ~1 gwei
AEVUM_RPC=http://127.0.0.1:8555 CHAIN=440050 ST=work/v3fork/state.json WORK=work/v3fork/inv REPORT_OUT=work/v3fork/report.json KEYS="$KEYS" VKEYS="$VKEYS" e2e/deploy_v3_page.sh | tee "$W/deploy.log"
V3=$(python3 -c "import json;print(json.load(open('$W/state.json'))['payrun_v3'])")
# build the page for that PayRunV3 in a scratch copy of the repo's page sources (docs/ stays as committed)
B=$W/build; mkdir -p "$B/e2e" "$B/web" && cp -r web/. "$B/web/" && cp e2e/build_pages.sh e2e/prerender.py e2e/report_v2.py e2e/testnet.json e2e/testnet_v2.json "$B/e2e/"
mkdir -p "$B/e2e/film" && cp e2e/film/report3.json "$B/e2e/film/"
(cd "$B" && AEVUM_RPC=http://127.0.0.1:8555 PAGES_DEV=1 CLERK_V3PAGE="$PWD/../state.json" V3_WITH="$PWD/../report.json" bash e2e/build_pages.sh) | tail -3
DEVDOCS=$B/docs
python3 -c "import sys;p=sys.argv[1]+'/index.html';s=open(p).read();o=\"connect-src 'self' https://rpc-test.qday.info\";assert o in s,'csp';s=s if '127.0.0.1:8555' in s else s.replace(o,o+' http://127.0.0.1:8555',1);open(p,'w').write(s)" "$DEVDOCS"
grep -q "const V3_PAGE = '$V3';" "$DEVDOCS/app.js" || { echo "V3_PAGE not pinned in the built app.js"; exit 1; }
python3 -m http.server 8097 --bind 127.0.0.1 --directory "$DEVDOCS" >/dev/null 2>&1 & HP=$!
NODE_PATH=${NODE_PATH:-/data/motion/node_modules:$PWD/sandbox/node_modules} CHROME_BIN=${CHROME_BIN:-/usr/bin/google-chrome} KEYS="$KEYS" V3_ADDR="$V3" OUT="$W" node e2e/video/fork_page_check_v3.cjs
