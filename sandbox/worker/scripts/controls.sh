#!/usr/bin/env bash
# Planted positive controls (P10) for the Worker's gates. Each mutant disables ONE guard; the matching HTTP test phase must go
# RED. Then the source is restored (sha checked) and the same phases must be GREEN. Needs the anvil fork + work/dev.vars.
# Usage: worker/scripts/controls.sh            (log: work/controls.log)
set -uo pipefail
cd "$(dirname "$0")/../.."
# R2-4: a partial run (ONLY=a,b) writes its own log, so work/controls.log always holds the last FULL run
if [ -n "${ONLY:-}" ]; then LOG=work/controls-partial.log; else LOG=work/controls.log; fi
: > "$LOG"; echo "run $(date -u +%Y-%m-%dT%H:%MZ) ONLY=${ONLY:-<all>}" >> "$LOG"
SRC="watch_paid.mjs worker/src/index.mjs worker/src/do.mjs worker/src/limits.mjs worker/src/page.mjs worker/mkvars.mjs lib/sandbox.mjs"
sha() { sha256sum $SRC | sha256sum | cut -c1-16; }
ORIG=$(sha); mkdir -p work/controls-bak; for f in $SRC; do cp "$f" "work/controls-bak/$(basename "$f")"; done
restore() { for f in $SRC; do cp "work/controls-bak/$(basename "$f")" "$f"; done; }
trap restore EXIT
run() {   # phases "U" = unit tests only
  if [ "$1" = U ]; then node --test test/worker.unit.test.mjs > work/controls-run.log 2>&1; return; fi
  if [ "$1" = W ]; then SANDBOX_FORK=1 timeout 600 node --test test/watch_paid.fork.test.mjs > work/controls-run.log 2>&1; return; fi
  SANDBOX_WORKER=1 SKIP_TRIM=1 PHASES=$1 timeout 1200 node --test --test-concurrency=1 test/worker.http.test.mjs > work/controls-run.log 2>&1; }
fails=0
mutant() {   # name phases [file old new]...
  local name=$1 phases=$2; shift 2
  if [ -n "${ONLY:-}" ] && [[ ",$ONLY," != *",$name,"* ]]; then return; fi    # ONLY=a,b runs just those mutants
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
mutant turnstile_off 5 worker/src/index.mjs "if (!demo && !(await turnstileOk(env, fields.token, ip)))" "if (false)"
mutant dev_gate_off 6 worker/src/limits.mjs "if (env.SANDBOX_DEV === '1' ? !local : cfg.rpc !== 'https://rpc-test.qday.info')" "if (false)"
mutant visitor_text_public 1 worker/src/do.mjs "kind, n: res.n, title: res.title," "kind, n: res.n, title: res.title + (text || ''),"
mutant queue_off 1 worker/src/do.mjs "const job = this.tail.then(() => this.run(kind, text));" "const job = this.run(kind, text);"
# --- review r1 (SECURITY-REVIEW-sandbox-r1.md)
mutant F1_visitor_ref_on_chain 1 lib/sandbox.mjs 'ref: `SBX-${n}`,' 'ref: proposed.reference || `SBX-${n}`,'
mutant F2_tsconfig_gate_off 6 worker/src/index.mjs "if (turnstileConfigError(env)) return refuse('tsconfig'" "if (false) return refuse('tsconfig'"
mutant F2_action_check_off U worker/src/limits.mjs "if (!devTest && d.action !== 'attack') return false;" ""
mutant F2_hostname_check_off U worker/src/limits.mjs "if (!devTest && d.hostname !== env.TURNSTILE_HOSTNAME) return false;" ""
mutant F2_test_key_check_off U worker/src/limits.mjs "if (!env.TURNSTILE_SECRET || TEST_KEY.test(env.TURNSTILE_SECRET))" "if (!env.TURNSTILE_SECRET)"
mutant F3_health_cache_off 1 worker/src/do.mjs "const HEALTH_TTL_MS = 30_000;" "const HEALTH_TTL_MS = 0;"
mutant F3_page_cache_off 1 worker/src/index.mjs "const PAGE_TTL_MS = 5_000;" "const PAGE_TTL_MS = 0;"
mutant F3_route_rate_limit_off 2 worker/src/index.mjs "if (!success) return html(" "if (false) return html("
mutant F3_health_error_string 6 worker/src/do.mjs "catch (e) { console.log(JSON.stringify({ ev: 'health_failed', name: e?.name })); }" "catch (e) { out.error = String(e?.message); }"
mutant F4_ipv6_not_grouped 2 worker/src/index.mjs "const key = ipKey(ip);" "const key = ipKey(ip) && ip;"
mutant F4_hour_cap_off 3 worker/src/do.mjs "if (hr.n >= L.globalHour)" "if (false)"
mutant F4_demo_any_token 3 worker/src/limits.mjs "return diff === 0;" "return true;"
mutant F5_any_revert_counts 1 lib/sandbox.mjs "if (!registeredPayee) {" "if (true) {"
mutant F5_session_check_off 8 worker/src/do.mjs "out.sessionsValid = exp.every((s) => s[0] > ts + SESSION_MARGIN_S && s[5] === false);" "out.sessionsValid = true;"
# (the explicit UNDECODED guard in refusal() is belt-and-braces: expect is now a fixed contract error name, so an UNDECODED
#  simulation can never match it; F5_any_revert_counts is the control for the fixed-expect rule)
mutant F6_amount_clamp_off 1 lib/sandbox.mjs "amt.length <= 12 && " "" lib/sandbox.mjs "units > 0n && units <= MAX_VISITOR_UNITS ? units" "units > 0n ? units"
mutant F7_symlink_check_off U worker/mkvars.mjs "if (lstatSync(out).isSymbolicLink()) die('--out is a symlink');" ""
mutant F8_no_recovery 7 worker/src/do.mjs "    this.recoverInterrupted();
  }" "  }"
