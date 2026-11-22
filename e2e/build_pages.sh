#!/usr/bin/env bash
# Static build of the approval page (docs/), hosted at https://clerk.swiftbotlab.workers.dev/. Read-only until a wallet connects; no keys, no server.
set -euo pipefail; cd "$(dirname "$0")/.."
mkdir -p docs; cp web/index.html docs/index.html; mkdir -p docs/vendor; cp web/vendor/viem-2.21.0.js docs/vendor/; cp "${1:-e2e/film/report3.json}" docs/report.json; touch docs/.nojekyll
python3 e2e/prerender.py docs/index.html
echo "docs/ ready: index.html + report.json ($(python3 -c "import json;print(json.load(open('docs/report.json'))['payrun'])"))"
