# One-command checks for judges. Needs Node 18+, Python 3; `local-eval` also needs Foundry (forge, anvil).
.PHONY: judge-rerun judge-rerun-v3 local-eval
JUDGE_RPC ?= https://rpc-test.qday.info

# Read-only: re-reads every transaction of the published testnet eval from https://rpc-test.qday.info and re-derives the
# outcome table from the chain. No keys, no sends. Compares the deployed PayRunV2 code too when Foundry is installed.
judge-rerun:
	@command -v forge >/dev/null 2>&1 && (cd contracts && forge build >/dev/null 2>&1) || echo "(forge not found: bytecode comparison skipped)"
	cd sandbox && ( [ -d node_modules/viem ] || npm ci --omit=dev --no-audit --no-fund ) && node judge_rerun.mjs --report ../e2e/adversarial/testnet-eval.json --rpc $(JUDGE_RPC)

# The same check for the PayRunV3 run (vendor-signed invoices: the attacks PayRunV2 could only stop off chain, refused on chain).
judge-rerun-v3:
	@command -v forge >/dev/null 2>&1 && (cd contracts && forge build >/dev/null 2>&1) || echo "(forge not found: bytecode comparison skipped)"
	cd sandbox && ( [ -d node_modules/viem ] || npm ci --omit=dev --no-audit --no-fund ) && node judge_rerun.mjs --report ../e2e/adversarial/testnet-eval-v3.json --rpc $(JUDGE_RPC)
	python3 e2e/adversarial/b_compare.py e2e/adversarial/testnet-eval.json e2e/adversarial/testnet-eval-v3.json --md

# The same 160-invoice attack set, unscaled, on a local anvil chain (a few minutes): writes e2e/work/adversarial/report.md
local-eval:
	e2e/adversarial/run.sh
