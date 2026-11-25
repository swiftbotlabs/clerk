#!/usr/bin/env bash
# Planted positive controls (P10) for the Worker's gates. Each mutant disables ONE guard; the matching HTTP test phase must go
# RED. Then the source is restored (sha checked) and the same phases must be GREEN. Needs the anvil fork + work/dev.vars.
# Usage: worker/scripts/controls.sh            (log: work/controls.log)
set -uo pipefail
cd "$(dirname "$0")/../.."
LOG=work/controls.log; : > "$LOG"
SRC="worker/src/index.mjs worker/src/do.mjs worker/src/limits.mjs"
sha() { sha256sum $SRC | sha256sum | cut -c1-16; }
ORIG=$(sha); mkdir -p work/controls-bak; for f in $SRC; do cp "$f" "work/controls-bak/$(basename "$f")"; done
restore() { for f in $SRC; do cp "work/controls-bak/$(basename "$f")" "$f"; done; }
trap restore EXIT
run() { SANDBOX_WORKER=1 SKIP_TRIM=1 PHASES=$1 timeout 900 node --test --test-concurrency=1 test/worker.http.test.mjs > work/controls-run.log 2>&1; }
fails=0
mutant() {   # name phases [file old new]...
  local name=$1 phases=$2; shift 2
  restore
  while [ $# -ge 3 ]; do
    python3 -c "import sys;p,o,n=sys.argv[1:4];s=open(p).read();assert s.count(o)>=1,'pattern not found';open(p,'w').write(s.replace(o,n))" "$1" "$2" "$3" \
      || { echo "MUTANT $name: pattern missing (control invalid)" | tee -a "$LOG"; fails=$((fails+1)); return; }
    shift 3
  done
  if run "$phases"; then echo "MUTANT $name (phases $phases): still GREEN -> the test does not catch it" | tee -a "$LOG"; fails=$((fails+1))
  else echo "MUTANT $name (phases $phases): RED as expected ($(grep -m1 -E '^# fail' work/controls-run.log))" | tee -a "$LOG"; fi
}
# kill switch has two layers (Worker + Durable Object); both must be off for the test to go red
mutant kill_switch_off_both 4 worker/src/index.mjs "if (env.SANDBOX_OFF === '1') return refuse('off'" "if (false) return refuse('off'" \
  worker/src/do.mjs "if (this.env.SANDBOX_OFF === '1') return { status: 503, code: 'off' };" "if (false) return { status: 503, code: 'off' };"
mutant interval_off 2 worker/src/do.mjs "if (mine.last !== null && now - mine.last" "if (false && now - mine.last"
mutant ip_day_off 3 worker/src/do.mjs "if (today >= L.ipDay)" "if (false)"
mutant global_day_off 3 worker/src/do.mjs "if (g >= L.globalDay)" "if (false)"
mutant turnstile_off 5 worker/src/index.mjs "if (!(await turnstileOk(env, fields.token, ip)))" "if (false)"
mutant dev_gate_off 6 worker/src/limits.mjs "if (env.SANDBOX_DEV === '1' ? !local : cfg.rpc !== 'https://rpc-test.qday.info')" "if (false)"
mutant visitor_text_public 1 worker/src/do.mjs "kind, n: res.n, title: res.title," "kind, n: res.n, title: res.title + (text || ''),"
mutant queue_off 1 worker/src/do.mjs "const job = this.tail.then(() => this.run(kind, text));" "const job = this.run(kind, text);"
restore
[ "$(sha)" = "$ORIG" ] || { echo "RESTORE FAILED: sha differs" | tee -a "$LOG"; exit 2; }
if run 1,2,3,4,5,6; then echo "RESTORED: phases 1-6 GREEN ($(grep -m1 -E '^# pass' work/controls-run.log)), source sha $ORIG" | tee -a "$LOG"
else echo "RESTORED but NOT green" | tee -a "$LOG"; fails=$((fails+1)); fi
echo "controls done: $fails problem(s)" | tee -a "$LOG"
exit $(( fails > 0 ))