mutant F8_no_running_row 7 worker/src/do.mjs "at, kind, 'running'," "at, kind, 'refused',"
# --- review round 2
mutant R2_1_net48_cap_off 3 worker/src/do.mjs "if (nh.n >= L.net48Hour)" "if (false)"
mutant R2_2_state_cache_off 1 worker/src/index.mjs "if (url.pathname === '/api/state') return cachedPage('/api/state', async () => JSON.stringify({ ...(await stub.state({ limit: 100 })), config: cfg }), jsonRaw);" "if (url.pathname === '/api/state') return json({ ...(await stub.state({ limit: 100 })), config: cfg });"
mutant R2_2_no_invalidation 1 worker/src/index.mjs "  pageCache.clear();     // this" "  // pageCache.clear();     // this"
# --- Paid watcher (condition 5) + the Paid ABI it uncovered (payeeAgentId is indexed in PayRunV2)
mutant W_watcher_abi_wrong W watch_paid.mjs "bytes32 invoiceRef, uint256 indexed agentId, address payee" "bytes32 invoiceRef, uint256 agentId, address payee"
mutant W_lib_abi_wrong W lib/sandbox.mjs "bytes32 invoiceRef, uint256 indexed agentId, address payee" "bytes32 invoiceRef, uint256 agentId, address payee"
mutant W_failed_read_is_ok W watch_paid.mjs "rc = 1; stateNow = 'ERROR'; fails++;" "rc = 0; stateNow = 'OK'; fails++;"
mutant W_seed_filter_too_wide W watch_paid.mjs "if (l.args.runId === BigInt(st.seed_run)) continue;" "continue;"
# --- missing controls named in r1
mutant origin_check_off 1 worker/src/index.mjs "if (origin !== null && origin !== url.origin)" "if (false)"
mutant body_cap_off 1 worker/src/index.mjs "if (n > max) { try { await reader.cancel(); } catch {} return null; }" "" worker/src/index.mjs "if (cl > max) return null;" ""
restore
[ "$(sha)" = "$ORIG" ] || { echo "RESTORE FAILED: sha differs" | tee -a "$LOG"; exit 2; }
if run 1,2,3,4,5,6,7,8 && run U && run W; then echo "RESTORED: HTTP phases 1-8 + unit + watcher GREEN, source sha $ORIG" | tee -a "$LOG"
else echo "RESTORED but NOT green" | tee -a "$LOG"; fails=$((fails+1)); fi
echo "controls done: $fails problem(s)" | tee -a "$LOG"
exit $(( fails > 0 ))
