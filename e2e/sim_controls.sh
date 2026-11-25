#!/usr/bin/env bash
# Planted positive controls (P10) for the approval page's no-wallet simulation (web/sim.js + web/app.js), checked in a separate
# headless browser against the LIVE testnet, read-only (e2e/video/sim_page_check.cjs). Each mutant must turn the check RED;
# the restored source (sha checked) must be GREEN.   Usage: e2e/sim_controls.sh OUTDIR
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?outdir}; mkdir -p "$OUT"; LOG="$OUT/sim-controls.log"; : > "$LOG"
SRC="web/sim.js web/app.js"
sha() { sha256sum $SRC | sha256sum | cut -c1-16; }
ORIG=$(sha); mkdir -p "$OUT/bak"; for f in $SRC; do cp "$f" "$OUT/bak/$(basename "$f")"; done
restore() { for f in $SRC; do cp "$OUT/bak/$(basename "$f")" "$f"; done; cp web/sim.js docs/sim.js; cp web/app.js docs/app.js; }
python3 -m http.server 8098 --bind 127.0.0.1 --directory docs >/dev/null 2>&1 & HP=$!
trap 'restore; kill $HP 2>/dev/null' EXIT
sleep 1
check() { cp web/sim.js docs/sim.js; cp web/app.js docs/app.js
  NODE_PATH=${NODE_PATH:-/data/motion/node_modules} CHROME_BIN=${CHROME_BIN:-/usr/bin/google-chrome} OUT="$OUT" PORT=8098 timeout 900 node e2e/video/sim_page_check.cjs > "$OUT/run.log" 2>&1; }
fails=0
mutant() { local name=$1; shift; if [ -n "${ONLY:-}" ] && [[ ",$ONLY," != *",$name,"* ]]; then return; fi; restore
  while [ $# -ge 3 ]; do python3 -c "import sys;p,o,n=sys.argv[1:4];s=open(p).read();assert s.count(o)==1,'pattern';open(p,'w').write(s.replace(o,n))" "$1" "$2" "$3" \
    || { echo "MUTANT $name: pattern missing (control invalid)" | tee -a "$LOG"; fails=$((fails+1)); return; }; shift 3; done
  if check; then echo "MUTANT $name: still GREEN -> not caught" | tee -a "$LOG"; fails=$((fails+1))
  else echo "MUTANT $name: RED as expected ($(grep -m1 'SIM FAIL' "$OUT/run.log" | cut -c1-160))" | tee -a "$LOG"; fi; }
mutant no_state_override web/sim.js "await pub.call({ to: owner, data, stateOverride: [{ address: owner, code: PROBE_CODE }] })" "await pub.call({ to: owner, data })"
mutant skip_confirm web/sim.js "enc('confirmPayee', [v.agentId, v.wallet]), enc('canExecute', [runId])," "enc('canExecute', [runId]), enc('canExecute', [runId]),"
mutant unlabelled web/app.js "const SIM_TAG = '<span class=\"sim-tag\">Simulation</span> ';" "const SIM_TAG = '';"
mutant trusted_vendor web/sim.js "if (Number(state) === 2 &&" "if (Number(state) >= 0 &&" web/sim.js "export const CANDIDATES = [1822," "export const CANDIDATES = [1698, 1822,"
restore
[ "$(sha)" = "$ORIG" ] || { echo "RESTORE FAILED" | tee -a "$LOG"; exit 1; }
if check; then echo "GREEN restored: $(tail -1 "$OUT/run.log")" | tee -a "$LOG"; else echo "RESTORED SOURCE RED" | tee -a "$LOG"; fails=$((fails+1)); fi
echo "sim controls: $fails failure(s)" | tee -a "$LOG"; exit $fails
