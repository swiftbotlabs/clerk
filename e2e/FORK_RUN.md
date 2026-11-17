# Fork run (local copy of Aevum testnet, chain 440050, real ERC-8004 registry + real tUSD8)

Recorded 2026-11-17 09:48 UTC with `e2e/run_fork.sh` (rules extractor). Same flow as the testnet run, which
needs testnet tokens (`e2e/run_testnet.sh`). Hashes below are fork hashes, not testnet hashes.

```
vendors: Acme #1695 0xFF177e533c13BE4B13f34fa995eE4189BE199f29, Globex #1696 0x90F79bf6EB2c4f870365E785982E1f101E93b906
PayRun 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9
PAYABLE  MATCH        inv-acme-1001.txt                120.00  
BLOCK    MATCH        inv-acme-1002-redirect.txt         0.00  wallet is registered for vendor: failed
PAYABLE  MATCH        inv-acme-1003-big.txt            650.00 over the session cap: needs the owner 
HOLD     CLOSE_MATCH  inv-acmee-55.txt                   0.00  name is a close match to the registered 'Acme Supplies Ltd' (0.92): a human must confirm
PAYABLE  MATCH        inv-globex-g77.txt                80.50  
RUN staged 0x43a4f3f1ce72603d07102d6bb5167ec7b26eb88756dbe2070e0bbcdc3838bbba inv-acme-1001.txt,inv-globex-g77.txt 
--- second pass (idempotency: nothing may be staged twice)
PAYABLE  MATCH        inv-acme-1001.txt                120.00 already staged 
BLOCK    MATCH        inv-acme-1002-redirect.txt         0.00  wallet is registered for vendor: failed
PAYABLE  MATCH        inv-acme-1003-big.txt            650.00 over the session cap: needs the owner 
HOLD     CLOSE_MATCH  inv-acmee-55.txt                   0.00  name is a close match to the registered 'Acme Supplies Ltd' (0.92): a human must confirm
PAYABLE  MATCH        inv-globex-g77.txt                80.50 already staged 
--- the clerk tries to execute its own run
reverted: custom error 0x30cd7471, data: "0x30cd7471": NotOw
--- owner executes run 1 (treasury tUSD8 from a fork-only balance write)
tUSD8 balance slot: 11
executed
received (tUSD8 units): Acme +120000000  Globex +80500000  Mallory +0
--- reconcile Paid events against the ledger (INV-1002 is the redirect attempt: it must show UNPAID)
PAID_OK          INV-1001     expected    120.00 paid    120.00 0xcb3206c36646133e51e83050128e9827b8d9bde3cbe794ad42acd48be0501c0c
PAID_OK          G-77         expected     80.50 paid     80.50 0xcb3206c36646133e51e83050128e9827b8d9bde3cbe794ad42acd48be0501c0c
UNPAID           INV-1002     expected     95.00 paid      0.00 
--- executing the same run again
custom error 0xf6a05c58
```
