#!/usr/bin/env bash
# Local-only wrangler dev for the sandbox Worker against the anvil fork. Usage:
#   worker/scripts/dev.sh start <port> <persist-dir> [--var K:V ...]    (own process group; pid in work/wrangler-<port>.pgid)
#   worker/scripts/dev.sh stop <port>
set -euo pipefail
cd "$(dirname "$0")/../.."
cmd=$1; port=$2; shift 2
pg=work/wrangler-$port.pgid
if [ "$cmd" = stop ]; then
  [ -f "$pg" ] && kill -TERM -- -"$(cat "$pg")" 2>/dev/null || true; sleep 1
  [ -f "$pg" ] && kill -KILL -- -"$(cat "$pg")" 2>/dev/null || true; rm -f "$pg"; exit 0
fi
persist=$1; shift
VARS=${SANDBOX_DEV_VARS:-work/dev.vars}     # another fork config (e.g. the PayRunV3 sandbox) via SANDBOX_DEV_VARS
[ -f "$VARS" ] || { echo "$VARS missing (node worker/mkvars.mjs --mode fork ...)"; exit 1; }
export WRANGLER_SEND_METRICS=false
# local runs never bind Workers AI (no account calls from tests): a copy of the config without the [ai] block
python3 -c "import re,sys;s=open('worker/wrangler.toml').read();t=re.sub(r'\n\[ai\]\nbinding = \"AI\"\n','\n',s);assert t!=s,'no [ai] block found';open('worker/wrangler.dev.toml','w').write(t)"
setsid npx wrangler dev --config worker/wrangler.dev.toml --env-file "$(realpath "$VARS")" --var SANDBOX_DEV:1 "$@" \
  --ip 127.0.0.1 --port "$port" --persist-to "$persist" --show-interactive-dev-session=false > "work/wrangler-$port.log" 2>&1 &
echo $! > "$pg"
for i in $(seq 1 90); do grep -q 'Ready on' "work/wrangler-$port.log" && exit 0; sleep 1; done
echo "wrangler did not become ready"; exit 1
