// No-wallet simulation for the approval page: "what approving would do", computed by eth_call against the LIVE PayRunV2.
// For one eth_call the owner's address gets the code of contracts/src/sim/DemoProbe.sol (a state override), so every call
// below runs with msg.sender == owner, exactly like the owner's own approval, and nothing is kept: no key, no signature, no
// transaction, no state change. The page labels every result as a simulation.
import { encodeFunctionData, decodeFunctionResult, decodeErrorResult, parseAbi, keccak256, stringToHex, toHex } from './vendor/viem-2.21.0.js';

// forge build: contracts/src/sim/DemoProbe.sol, deployedBytecode (checked against the artifact by e2e/test_sim.mjs)
export const PROBE_CODE = '0x608060405234801561000f575f5ffd5b5060043610610029575f3560e01c8063d39ed69e1461002d575b5f5ffd5b61004061003b366004610385565b610056565b60405161004d9190610465565b60405180910390f35b60608567ffffffffffffffff8111156100715761007161051b565b6040519080825280602002602001820160405280156100d557816020015b6100c26040518060a001604052805f15158152602001606081526020015f81526020015f81526020015f60ff1681525090565b81526020019060019003908161008f5790505b5090505f5b8681101561023f575f5f8a6001600160a01b03168a8a858181106101005761010061052f565b90506020028101906101129190610543565b60405161012092919061058d565b5f604051808303815f865af19150503d805f8114610159576040519150601f19603f3d011682016040523d82523d5f602084013e61015e565b606091505b5091509150818484815181106101765761017661052f565b602090810291909101015190151590528351819085908590811061019c5761019c61052f565b6020026020010151602001819052506101b5888861024b565b8484815181106101c7576101c761052f565b602002602001015160400181815250506101e1888761024b565b8484815181106101f3576101f361052f565b6020026020010151606001818152505061020d8b86610315565b84848151811061021f5761021f61052f565b602090810291909101015160ff90911660809091015250506001016100da565b50979650505050505050565b6040516001600160a01b0382811660248301525f91829182919086169060440160408051601f198184030181529181526020820180516001600160e01b03166370a0823160e01b179052516102a0919061059c565b5f60405180830381855afa9150503d805f81146102d8576040519150601f19603f3d011682016040523d82523d5f602084013e6102dd565b606091505b50915091508180156102f157506020815110155b1561030d578080602001905181019061030a91906105b7565b92505b505092915050565b5f5f5f846001600160a01b03168460405160240161033591815260200190565b60408051601f198184030181529181526020820180516001600160e01b0316632b99bd5f60e21b179052516102a0919061059c565b80356001600160a01b0381168114610380575f5ffd5b919050565b5f5f5f5f5f5f5f60c0888a03121561039b575f5ffd5b6103a48861036a565b9650602088013567ffffffffffffffff8111156103bf575f5ffd5b8801601f81018a136103cf575f5ffd5b803567ffffffffffffffff8111156103e5575f5ffd5b8a60208260051b84010111156103f9575f5ffd5b6020919091019650945061040f6040890161036a565b935061041d6060890161036a565b925061042b6080890161036a565b96999598509396929591949193505060a09091013590565b5f5b8381101561045d578181015183820152602001610445565b50505f910152565b5f602082016020835280845180835260408501915060408160051b8601019250602086015f5b8281101561050f57603f198786030184528151805115158652602081015160a0602088015280518060a08901526104c98160c08a0160208501610443565b604083810151908901526060808401519089015260809283015160ff169288019290925250601f01601f191690940160c00193602093840193919091019060010161048b565b50929695505050505050565b634e487b7160e01b5f52604160045260245ffd5b634e487b7160e01b5f52603260045260245ffd5b5f5f8335601e19843603018112610558575f5ffd5b83018035915067ffffffffffffffff821115610572575f5ffd5b602001915036819003821315610586575f5ffd5b9250929050565b818382375f9101908152919050565b5f82516105ad818460208701610443565b9190910192915050565b5f602082840312156105c7575f5ffd5b505191905056fea264697066735822122090b306270426e0a701f978f666d8a6859d9597958b886bcb6f0693a961391ddd64736f6c63430008220033';
export const SIM_ABI = parseAbi([
  'struct Line { uint256 payeeAgentId; address payee; uint128 amount; bytes32 invoiceHash; bytes32 invoiceRef; }',
  'struct Step { bool ok; bytes ret; uint256 payeeBalance; uint256 treasuryBalance; uint8 runStatus; }',
  'function simulate(address payrun, bytes[] calls, address token, address payee, address treasury, uint256 runId) returns (Step[])',
  'function owner() view returns (address)', 'function treasury() view returns (address)', 'function token() view returns (address)',
  'function registry() view returns (address)', 'function runCount() view returns (uint256)',
  'function payeeStatus(uint256 agentId) view returns (uint8 state, address wallet, uint64 releaseAt, uint32 changes)',
  'function grantSession(address key, uint64 expiry, uint128 perRunCap, uint128 perDayCap)', 'function stage(Line[] lines) returns (uint256)',
  'function execute(uint256 runId) returns (bool)', 'function confirmPayee(uint256 agentId, address wallet)', 'function reject(uint256 runId, string reason)',
  'function canExecute(uint256 runId) view returns (bool ok, uint256 line, uint8 reason, uint64 releaseAt)',
  'function lineOf(uint256 runId, uint256 i) view returns (Line)',
  'error NotOwner()', 'error NoSession()', 'error SessionExpired()', 'error SessionRevokedErr()', 'error BadLines()',
  'error RunCapExceeded(uint256 total, uint256 cap)', 'error DayCapExceeded(uint256 stagedToday, uint256 cap)',
  'error PayeeNotRegistered(uint256 line, uint256 agentId, address payee, address registered)', 'error ZeroAmount(uint256 line)',
  'error AlreadyPaid(uint256 line, bytes32 invoiceHash, uint256 runId)', 'error AlreadyStaged(uint256 line, bytes32 invoiceHash, uint256 runId)',
  'error NotStaged(uint256 runId)', 'error RunStale(uint256 runId)', 'error TransferFailed(uint256 line)', 'error Reentrancy()', 'error BadSession()',
  'error ConfirmMismatch(uint256 agentId, address wallet, address registered)', 'error AlreadyTrusted(uint256 agentId, address wallet)']);
