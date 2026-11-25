// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice NEVER DEPLOYED. The approval page's no-wallet simulation puts this runtime code at the PayRun OWNER's address for a
/// single eth_call (a state override), so each call below runs with msg.sender == owner, exactly as the owner's own approval
/// would, and every effect is thrown away when the call returns. No key, no signature, no transaction.
/// It first records the payee's and the treasury's token balances BEFORE any call (so "paid X" is exact: same block, same
/// state), then after each call what changed: did the call succeed (and its return or revert data), both balances again,
/// and the run's status.
contract DemoProbe {
    struct Step {
        bool ok;
        bytes ret;
        uint256 payeeBalance;
        uint256 treasuryBalance;
        uint8 runStatus;
    }

    function simulate(address payrun, bytes[] calldata calls, address token, address payee, address treasury, uint256 runId)
        external
        returns (uint256 payeeBefore, uint256 treasuryBefore, Step[] memory out)
    {
        payeeBefore = _balance(token, payee);
        treasuryBefore = _balance(token, treasury);
        out = new Step[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = payrun.call(calls[i]);
            out[i].ok = ok;
            out[i].ret = ret;
            out[i].payeeBalance = _balance(token, payee);
            out[i].treasuryBalance = _balance(token, treasury);
            out[i].runStatus = _status(payrun, runId);
        }
    }

    function _balance(address token, address who) internal view returns (uint256 b) {
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        if (ok && r.length >= 32) b = abi.decode(r, (uint256));
    }

    function _status(address payrun, uint256 runId) internal view returns (uint8 s) {
        (bool ok, bytes memory r) = payrun.staticcall(abi.encodeWithSignature("runs(uint256)", runId));
        if (ok && r.length >= 32) s = uint8(abi.decode(r, (uint256)));
    }
}
