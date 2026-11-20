#!/usr/bin/env bash
# Static build of the approval page for GitHub Pages (main branch, /docs). Read-only until a wallet connects; no keys, no server.
set -euo pipefail; cd "$(dirname "$0")/.."
mkdir -p docs; cp web/index.html docs/index.html; cp "${1:-e2e/film/report3.json}" docs/report.json; touch docs/.nojekyll
echo "docs/ ready: index.html + report.json ($(python3 -c "import json;print(json.load(open('docs/report.json'))['payrun'])"))"
