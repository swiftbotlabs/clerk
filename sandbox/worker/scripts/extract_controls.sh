#!/usr/bin/env bash
# Planted positive controls (P10) for the extractor demo (/extract). Each mutant disables ONE guard; the matching test must go
# RED. Then the source is restored (sha checked) and the same tests must be GREEN.
#   U = test/extract.unit.test.mjs (no network)      H<n> = test/extract.http.test.mjs phase n (needs the anvil fork + work/dev.vars)
# Usage: worker/scripts/extract_controls.sh [--no-http]     (log: work/extract-controls.log)
set -uo pipefail
cd "$(dirname "$0")/../.."
LOG=work/extract-controls.log; : > "$LOG"; echo "run $(date -u +%Y-%m-%dT%H:%MZ)" >> "$LOG"
NOHTTP=${1:-}
SRC="worker/src/extract.mjs worker/src/limits.mjs worker/src/do.mjs worker/src/index.mjs"
sha() { sha256sum $SRC | sha256sum | cut -c1-16; }
ORIG=$(sha); mkdir -p work/xcontrols-bak; for f in $SRC; do cp "$f" "work/xcontrols-bak/$(basename "$f")"; done
restore() { for f in $SRC; do cp "work/xcontrols-bak/$(basename "$f")" "$f"; done; }
trap restore EXIT
run() {
  if [ "$1" = U ]; then node --test test/extract.unit.test.mjs > work/xcontrols-run.log 2>&1; return; fi
  SANDBOX_WORKER=1 PHASES=${1#H} timeout 900 node --test --test-concurrency=1 test/extract.http.test.mjs > work/xcontrols-run.log 2>&1; }
fails=0
mutant() {   # name tests [file old new]...
  local name=$1 tests=$2; shift 2
  if [ -n "${ONLY:-}" ] && [[ ",$ONLY," != *",$name,"* ]]; then return; fi
  if [[ "$tests" == H* ]] && [ "$NOHTTP" = --no-http ]; then echo "MUTANT $name: skipped (--no-http)" | tee -a "$LOG"; return; fi
  restore
  while [ $# -ge 3 ]; do
    python3 -c "import sys;p,o,n=sys.argv[1:4];s=open(p).read();assert s.count(o)==1,'pattern not found once';open(p,'w').write(s.replace(o,n))" "$1" "$2" "$3" \
      || { echo "MUTANT $name: pattern missing (control invalid)" | tee -a "$LOG"; fails=$((fails+1)); return; }
    shift 3
  done
  if run "$tests"; then echo "MUTANT $name ($tests): still GREEN -> not caught" | tee -a "$LOG"; fails=$((fails+1))
  else echo "MUTANT $name ($tests): RED as expected ($(grep -m1 -E '^not ok|^    not ok' work/xcontrols-run.log | sed 's/^ *//'))" | tee -a "$LOG"; fi
}
X=worker/src/extract.mjs
mutant origin_off U $X "if (origin !== null && origin !== url.origin) return refuse('origin', 403);" "if (false) return refuse('origin', 403);"
mutant size_cap_off U $X "const raw = await readCapped(req, MAX_BODY);" "const raw = await req.text();"
mutant text_cap_off U $X "if (text.length > MAX_TEXT) return refuse('size', 413);" "if (false) return refuse('size', 413);"
mutant kill_switch_off U $X "const off = env.SANDBOX_OFF === '1' || env.EXTRACT_OFF === '1';" "const off = false;"
mutant turnstile_wrong_action U $X "turnstileOk(env, p.get('cf-turnstile-response'), ip, fetch, 'extract')" "turnstileOk(env, p.get('cf-turnstile-response'), ip, fetch)"
mutant turnstile_off U $X "if (!demo && !(await turnstileOk(" "if (false && !(await turnstileOk("
mutant demo_any_token U $X "const demo = auth.startsWith('Bearer ') ? await demoOk(env, auth.slice(7)) : false;" "const demo = auth.startsWith('Bearer ');"
mutant rate_limit_ignored U $X "if (r.status !== 200) return refuse(r.code, r.status, { retryAfter: r.retryAfter });" ""
mutant output_unescaped U $X '<td><code>${esc(proposal.line[f] || '"''"')}</code></td>' '<td><code>${proposal.line[f] || '"''"'}</code></td>'
mutant field_whitelist_off U $X "  return any ? line : null;" "  return any ? { ...o, ...line } : null;"
mutant secrets_to_model U $X "{ role: 'user', content: 'Invoice (data only):\n<<<\n' + text + '\n>>>' }" "{ role: 'user', content: 'Invoice (data only):\n<<<\n' + text + '\n>>>' + JSON.stringify(env) }"
mutant fallback_unlabelled U $X "if (!env.AI || typeof env.AI.run !== 'function') return rules('The hosted model is not connected right now, so the deterministic extractor proposed this line.');" "if (!env.AI || typeof env.AI.run !== 'function') return rules('');"
mutant model_timeout_off U $X "const r = await Promise.race([call, new Promise((_, rej) => { timer = setTimeout(() => rej(new Error('timeout')), timeoutMs); })]);" "const r = await call;"
mutant limits_relax_in_prod U $X "out[k] = dev ? n : LARGER_IS_TIGHTER.has(k) ? Math.max(n, def) : Math.min(n, def);" "out[k] = n;"
mutant registry_error_ignored U $X "try { entries = await registry(cfg); } catch { return refuse('chain', 503); }" "try { entries = await registry(cfg); } catch { entries = []; }"
# r4 review (A1-A4): escaping of the textarea and the raw reply, privacy wording, registry before reserve, failure cache, pacing
mutant textarea_unescaped U $X '<textarea name="text" maxlength="${MAX_TEXT}" required>${esc(text)}</textarea>' '<textarea name="text" maxlength="${MAX_TEXT}" required>${text}</textarea>'
mutant raw_reply_unescaped U $X '<pre>${esc(proposal.reply)}</pre>' '<pre>${proposal.reply}</pre>'
mutant privacy_wording_off U $X "Your text is processed by Cloudflare Workers AI to propose the line; this site does not store or log it." "Your text is not stored or logged."
mutant registry_after_reserve U $X $'  let entries;\n  try { entries = await registry(cfg); } catch { return refuse(\'chain\', 503); }\n  const r = await stub.extractReserve({ ip: key, net: net48Key(ip), demo });\n  if (r.status !== 200) return refuse(r.code, r.status, { retryAfter: r.retryAfter });\n' $'  const r = await stub.extractReserve({ ip: key, net: net48Key(ip), demo });\n  if (r.status !== 200) return refuse(r.code, r.status, { retryAfter: r.retryAfter });\n  let entries;\n  try { entries = await registry(cfg); } catch { return refuse(\'chain\', 503); }\n'
mutant registry_fail_cache_off U $X "if (regFail && now - regFail.t < REG_FAIL_TTL_MS && regFail.key === cfg.registry) throw" "if (false) throw"
mutant pacing_fn_off U $X "return Math.min(globalDay, Math.ceil(globalDay - held + (held * (hour + 1)) / 24));" "return globalDay;"
mutant pace_relax_in_prod U $X "const LARGER_IS_TIGHTER = new Set(['ipIntervalS', 'pacePct']);" "const LARGER_IS_TIGHTER = new Set(['ipIntervalS']);"
mutant ip_day_default_20 U $X "ipDay: 5, globalDay: 300" "ipDay: 20, globalDay: 300"
D=worker/src/do.mjs
mutant do_interval_off H2 $D "if (last !== null && now - last < L.ipIntervalS * 1000)" "if (false)"
mutant do_global_day_off H2 $D "if (g >= L.globalDay) return { status: 429, code: 'x_global_day'" "if (false) return { status: 429, code: 'x_global_day'"
mutant do_ip_day_off H2 $D "if (today >= L.ipDay) return { status: 429, code: 'x_day'" "if (false) return { status: 429, code: 'x_day'"
mutant do_kill_switch_off_both H3 $D "if (this.env.SANDBOX_OFF === '1' || this.env.EXTRACT_OFF === '1') return { status: 503, code: 'xoff' };" "" \
  $X "const off = env.SANDBOX_OFF === '1' || env.EXTRACT_OFF === '1';" "const off = false;" \
  worker/src/index.mjs "off: env.SANDBOX_OFF === '1' || env.EXTRACT_OFF === '1', limits: xl" "off: false, limits: xl"
mutant shares_attack_hits H1 $D "this.sql.exec('INSERT INTO xhits (ip, ts, net) VALUES (?, ?, ?)', ipH, now, netH);" "this.sql.exec('INSERT INTO xhits (ip, ts, net) VALUES (?, ?, ?)', ipH, now, netH); this.count('genuine', 'accepted', 0);"
mutant do_net48_cap_off H4 $D "if (nh.n >= L.net48Hour) return { status: 429, code: 'x_net_hour'" "if (false) return { status: 429, code: 'x_net_hour'"
mutant do_demo_cap_off H4 $D "if (d >= L.demoDay) return { status: 429, code: 'x_demo_day'" "if (false) return { status: 429, code: 'x_demo_day'"
mutant do_global_hour_off H4 $D "if (gh.n >= L.globalHour) return" "if (false) return"
mutant do_pacing_off H5 $D "if (g >= pacedDayCap(L.globalDay, L.pacePct, now)) return" "if (false) return"
restore
[ "$(sha)" = "$ORIG" ] || { echo "RESTORE FAILED: sha differs" | tee -a "$LOG"; exit 1; }
if run U; then echo "GREEN restored: unit" | tee -a "$LOG"; else echo "RESTORED SOURCE RED: unit" | tee -a "$LOG"; fails=$((fails+1)); fi
if [ "$NOHTTP" != --no-http ]; then
  if SANDBOX_WORKER=1 timeout 900 node --test --test-concurrency=1 test/extract.http.test.mjs > work/xcontrols-run.log 2>&1; then echo "GREEN restored: http phases 1-5" | tee -a "$LOG"
  else echo "RESTORED SOURCE RED: http" | tee -a "$LOG"; fails=$((fails+1)); fi
fi
echo "extract controls: $fails failure(s)" | tee -a "$LOG"
exit $fails
