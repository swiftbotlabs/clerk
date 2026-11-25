// watch_paid.mjs against the LOCAL anvil fork (review condition 5). The fork state is snapshotted and restored, so the
// payments made here as positive controls never leak into the other suites.
// Run: SANDBOX_FORK=1 node --test test/watch_paid.fork.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, mkdtempSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createWalletClient, http, parseAbi } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { makeSandbox, PAYRUN_ABI } from '../lib/sandbox.mjs';
import { parseEventLogs } from 'viem';

const ROOT = new URL('..', import.meta.url).pathname;
const RPC = 'http://127.0.0.1:18546';
const skip = !process.env.SANDBOX_FORK || !existsSync(ROOT + 'work/fork-state.json');
const st = skip ? {} : JSON.parse(readFileSync(ROOT + 'work/fork-state.json', 'utf8'));
const keys = skip ? {} : JSON.parse(readFileSync(ROOT + 'work/fork-keys.json', 'utf8')).keys;

const watch = (dir, extra = []) => spawnSync('node', [ROOT + 'watch_paid.mjs', '--state', ROOT + 'work/fork-state.json', '--rpc', RPC, '--log', dir + '/paid.log', '--once', ...extra], { encoding: 'utf8', timeout: 120_000 });
const logOf = (dir) => readFileSync(dir + '/paid.log', 'utf8');

test('Paid watcher on the fork', { skip, timeout: 600_000 }, async (t) => {
  const S = makeSandbox({ rpc: RPC, chainId: 44005, payrun: st.payrun, registry: '0xF45E7f39Caba1d2055f613970575a7e7069636Be', token: '0x456569838f1d43009A91ebA4263147Afd7233483',
    keys: Object.fromEntries(['owner', 'clerk', 'revoked', 'expired', 'stranger', 'daycap', 'vendor_hijack', 'vendor_new'].map((k) => [k, keys[k]])),
    vendors: { acme: { id: st.acme_id, name: st.acme_name }, hijack: { id: st.hijack_id, name: st.hijack_name }, new: { id: st.new_id, name: st.new_name } },
    paidInvoiceHash: st.paid_invoice_hash, minBalanceWei: 1_000_000_000_000_000n });
  const snap = await S.pub.request({ method: 'evm_snapshot', params: [] });
  const dir = mkdtempSync(ROOT + 'work/watch-t-');
  try {
    await t.test('clean sandbox: rc 0, one OK line, blocks scanned, the seed payment ignored', () => {
      const r = watch(dir);
      assert.equal(r.status, 0, r.stdout + r.stderr);
      const lines = logOf(dir).trim().split('\n');
      assert.equal(lines.length, 1); assert.match(lines[0], /rc=0 state=OK head=\d+ scanned=[1-9]\d* treasury=90000/);
    });
    await t.test('a failed read is an ERROR (rc 1), not "nothing new"', () => {
      const d2 = mkdtempSync(ROOT + 'work/watch-e-');
      try {
        const r = spawnSync('node', [ROOT + 'watch_paid.mjs', '--state', ROOT + 'work/fork-state.json', '--rpc', 'http://127.0.0.1:1', '--log', d2 + '/paid.log', '--once'], { encoding: 'utf8', timeout: 120_000 });
        assert.equal(r.status, 1); assert.match(logOf(d2), /rc=1 state=ERROR fails=1/);
      } finally { rmSync(d2, { recursive: true, force: true }); }
    });
    await t.test('POSITIVE CONTROL: real payments on the fork raise ALERTs (control vendor and non-control vendor)', async () => {
      const owner = createWalletClient({ transport: http(RPC), account: privateKeyToAccount(keys.owner), chain: { id: 44005, name: 'fork', nativeCurrency: { name: 't', symbol: 't', decimals: 18 }, rpcUrls: { default: { http: [RPC] } } } });
      const pay = async (runId) => { const h = await owner.writeContract({ address: st.payrun, abi: PAYRUN_ABI, functionName: 'execute', args: [BigInt(runId)], gas: 400_000n }); return S.pub.waitForTransactionReceipt({ hash: h }); };
      // 1) the genuine control run, paid by the owner (the sandbox itself never does this)
      const g = await S.attack('genuine');
      const rc1 = await pay(g.steps.at(-1).runId);
      assert.equal(rc1.status, 'success');
      // the library's own ABI must decode a real Paid (blockedExecute relies on it to flag a payment as a fault)
      assert.equal(parseEventLogs({ abi: PAYRUN_ABI, logs: rc1.logs }).filter((l) => l.eventName === 'Paid').length, 1, 'lib PAYRUN_ABI decodes Paid');
      // 2) Hooli: owner confirms its current wallet, clerk stages, owner pays -> a payment to a NON-control vendor
      const dir0 = await S.directory();
      const admin = parseAbi(['function confirmPayee(uint256,address)']);
      await S.pub.waitForTransactionReceipt({ hash: await owner.writeContract({ address: st.payrun, abi: admin, functionName: 'confirmPayee', args: [BigInt(st.hijack_id), dir0.hijack.wallet], gas: 200_000n }) });
      const clerk = createWalletClient({ transport: http(RPC), account: privateKeyToAccount(keys.clerk), chain: owner.chain });
      const hs = await clerk.writeContract({ address: st.payrun, abi: PAYRUN_ABI, functionName: 'stage', gas: 400_000n,
        args: [[{ payeeAgentId: BigInt(st.hijack_id), payee: dir0.hijack.wallet, amount: 10_000n, invoiceHash: '0x' + 'ab'.repeat(32), invoiceRef: '0x' + '00'.repeat(32) }]] });
      assert.equal((await S.pub.waitForTransactionReceipt({ hash: hs })).status, 'success');
      const runId = await S.read('runCount');
      assert.equal((await pay(runId)).status, 'success');
      const r = watch(dir);
      assert.equal(r.status, 2, r.stdout + r.stderr);
      const log = logOf(dir);
      assert.match(log, /ALERT PAID to the control vendor \(Acme\)/);
      assert.match(log, /ALERT PAID TO NON-CONTROL VENDOR/);
      assert.match(log, /ALERT TREASURY DROPPED/);
      assert.match(r.stdout, /ALERT/);
      // the cursor moved: the same payments are not reported twice, but the treasury alert stays until fixed
      const r2 = watch(dir);
      assert.equal(r2.status, 2);
      const tail = logOf(dir).trim().split('\n').slice(-2).join('\n');
      assert.doesNotMatch(tail, /ALERT PAID/); assert.match(tail, /TREASURY DROPPED/);
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
    await S.pub.request({ method: 'evm_revert', params: [snap] });
  }
});
