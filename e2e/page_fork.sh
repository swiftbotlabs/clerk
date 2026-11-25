#!/usr/bin/env bash
# The built approval page (docs/) on a LOCAL fork of Aevum testnet: confirm a held payee, pay, and reject through the owner's
# Kernel smart account, plus a not-the-signer control. Local only (anvil on 127.0.0.1:8555, chain id 440050); no testnet sends.
#   KEYS=<testnet keys json> e2e/page_fork.sh          (run e2e/build_pages.sh first)
set -euo pipefail; cd "$(dirname "$0")/.."
KEYS=${KEYS:?set KEYS to the testnet key file (read in-process, never printed)}
for port in 8555 8097; do ! ss -ltn | grep -q ":$port " || { echo "port $port busy"; exit 1; }; done
# docs/ is the production build (its CSP has no local origin); serve a dev copy that may also reach the fork RPC on :8555
DEVDOCS=e2e/work/docs-dev; rm -rf "$DEVDOCS"; mkdir -p e2e/work; cp -r docs "$DEVDOCS"
python3 -c "import sys;p=sys.argv[1]+'/index.html';s=open(p).read();o=\"connect-src 'self' https://rpc-test.qday.info;\";assert s.count(o)==1,'csp';open(p,'w').write(s.replace(o,\"connect-src 'self' https://rpc-test.qday.info http://127.0.0.1:8555;\"))" "$DEVDOCS"
anvil --fork-url "${AEVUM_RPC:-https://rpc-test.qday.info}" --hardfork shanghai --chain-id 440050 --port 8555 --silent & AP=$!
python3 -m http.server 8097 --bind 127.0.0.1 --directory "$DEVDOCS" >/dev/null 2>&1 & HP=$!
trap 'kill $AP $HP 2>/dev/null' EXIT
for i in $(seq 1 100); do cast block-number --rpc-url http://127.0.0.1:8555 >/dev/null 2>&1 && break; sleep 0.3; done
KEYS="$KEYS" OUT="${OUT:-e2e/work}" node e2e/video/fork_page_check.cjs
