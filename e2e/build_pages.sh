#!/usr/bin/env bash
# Static build of the approval page (docs/), hosted at https://clerk.swiftbotlab.workers.dev/. Read-only until a wallet connects; no keys, no server.
#   e2e/build_pages.sh [v1 report.json]        V2_WITH=<report> merges a real clerk run on PayRunV2 into docs/report-v2.json
set -euo pipefail; cd "$(dirname "$0")/.."
mkdir -p docs/vendor
cp web/index.html docs/index.html; cp web/app.js docs/app.js;
# The source page's CSP also allows the LOCAL fork RPC (http://127.0.0.1:8555, used by e2e/hold_local.sh and page_fork.sh). The hosted
# build drops it; PAGES_DEV=1 keeps it (local tests only, never deployed).
if [ "${PAGES_DEV:-0}" != 1 ]; then
  python3 -c "import sys;p='docs/index.html';s=open(p).read();o=' http://127.0.0.1:8555';assert s.count(o)==1,'dev origin not found once';open(p,'w').write(s.replace(o,''))"
fi
cp web/sim.js docs/sim.js; cp web/vendor/viem-2.21.0.js docs/vendor/
cp "${1:-e2e/film/report3.json}" docs/report.json; touch docs/.nojekyll
python3 e2e/report_v2.py docs/report-v2.json ${V2_WITH:+--with "$V2_WITH"}
# Response headers for Cloudflare static assets (the page also carries the same CSP as a meta tag; frame-ancestors only works here)
cat > docs/_headers <<'EOF'
/*
  Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self' https://rpc-test.qday.info; base-uri 'none'; form-action 'none'; object-src 'none'; frame-ancestors 'none'
  X-Content-Type-Options: nosniff
  Referrer-Policy: no-referrer
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()
  X-Frame-Options: DENY
EOF
python3 e2e/prerender.py docs/index.html
if [ "${PAGES_DEV:-0}" != 1 ] && grep -n '127\.0\.0\.1\|localhost' docs/index.html docs/_headers; then echo "FAIL: a local origin is in the production page's CSP"; exit 1; fi
echo "docs/ ready: index.html + app.js + report.json ($(python3 -c "import json;print(json.load(open('docs/report.json'))['payrun'])")) + report-v2.json + _headers"