const REG_ABI = parseAbi(['function getAgentWallet(uint256) view returns (address)', 'function tokenURI(uint256) view returns (string)']);
export const BLOCK_REASON = { 1: 'the payee is new or just changed, so it is on hold', 2: 'it was staged during a hold: the owner must confirm the payee',
  3: 'the payee changed after staging: the run is closed' };
// Vendors the walkthrough may use: ERC-8004 identities this PayRunV2 has never paid (the public sandbox's test vendors and the
// testnet eval's). The first one the contract shows as new (Held) is used, so the hold is real, not set up by the page.
export const CANDIDATES = [1822, 1821, 1823, 1824, 1825, 1826, 1827, 1828, 1829, 1830, 1820];   // 1820 last: its name is the same as Clerk's own Acme (#1698)
const SIM_AMOUNT = 10_000n;   // 0.01 tUSD8

const rd = (pub, address, functionName, args = [], abi = SIM_ABI) => pub.readContract({ address, abi, functionName, args });
const enc = (functionName, args) => encodeFunctionData({ abi: SIM_ABI, functionName, args });
function why(ret) {
  if (!ret || ret === '0x') return 'reverted';
  try { const e = decodeErrorResult({ abi: SIM_ABI, data: ret }); return e.errorName + (e.args?.length ? '(' + e.args.map(String).join(', ') + ')' : ''); }
  catch { return 'reverted (' + String(ret).slice(0, 10) + ')'; }
}

/** One eth_call: the probe at the owner's address runs `calls` against payrun. Returns the probe's Step[] decoded. */
export async function runProbe(pub, { payrun, owner, token, treasury, payee, runId, calls }) {
  const data = encodeFunctionData({ abi: SIM_ABI, functionName: 'simulate', args: [payrun, calls, token, payee, treasury, runId] });
  const { data: out } = await pub.call({ to: owner, data, stateOverride: [{ address: owner, code: PROBE_CODE }] });
  const steps = decodeFunctionResult({ abi: SIM_ABI, functionName: 'simulate', data: out });
  return steps.map((s) => ({ ok: s.ok, ret: s.ret, payeeBalance: s.payeeBalance, treasuryBalance: s.treasuryBalance, runStatus: Number(s.runStatus), why: s.ok ? null : why(s.ret) }));
}

async function context(pub, payrun) {
  const [owner, treasury, token, registry, runCount, block] = await Promise.all([rd(pub, payrun, 'owner'), rd(pub, payrun, 'treasury'),
    rd(pub, payrun, 'token'), rd(pub, payrun, 'registry'), rd(pub, payrun, 'runCount'), pub.getBlock()]);
  return { owner, treasury, token, registry, runCount, now: block.timestamp };
}
function vendorName(uri) {
  try {
    const m = /^data:application\/json;base64,([A-Za-z0-9+/=]{1,8000})$/.exec(uri);
    const doc = m ? JSON.parse(atob(m[1])) : null;
    const n = typeof doc?.name === 'string' ? doc.name.replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁦-⁩]/g, '').trim() : '';
    return n ? n.slice(0, 60) : null;
  } catch { return null; }
}

