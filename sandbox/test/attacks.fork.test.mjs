// Every attack kind against the sandbox deployed on a LOCAL anvil fork of Aevum testnet (deploy.mjs --fork).
// Run: SANDBOX_FORK=1 node --test test/attacks.fork.test.mjs   (needs anvil on :18546 and work/fork-state.json)
// Asserts per kind: the expected refusal landed as a real tx (reverted, or PaymentBlocked with nothing paid), no tUSD8 moved,
// and controls: a genuine invoice is ACCEPTED, and the owner guard refuses to send an execute that would pay.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { makeSandbox, KINDS, ERC20_ABI, PAYRUN_ABI } from '../lib/sandbox.mjs';

const RPC = 'http://127.0.0.1:18546', TUSD = '0x456569838f1d43009A91ebA4263147Afd7233483';
const skip = !process.env.SANDBOX_FORK || !existsSync(new URL('../work/fork-state.json', import.meta.url));
const st = skip ? {} : JSON.parse(readFileSync(new URL('../work/fork-state.json', import.meta.url)));
const keys = skip ? {} : JSON.parse(readFileSync(new URL('../work/fork-keys.json', import.meta.url))).keys;

function sb() {
  return makeSandbox({ rpc: RPC, chainId: 44005, payrun: st.payrun, registry: '0xF45E7f39Caba1d2055f613970575a7e7069636Be', token: TUSD,
    keys: Object.fromEntries(['owner', 'clerk', 'revoked', 'expired', 'stranger', 'daycap', 'vendor_hijack', 'vendor_new'].map((k) => [k, keys[k]])),
    vendors: { acme: { id: st.acme_id, name: st.acme_name }, hijack: { id: st.hijack_id, name: st.hijack_name }, new: { id: st.new_id, name: st.new_name } },
    paidInvoiceHash: st.paid_invoice_hash, minBalanceWei: 1_000_000_000_000_000n });
}

test('attacks on the fork', { skip }, async (t) => {
  const S = sb();
  // the 'expired' session was granted for 120 s: move the fork's clock past it
  await S.pub.request({ method: 'evm_increaseTime', params: [200] }); await S.pub.request({ method: 'evm_mine', params: [] });
  const bal = async () => S.pub.readContract({ address: TUSD, abi: ERC20_ABI, functionName: 'balanceOf', args: [st.addresses.treasury] });
  const before = await bal();
  for (const [kind, K] of Object.entries(KINDS)) {
    await t.test(`${K.n}. ${kind}`, async () => {
      const r = await S.attack(kind);
      assert.equal(r.fault, false, JSON.stringify(r.steps, null, 1));
      if (K.control) { assert.equal(r.accepted, true); assert.equal(r.steps.at(-1).status, 'success'); return; }
      assert.equal(r.refused, true, JSON.stringify(r, null, 1));
      const last = r.steps.at(-1);
      assert.ok(last.hash && last.sent, 'a real tx was sent');
      if (K.expect.startsWith('PaymentBlocked')) assert.match(last.error, new RegExp(`reason ${K.expect.split(':')[1]}`));
      else { assert.equal(last.status, 'reverted'); assert.equal(last.error, K.expect); }
      if (K.invoice) assert.ok(['HOLD', 'BLOCK'].includes(r.offchain.decision), `off-chain checks should not pass ${kind}: ${r.offchain.decision}`);
    });
  }
  await t.test('each kind twice more (repeatable, no state wear-out)', async () => {
    for (const kind of ['hijack_after_staging', 'new_payee_unconfirmed', 'split_day_cap', 'resend_paid'])
      for (let i = 0; i < 2; i++) { const r = await S.attack(kind); assert.equal(r.refused, true, `${kind} #${i}: ${JSON.stringify(r.steps)}`); }
  });
  await t.test('nothing left the treasury', async () => assert.equal(await bal(), before));

  // ---- controls: the tests above must be able to fail
  await t.test('CONTROL: a visitor invoice naming the REGISTERED wallet is accepted, not counted as a refusal', async () => {
    const dir = await S.directory();
    const txt = `ACME SUPPLIES LTD\nFrom: Acme Supplies Ltd\nInvoice No: INV-CTL-${Date.now()}\nDue date: 2026-12-18\nAmount due: 0.03 tUSD8\nPay to: ${dir.acme.wallet}`;
    const r = await S.attack('payee_swap', { text: txt });
    assert.equal(r.refused, false); assert.equal(r.fault, false); assert.equal(r.steps.at(-1).status, 'success');
  });
  await t.test('CONTROL: the owner guard never sends an execute that would pay', async () => {
    const g = await S.attack('genuine');
    const runId = BigInt(g.steps.at(-1).runId);
    assert.equal((await S.read('canExecute', [runId]))[0], true, 'the control run is payable, so the guard matters');
    const n0 = await S.pub.getTransactionCount({ address: S.acct.owner.address });
    const b0 = await bal();
    const r = await S.blockedExecute('guard probe', runId, 1);
    assert.equal(r.sent, false); assert.equal(r.fault, true); assert.match(r.simulated, /WOULD PAY/);
    assert.equal(await S.pub.getTransactionCount({ address: S.acct.owner.address }), n0, 'owner sent nothing');
    assert.equal(await bal(), b0);
  });
});
