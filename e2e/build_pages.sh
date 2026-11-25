#!/usr/bin/env bash
# Static build of the approval page (docs/), hosted at https://clerk.swiftbotlab.workers.dev/. Read-only until a wallet connects; no keys, no server.
#   e2e/build_pages.sh [v1 report.json]        V2_WITH=<report> merges a real clerk run on PayRunV2 into docs/report-v2.json
set -euo pipefail; cd "$(dirname "$0")/.."
mkdir -p docs/vendor
cp web/index.html docs/index.html; cp web/app.js docs/app.js; cp web/vendor/viem-2.21.0.js docs/vendor/
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
echo "docs/ ready: index.html + app.js + report.json ($(python3 -c "import json;print(json.load(open('docs/report.json'))['payrun'])")) + report-v2.json + _headers"
