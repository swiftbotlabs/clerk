# Clerk public sandbox: try to make Clerk pay the wrong payee

Live: https://clerk-sandbox.swiftbotlab.workers.dev/ · its own PayRunV2 on Aevum testnet:
[`0x8034c01b…`](https://explorer-test.qday.info/address/0x8034c01ba98d882abd30118235d648183d3fae52), with three vendors registered in the
real ERC-8004 registry.

Pick an attack, optionally paste your own invoice text, and the sandbox sends the attempt as a real Aevum testnet transaction, then shows
the contract's answer with its explorer link.

## The 14 attack kinds (and the control)
Payee swap ("we have new bank details"), look-alike vendor, prompt injection, over the run cap, split to dodge the day cap, re-sending a
paid invoice, the clerk's key calling `execute`, a revoked key, an expired key, a key with no session, the vendor's wallet hijacked after
staging, a brand-new payee with no owner confirmation, a duplicate line in one run, and a zero amount. A genuine invoice to the registered
wallet is the control and is accepted.

## Seeded on 25 Nov through the public page (by us, to start the log)
15 attempts, 14 refused on chain with the expected error (PayeeNotRegistered, RunCapExceeded, DayCapExceeded, AlreadyPaid, NotOwner,
SessionRevokedErr, SessionExpired, NoSession, AlreadyStaged, ZeroAmount; the hijack and the new payee are executed by the owner and the
contract emits `PaymentBlocked` instead of paying), the genuine control accepted, 0 faults, the 0.09 test tUSD8 treasury untouched.
Example refusal: [PayeeNotRegistered](https://explorer-test.qday.info/tx/0x69b797d7c6f63532cc0ef4dcf6aa22ae6740006e654d5d4d6eaa90b41ec05dfb).
The deployment record is `sandbox-testnet.json`.

## Safety
- Visitor text never reaches the chain: the on-chain reference is always `SBX-n`, and an address you paste is replaced by a fresh random
  one. The owner's key only executes a run staged in the same attempt, and only after a simulation shows it would pay nothing.
- Abuse limits: Turnstile, one attempt a minute per visitor, hourly and daily caps, a kill switch, and a read-only watcher
  (`watch_paid.mjs`) that alerts on any `Paid` event from the sandbox contract.
- Two security reviews before launch; 35 deliberately broken builds each fail the tests (`worker/scripts/controls.sh`).

## PayRunV3 mode (vendor-signed invoices, our own vendor registry)
The same Worker and library also run a sandbox on PayRunV3 with its own `VendorRegistry` (`node deploy.mjs --v3 ...`; the state
file's `version` picks the mode). Acme is `signedOnly`: every Acme line the sandbox stages carries Acme's EIP-712 signature, and three
more attacks try to get past that: an unsigned invoice (`VendorSignatureRequired`), a signature by another key and an amount raised
after the vendor signed (both `BadVendorSignature`). Wallet changes are made by the registry's owner (the payer's vendor file edited),
and PayRunV3's hold still blocks them. In this mode the attempts go to their own log; the PayRunV2 sandbox's log stays readable at
`/history/v2`. Tested on a fork of Aevum testnet: `test/attacks.fork.test.mjs` (state `version: v3`) and `test/worker.v3.http.test.mjs`.

## Layout
| Path | What it does |
|---|---|
| `lib/` | JS port of the clerk's checks (parity-tested against `agent/check.py`) and the attack library |
| `worker/` | Cloudflare Worker + one Durable Object (serialised sends, SQLite log and counts, rate limits), server-rendered page |
| `deploy.mjs` | Idempotent deploy of the sandbox contracts and vendors (testnet or a local fork; `--v3` for PayRunV3 + VendorRegistry) |
| `sign_invoice.mjs` | The vendor's side of a PayRunV3 invoice: signs a document's line (EIP-712) and checks it with the contract's `checkInvoice` |
| `watch_paid.mjs` | Read-only watcher: one log line per check, alerts on any `Paid` other than the seed run |
| `test/` | Unit, fork and HTTP tests (HTTP tests run the Worker locally against an anvil fork) |
