// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentIdentity} from "./PayRun.sol";

/// The hold view of a PayRunV3 (or anything with the same signature): state 0 None, 1 Trusted, 2 Held, 3 Released.
interface IPayeeHold {
    function payeeStatus(uint256 agentId) external view returns (uint8 state, address wallet, uint64 releaseAt, uint32 changes);
}

/// @title PayeeCheck: Clerk's Confirmation of Payee, as a library any Aevum app can import.
/// @notice Before your contract sends money to `payee` for an ERC-8004 identity `agentId`, ask:
///   1. is `payee` the wallet the registry holds for that identity (any ERC-8004 read interface: QDay's registry,
///      Clerk's VendorRegistry or VendorRegistryV2)?
///   2. is a wallet change pending in the registry (VendorRegistryV2's 48-hour timelock; skipped for registries without it)?
///   3. optional: is the wallet still inside a payee-change hold (PayRunV3's `payeeStatus`, or your own contract with the
///      same view)?
/// `check` only reads and never reverts on a well-behaved registry; `requireOk` reverts unless the verdict is Ok. It is
/// conservative on purpose: a payee whose registry entry is changing, or who is held, is not Ok.
library PayeeCheck {
    enum Verdict { Ok, Unregistered, Mismatch, ChangePending, Held }

    struct Result {
        Verdict verdict;
        address registered;     // registry.getAgentWallet(agentId)
        address pendingWallet;  // VendorRegistryV2 only: the wallet proposed for this identity (0 = none or not supported)
        uint64 pendingEta;      // when that change can apply
        uint64 holdUntil;       // hold source only: when the hold on `registered` ends (0 = no hold)
    }

    error PayeeCheckFailed(uint256 agentId, address payee, Verdict verdict, address registered);

    bytes4 private constant PENDING_WALLET = bytes4(keccak256("pendingWallet(uint256)"));

    /// @notice Registry check plus the registry's pending change, when it has one.
    function check(IAgentIdentity registry, uint256 agentId, address payee) internal view returns (Result memory r) {
        r.registered = registry.getAgentWallet(agentId);
        (r.pendingWallet, r.pendingEta) = pendingOf(address(registry), agentId);
        if (r.registered == address(0)) r.verdict = Verdict.Unregistered;
        else if (payee != r.registered) r.verdict = Verdict.Mismatch;
        else if (r.pendingEta != 0) r.verdict = Verdict.ChangePending;
        else r.verdict = Verdict.Ok;
    }

    /// @notice The same, plus a payee-change hold source (e.g. a PayRunV3). Pass address(0) for none.
    function check(IAgentIdentity registry, IPayeeHold hold, uint256 agentId, address payee)
        internal view returns (Result memory r)
    {
        r = check(registry, agentId, payee);
        if (r.verdict != Verdict.Ok || address(hold) == address(0)) return r;
        (uint8 state, address wallet, uint64 releaseAt,) = hold.payeeStatus(agentId);
        // Trusted (1) or Released (3) for exactly this wallet is fine; anything else is held.
        if (wallet != payee || (state != 1 && state != 3)) {
            r.verdict = Verdict.Held;
            r.holdUntil = releaseAt;
        }
    }

    function requireOk(IAgentIdentity registry, uint256 agentId, address payee) internal view returns (Result memory r) {
        r = check(registry, agentId, payee);
        if (r.verdict != Verdict.Ok) revert PayeeCheckFailed(agentId, payee, r.verdict, r.registered);
    }

    function requireOk(IAgentIdentity registry, IPayeeHold hold, uint256 agentId, address payee)
        internal view returns (Result memory r)
    {
        r = check(registry, hold, agentId, payee);
        if (r.verdict != Verdict.Ok) revert PayeeCheckFailed(agentId, payee, r.verdict, r.registered);
    }

    /// @notice VendorRegistryV2's `pendingWallet(agentId)`, or (0, 0) for a registry without it or with a malformed answer.
    function pendingOf(address registry, uint256 agentId) internal view returns (address wallet, uint64 eta) {
        (bool ok, bytes memory ret) = registry.staticcall{gas: 50_000}(abi.encodeWithSelector(PENDING_WALLET, agentId));
        if (!ok || ret.length < 64) return (address(0), 0);
        (uint256 w, uint256 e) = abi.decode(ret, (uint256, uint256));
        if (w >> 160 != 0 || e > type(uint64).max || w == 0 || e == 0) return (address(0), 0);
        return (address(uint160(w)), uint64(e));
    }
}

/// @title PayeeChecker: the library behind one external view, for apps and scripts that want a single eth_call.
contract PayeeChecker {
    function check(IAgentIdentity registry, IPayeeHold hold, uint256 agentId, address payee)
        external view returns (PayeeCheck.Result memory)
    {
        return PayeeCheck.check(registry, hold, agentId, payee);
    }
}
