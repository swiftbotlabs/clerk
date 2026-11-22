#!/usr/bin/env bash
# Adversarial-invoice eval, end to end on a local anvil chain (no network, no keys beyond anvil's public test keys).
#   ./run.sh [OUTDIR]   -> OUTDIR/corpus (160 invoices + truth.json), OUTDIR/result.json, OUTDIR/report.md
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:-$PWD/../work/adversarial}
rm -rf "$OUT/corpus"; mkdir -p "$OUT"
(cd ../../contracts && forge build >/dev/null)
python3 gen.py "$OUT/corpus" --seed 8004
python3 -u run_eval.py "$OUT/corpus" "$OUT/result.json" --mode both
python3 report.py "$OUT/result.json" > "$OUT/report.md"
cat "$OUT/report.md"
