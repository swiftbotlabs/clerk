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
# docs/ is the BUILT page: app.js gets the pinned PayRunV3 (e2e/build_pages.sh does the same), so copies must too
pin() { [ -f e2e/testnet_v3page.json ] || return 0; python3 -c "import json,re;a=json.load(open('e2e/testnet_v3page.json'))['payrun_v3'];assert re.fullmatch(r'0x[0-9a-fA-F]{40}',a);p='docs/app.js';s=open(p).read();m=\"const V3_PAGE = '';\";assert s.count(m)==1;open(p,'w').write(s.replace(m,f\"const V3_PAGE = '{a}';\"))"; }
V3EXP=$([ -f e2e/testnet_v3page.json ] && python3 -c "import json;print(json.load(open('e2e/testnet_v3page.json'))['payrun_v3'])"); export EXPECT_PAYRUN=${EXPECT_PAYRUN:-$V3EXP}; [ -n "$EXPECT_PAYRUN" ] && export EXPECT_NAME=${EXPECT_NAME:-PayRunV3}
restore() { for f in $SRC; do cp "$OUT/bak/$(basename "$f")" "$f"; done; cp web/sim.js docs/sim.js; cp web/app.js docs/app.js; pin; }
python3 -m http.server 8098 --bind 127.0.0.1 --directory docs >/dev/null 2>&1 & HP=$!
trap 'restore; kill $HP 2>/dev/null' EXIT
sleep 1
# B1 gate: the probe code in sim.js must equal the compiled DemoProbe (forge artifact) BEFORE the browser check runs
(cd contracts && FOUNDRY_OFFLINE=true forge build >/dev/null 2>&1) || { echo "forge build failed" | tee -a "$LOG"; exit 1; }
check() { cp web/sim.js docs/sim.js; cp web/app.js docs/app.js; pin
  node e2e/test_sim.mjs > "$OUT/run.log" 2>&1 && \
  NODE_PATH=${NODE_PATH:-/data/motion/node_modules} CHROME_BIN=${CHROME_BIN:-/usr/bin/google-chrome} OUT="$OUT" PORT=8098 timeout 900 node e2e/video/sim_page_check.cjs >> "$OUT/run.log" 2>&1; }
fails=0
mutant() { local name=$1; shift; if [ -n "${ONLY:-}" ] && [[ ",$ONLY," != *",$name,"* ]]; then return; fi; restore
  while [ $# -ge 3 ]; do python3 -c "import sys;p,o,n=sys.argv[1:4];s=open(p).read();assert s.count(o)==1,'pattern';open(p,'w').write(s.replace(o,n))" "$1" "$2" "$3" \
    || { echo "MUTANT $name: pattern missing (control invalid)" | tee -a "$LOG"; fails=$((fails+1)); return; }; shift 3; done
  if check; then echo "MUTANT $name: still GREEN -> not caught" | tee -a "$LOG"; fails=$((fails+1))
  else echo "MUTANT $name: RED as expected ($(grep -m1 'SIM FAIL' "$OUT/run.log" | cut -c1-160))" | tee -a "$LOG"; fi; }
mutant no_state_override web/sim.js "await pub.call({ to: owner, data, stateOverride: [{ address: owner, code: PROBE_CODE }] })" "await pub.call({ to: owner, data })"
mutant skip_confirm web/sim.js "enc('confirmPayee', [v.agentId, v.wallet]), enc('canExecute', [runId])," "enc('canExecute', [runId]), enc('canExecute', [runId]),"
mutant unlabelled web/app.js "const SIM_TAG = '<span class=\"sim-tag\">Simulation</span> ';" "const SIM_TAG = '';"
# r7b: with a PayRunV3 pinned the walkthrough must run on it: falling back to PayRunV2 (the live bug of 27 Nov) must turn RED,
# and so must dropping the signedOnly skip with Acme (#1, signedOnly) first in line (staging reverts VendorSignatureRequired)
mutant walkthrough_on_v2 web/app.js "function simPayrun() { return (PINNED[chainId] || [])[2] ||" "function simPayrun() { return (PINNED[chainId] || [])[1] ||"
mutant signed_vendor_unskipped web/sim.js "if (signed) continue;" "" web/sim.js "export const OWN_REGISTRY_CANDIDATES = [12," "export const OWN_REGISTRY_CANDIDATES = [1, 12,"
[ -n "${EXPECT_PAYRUN:-}" ] || mutant trusted_vendor web/sim.js "if (Number(state) === 2 &&" "if (Number(state) >= 0 &&" web/sim.js "export const CANDIDATES = [1822," "export const CANDIDATES = [1698, 1822,"
# r4 review B1/B2: a stale probe (one metadata byte differs: the page would still work, only test_sim catches it), "paid X"
# computed from a post-call balance instead of the probe's pre-call read, and the held result without "after you've checked the vendor"
mutant probe_code_stale web/sim.js "a86e28e63e364736f6c63430008220033';" "a86e28e63e464736f6c63430008220033';"
mutant before_after_first_call web/sim.js "return { before: { payee: payeeBefore, treasury: treasuryBefore }," "return { before: { payee: steps[0].payeeBalance, treasury: steps[0].treasuryBalance },"
mutant held_text_no_check web/app.js "'Confirm the payee, only after you\\'ve checked the vendor (call them on a number you already had): accepted (only the owner can do this).'" "'Confirm the payee: accepted (only the owner can do this).'"
restore
[ "$(sha)" = "$ORIG" ] || { echo "RESTORE FAILED" | tee -a "$LOG"; exit 1; }
if check; then echo "GREEN restored: $(tail -1 "$OUT/run.log")" | tee -a "$LOG"; else echo "RESTORED SOURCE RED" | tee -a "$LOG"; fails=$((fails+1)); fi
echo "sim controls: $fails failure(s)" | tee -a "$LOG"; exit $fails