/** Pick the vendor for the walkthrough: the first candidate that is new to this PayRunV2 (state Held, registered wallet set). */
export async function pickVendor(pub, payrun, registry, candidates = CANDIDATES) {
  for (const id of candidates) {
    try {
      const [state, wallet] = await rd(pub, payrun, 'payeeStatus', [BigInt(id)]);
      const reg = await rd(pub, registry, 'getAgentWallet', [BigInt(id)], REG_ABI);
      if (Number(state) === 2 && /^0x[0-9a-fA-F]{40}$/.test(reg) && BigInt(reg) !== 0n && reg.toLowerCase() === wallet.toLowerCase()) {
        let name = null; try { name = vendorName(await rd(pub, registry, 'tokenURI', [BigInt(id)], REG_ABI)); } catch {}
        return { agentId: BigInt(id), wallet: reg, name: name || 'agent #' + id };
      }
    } catch {}
  }
  return null;
}

/** The four-step walkthrough, run live up to step `upto` (1..4). Each step's facts come from the probe's return values. */
export async function walkthrough(pub, payrun, upto, cached = {}) {
  const c = cached.ctx || await context(pub, payrun);
  const v = cached.vendor || await pickVendor(pub, payrun, c.registry);
  if (!v) throw new Error('no vendor new to this contract was found for the walkthrough');
  const runId = c.runCount + 1n;
  const line = { payeeAgentId: v.agentId, payee: v.wallet, amount: SIM_AMOUNT, invoiceHash: keccak256(stringToHex('clerk-sim:' + payrun + ':' + v.agentId)),
    invoiceRef: toHex('SIM-1', { size: 32 }) };
  const calls = [enc('grantSession', [c.owner, c.now + 3600n, SIM_AMOUNT, SIM_AMOUNT]), enc('stage', [[line]]), enc('canExecute', [runId]),   // step 1
    enc('execute', [runId]),                                                                                                             // step 2
    enc('confirmPayee', [v.agentId, v.wallet]), enc('canExecute', [runId]),                                                             // step 3
    enc('execute', [runId])];                                                                                                            // step 4
  const n = [3, 4, 6, 7][Math.max(1, Math.min(4, upto)) - 1];
  const s = await runProbe(pub, { payrun, owner: c.owner, token: c.token, treasury: c.treasury, payee: v.wallet, runId, calls: calls.slice(0, n) });
  const can = (i) => { const [ok, , reason] = decodeFunctionResult({ abi: SIM_ABI, functionName: 'canExecute', data: s[i].ret }); return { ok, reason: Number(reason) }; };
  const paid = (i) => s[i].ok && decodeFunctionResult({ abi: SIM_ABI, functionName: 'execute', data: s[i].ret });
  const start = { payee: s[0].payeeBalance, treasury: s[0].treasuryBalance };
  const out = { ctx: c, vendor: v, runId, amount: SIM_AMOUNT, start, steps: [] };
  if (!s[1].ok) { out.steps.push({ n: 1, ok: false, text: 'Staging failed: ' + s[1].why }); return out; }
  out.steps.push({ n: 1, ok: true, held: !can(2).ok, reason: can(2).reason, runStatus: s[1].runStatus });
  if (n >= 4) out.steps.push({ n: 2, ok: s[3].ok, paid: paid(3), why: s[3].why, payee: s[3].payeeBalance, treasury: s[3].treasuryBalance, runStatus: s[3].runStatus });
  if (n >= 6) out.steps.push({ n: 3, ok: s[4].ok, why: s[4].why, canAfter: can(5).ok });
  if (n >= 7) out.steps.push({ n: 4, ok: s[6].ok, paid: paid(6), why: s[6].why, payee: s[6].payeeBalance, treasury: s[6].treasuryBalance, runStatus: s[6].runStatus });
  return out;
}

/** "What would approving this run do?" for a run already on chain. kind: 'pay' | 'held' | 'reject'. */
export async function simulateRun(pub, payrun, runId, kind) {
  const c = await context(pub, payrun);
  const l = await rd(pub, payrun, 'lineOf', [BigInt(runId), 0n]);
  const id = BigInt(runId);
  const calls = kind === 'held' ? [enc('execute', [id]), enc('confirmPayee', [l.payeeAgentId, l.payee]), enc('execute', [id])]
    : kind === 'reject' ? [enc('reject', [id, 'simulation'])] : [enc('execute', [id])];
  const s = await runProbe(pub, { payrun, owner: c.owner, token: c.token, treasury: c.treasury, payee: l.payee, runId: id, calls });
  const bal = await Promise.all([pub.readContract({ address: c.token, abi: parseAbi(['function balanceOf(address) view returns (uint256)']), functionName: 'balanceOf', args: [l.payee] }),
    pub.readContract({ address: c.token, abi: parseAbi(['function balanceOf(address) view returns (uint256)']), functionName: 'balanceOf', args: [c.treasury] })]);
  return { kind, payee: l.payee, agentId: l.payeeAgentId, before: { payee: bal[0], treasury: bal[1] }, steps: s.map((x, i) => ({ ...x,
    paid: x.ok && kind !== 'reject' && (kind !== 'held' || i !== 1) ? decodeFunctionResult({ abi: SIM_ABI, functionName: 'execute', data: x.ret }) : null })) };
}
