# Clerk

**Accounts payable with an AI clerk that can't be talked into paying the wrong person.** Built on Aevum testnet (chain 44005) with tUSD8 and the ERC-8004 identity registry.

Invoice-redirection fraud ("we have new bank details, pay this account instead") is the most common way businesses lose money on payables, and AI agents now read the invoices. Clerk lets an AI do the reading and the paperwork while the rules, not the model, decide who gets paid:

- The clerk's key can only **stage** a pay run: under a per-run cap and a per-day cap, before it expires, and only to the wallet each vendor **registered** for its ERC-8004 identity (Confirmation of Payee, checked on chain).
- Every amount, invoice number and due date the model proposes must appear in the invoice itself, and an invoice that names a look-alike of the vendor is held for a human.
- The owner approves a run with one transaction. Execution re-checks every payee against the registry, pays each invoice at most once (ever), and is all-or-nothing.
- The reconciler matches `Paid` events to the ledger and flags anything unpaid, unexpected, short or duplicated.

```mermaid
flowchart LR
  A[Invoices: email, text, CSV] --> B[LLM extractor\nno tools, proposes only]
  B --> C{check.py\nnumbers in source?\nregistered wallet?\nname match?}
  C -- BLOCK / HOLD --> H[Human queue]
  C -- PAYABLE --> D[stage.py\ndedupe, pack under caps,\nsimulate, send]
  D -- session key: stage() only --> E[(PayRun on Aevum)]
  R[(ERC-8004 registry)] -. getAgentWallet .-> E
  F[Owner: approval page] -- execute / reject --> E
  E -- Paid events --> G[reconcile.py vs ledger]
```

## What is in the repo
| Path | What it does |
|---|---|
| `contracts/src/PayRun.sol` | Staging-only session keys (expiry, per-run cap, per-day cap, revoke), `stage()` with on-chain Confirmation of Payee, pay-once invoices, owner `execute()` / `reject()`, 7-day run expiry, `headroom()` view. Shanghai EVM. |
| `contracts/test/` | 9 unit tests + fork tests against the real Aevum ERC-8004 registry, EntryPoint v0.7 and Kernel v3.1 |
| `agent/check.py` | Fail-closed checks between an invoice and the line a model proposed (12 tests) |
| `agent/stage.py` | `plan` / `stage`: extract, check, dedupe by `keccak256(file)` on chain, pack within the key's headroom, simulate, send with retries and a landed-check (idempotent) |
| `agent/reconcile.py` | `Paid` events in 1,000-block chunks, matched to `ledger.csv` |
| `web/index.html` | Approval page: each staged line with the invoice line behind every number, held and stopped invoices, approve or reject from the owner's wallet |
| `e2e/run_fork.sh` | The whole flow on a local fork of Aevum testnet (real registry, real tUSD8) |

## The owner is a smart account (ERC-4337, Kernel v3.1 on Aevum)
`contracts/test/fork/KernelOwnerFork.t.sol` runs on a fork of Aevum testnet with Aevum's own deployed contracts: EntryPoint v0.7
(`0x0000000071727De22E5E9d8BAf0edAc6f37da032`), Kernel v3.1 factory (`0xaac5D4240AF87249B3f71BC8E4A2cae074A3E419`) and
implementation (`0xBAC849bB641841b44E965fB01A4Bf5F074f84b4D`), Kernel's ECDSA validator (`0x845ADb2C711129d4f3966735eD98a9F09fC4cE57`).
- A Kernel account is both the PayRun owner and the treasury that holds the tUSD8.
- One **batched UserOperation** approves PayRun and grants the agent's staging-only session key (expiry, per-run cap, per-day cap).
- The agent stages a run; it cannot execute it. A second UserOperation from the account executes the run and pays the registered wallet.
- A UserOperation signed by any other key is refused by the EntryPoint (`AA24 signature error`), and the owner's signing key on its own
  cannot call PayRun: only the account can. (Planted control: signing the pay UserOperation with a stranger's key turns the test red.)

## Safety and controls
| Risk | Control | Where |
|---|---|---|
| Compromised or prompt-injected agent pays an attacker | The agent's key cannot move money; it can only stage, and only to registered wallets | `PayRun.stage`, `_checkPayee` |
| Runaway spending | Per-run and per-day caps, expiry, instant revoke | `grantSession`, `revokeSession` |
| Hallucinated amounts or references | Every value must appear in the source document | `check.py` |
| Look-alike vendor ("Acme Suppiles Ltd") | Held for a human | `check.py` |
| Vendor wallet hijacked after staging | `execute` re-checks every payee and reverts the run | `PayRun.execute` |
| Paying the same invoice twice | `paidInRun` / `stagedInRun` per invoice hash; stage.py checks before sending | `PayRun`, `stage.py` |
| Partial payment runs | All-or-nothing execution | `PayRun.execute` |
| Stale approvals | A staged run expires after 7 days | `RUN_TTL` |
| Audit | `Paid(runId, line, invoiceHash, ref, payeeAgentId, payee, amount)` + reconciliation | `reconcile.py` |

## Run it
Requirements: Foundry (`forge`, `cast`, `anvil`), Python 3.11+, a Solidity 0.8.24+ compiler (set `solc` in `contracts/foundry.toml`).

```bash
cd contracts && forge test                                   # unit tests
forge test --match-path 'test/fork/*' --fork-url https://rpc-test.qday.info   # against the real registry
cd ../agent/tests && python3 test_check.py                   # check.py
cd ../../e2e && ./run_fork.sh                                 # full flow on a local fork (chain 440050)
EXTRACTOR=llm ./run_fork.sh                                   # same, with the LLM extractor (needs CLERK_LLM_URL)
```

Environment: `AEVUM_RPC` (default `https://rpc-test.qday.info`), `AEVUM_REGISTRY` (default the testnet registry), `PAYRUN` (deployed address),
`CLERK_LLM_URL` (any OpenAI-compatible chat endpoint; default a local llama.cpp server on 127.0.0.1:8091), `CLERK_LLM_MODEL`, `CLERK_LLM_KEY`,
`CLERK_PASSWORD_FILE` (keystore password for the session key).

## Aevum testnet
| | |
|---|---|
| Chain | 44005, RPC https://rpc-test.qday.info, explorer https://explorer-test.qday.info |
| tUSD8 | `0x456569838f1d43009A91ebA4263147Afd7233483` (6 decimals) |
| ERC-8004 identity registry | `0xF45E7f39Caba1d2055f613970575a7e7069636Be` |
| PayRun | _deploying_ |

## Limits and next steps
- The owner runs as a Kernel v3.1 smart account in the fork tests; the testnet runner still uses a plain owner key. The agent's session key lives in PayRun (`grantSession`); a Kernel permission validator could hold it inside the account instead.
- The daily cap counts staged amounts (rejected runs still count), which is deliberately conservative.
- PDF and image invoices need a text layer first (pdftotext / OCR) before `check.py` can verify numbers.

## Credits
forge-std (MIT/Apache-2.0). Local model for the demo extractor: Qwen3-1.7B (Apache-2.0) via llama.cpp. Network facts from the Aevum Starter Kit docs (MIT, PQA Labs). MIT licensed.
