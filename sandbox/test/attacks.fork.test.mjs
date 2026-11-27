// Every attack kind against the sandbox deployed on a LOCAL anvil fork of Aevum testnet (deploy.mjs --fork).
// Run: SANDBOX_FORK=1 node --test test/attacks.fork.test.mjs   (needs anvil on :18546 and work/fork-state.json)
// PayRunV3 sandbox (deploy.mjs --v3 --fork): SANDBOX_FORK=1 SANDBOX_FORK_RPC=http://127.0.0.1:18551 SANDBOX_FORK_STATE=<state> \
//   SANDBOX_FORK_KEYS=<keys> node --test test/attacks.fork.test.mjs   (the state's `version` picks the kinds and the key roles)
// Asserts per kind: the expected refusal landed as a real tx (reverted, or PaymentBlocked with nothing paid), no tUSD8 moved,
// and controls: a genuine invoice is ACCEPTED, and the owner guard refuses to send an execute that would pay.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { makeSandbox, KINDS, kindsFor, ROLES_FOR, ERC20_ABI, PAYRUN_ABI } from '../lib/sandbox.mjs';

const RPC = process.env.SANDBOX_FORK_RPC || 'http://127.0.0.1:18546', TUSD = '0x456569838f1d43009A91ebA4263147Afd7233483';
const STATE = process.env.SANDBOX_FORK_STATE || new URL('../work/fork-state.json', import.meta.url).pathname;
const KEYS = process.env.SANDBOX_FORK_KEYS || new URL('../work/fork-keys.json', import.meta.url).pathname;
const skip = !process.env.SANDBOX_FORK || !existsSync(STATE);
const st = skip ? {} : JSON.parse(readFileSync(STATE));
const keys = skip ? {} : JSON.parse(readFileSync(KEYS)).keys;
const VERSION = st.version || 'v2';
const KINDS_HERE = kindsFor(VERSION);

function sb() {
  return makeSandbox({ version: VERSION, rpc: RPC, chainId: 44005, payrun: st.payrun, registry: VERSION === 'v3' ? st.registry : '0xF45E7f39Caba1d2055f613970575a7e7069636Be', token: TUSD,
    keys: Object.fromEntries(ROLES_FOR[VERSION].map((k) => [k, keys[k]])),
    vendors: { acme: { id: st.acme_id, name: st.acme_name }, hijack: { id: st.hijack_id, name: st.hijack_name }, new: { id: st.new_id, name: st.new_name } },
    paidInvoiceHash: st.paid_invoice_hash, minBalanceWei: 1_000_000_000_000_000n });
}

test('attacks on the fork', { skip }, async (t) => {
  const S = sb();
  // the 'expired' session was granted for 120 s: move the fork's clock past it
  await S.pub.request({ method: 'evm_increaseTime', params: [200] }); await S.pub.request({ method: 'evm_mine', params: [] });
  const bal = async () => S.pub.readContract({ address: TUSD, abi: ERC20_ABI, functionName: 'balanceOf', args: [st.addresses.treasury] });
  const before = await bal();
  if (VERSION === 'v3') await t.test('v3 offers 18 kinds (15 + 3 signature attacks), v2 15', () => {
    assert.equal(Object.keys(KINDS_HERE).length, 18); assert.equal(Object.keys(kindsFor('v2')).length, 15);
  });
  for (const [kind, K] of Object.entries(KINDS_HERE)) {
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
  await t.test(VERSION === 'v3' ? 'V3: a visitor invoice naming the REGISTERED wallet is refused on chain (no Acme signature)'
    : 'CONTROL: a visitor invoice naming the REGISTERED wallet is accepted, not counted as a refusal', async () => {
    const dir = await S.directory();
    const txt = `ACME SUPPLIES LTD\nFrom: Acme Supplies Ltd\nInvoice No: INV-CTL-${Date.now()}\nDue date: 2026-12-18\nAmount due: 0.03 tUSD8\nPay to: ${dir.acme.wallet}`;
    const r = await S.attack('payee_swap', { text: txt });
    assert.equal(r.fault, false);
    if (VERSION === 'v3') { assert.equal(r.refused, true); assert.equal(r.steps.at(-1).error, 'VendorSignatureRequired'); }
    else { assert.equal(r.refused, false); assert.equal(r.steps.at(-1).status, 'success'); }
  });
  if (VERSION === 'v3') {
    await t.test("V3 CONTROL: with Acme's signedOnly switched off, the unsigned line would be ACCEPTED (so attack 15 is the contract's signedOnly rule)", async () => {
      const { createWalletClient, http, parseAbi } = await import('viem');
      const { privateKeyToAccount } = await import('viem/accounts');
      const chain = { id: 44005, name: 'f', nativeCurrency: { name: 't', symbol: 't', decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
      const w = createWalletClient({ chain, transport: http(RPC), account: privateKeyToAccount(keys.owner) });
      const abi = parseAbi(['function setSignedOnly(uint256,bool)']);
      const flip = async (on) => S.pub.waitForTransactionReceipt({ hash: await w.writeContract({ address: st.payrun, abi, functionName: 'setSignedOnly', args: [BigInt(st.acme_id), on], type: 'legacy' }) });
      await flip(false);
      try {
        const r = await S.attack('unsigned_invoice');
        assert.equal(r.refused, false, 'unsigned line must be accepted with signedOnly off');
        assert.equal(r.fault, true, 'simulation said WOULD SUCCEED, so nothing was sent (a fault, not a refusal)');
        assert.equal(r.steps.at(-1).sent, false);
      } finally { await flip(true); }
      assert.equal((await S.read('signedOnly', [BigInt(st.acme_id)])), true, 'restored');
    });
    await t.test('V3 CONTROL: the edited-amount line is ACCEPTED when Acme signs the edited amount (so the refusal is about the edit)', async () => {
      const dir = await S.directory();
      const { keccak256, stringToHex } = await import('viem');
      const l = { payeeAgentId: BigInt(st.acme_id), payee: dir.acme.wallet, amount: 50_000n, invoiceHash: keccak256(stringToHex('ctl-edit-' + Date.now())), invoiceRef: '0x' + '00'.repeat(32) };
      const { fn, args } = await S.stageCall([l]);    // Acme signs exactly 0.05
      assert.equal(fn, 'stageSigned');
      const sim = await S.simulate('clerk', fn, args);
      assert.equal(sim.ok, true, JSON.stringify(sim.error));
    });
  }
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
