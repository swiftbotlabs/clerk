// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PayRunV2} from "./PayRunV2.sol";

/// @title ClerkStagePolicy: the clerk's session key as a Kernel v3.1 permission, inside the owner's smart account.
/// @notice A Kernel permission = a signer (Aevum's deployed ECDSASigner, bound to the clerk's key) + this policy. A UserOperation
/// signed under the permission passes this policy only when it is exactly one call, from the account, to `PayRunV2.stage(lines)`
/// on the configured PayRun, with no value and a run total within the per-run cap. Everything else (execute, approve, transfer,
/// a batch, a delegatecall, another target or selector) is refused. The key's expiry is returned as `validUntil`, so the
/// EntryPoint enforces it (no TIMESTAMP opcode during validation). PayRunV2 still applies its own caps, expiry and payee checks
/// on the account's session when `stage` runs, so every limit is enforced twice.
/// Gas is money too: the clerk signs the UserOperation's gas fields, and the account pays what they allow. So the policy also
/// refuses any paymaster, caps maxFeePerGas, and keeps a running wei budget per permission (each op's worst-case cost,
/// (verification + call + pre-verification gas) x maxFeePerGas, is taken from it at validation, whether or not `stage` succeeds).
/// Revoke: the owner uninstalls the permission (one UserOperation from the root key).
/// Storage follows ERC-7562's associated-storage rule: every slot is keyed by the account (msg.sender).
contract ClerkStagePolicy {
    struct Config {
        address payRun;        // the only target
        uint48 validUntil;     // the key's expiry (0 = not installed)
        uint128 perRunCap;     // max total of one staged run (token units)
        uint128 maxFeePerGas;  // highest maxFeePerGas the clerk may sign (wei)
        uint128 gasBudget;     // wei the clerk's UserOperations may still cost the account, worst case
    }

    uint256 internal constant PASS = 0;
    uint256 internal constant FAIL = 1; // SIG_VALIDATION_FAILED: Kernel reverts PolicyFailed

    bytes4 internal constant KERNEL_EXECUTE = 0xe9ae5c53; // execute(bytes32 mode, bytes executionCalldata)
    uint256 internal constant MAX_LINES = 25;

    mapping(bytes32 id => mapping(address account => Config)) public configs;
    mapping(address account => uint256) public installed;

    error BadConfig();

    event ClerkPolicyInstalled(address indexed account, bytes32 indexed id, address payRun, uint128 perRunCap, uint48 validUntil,
        uint128 maxFeePerGas, uint128 gasBudget);
    event ClerkPolicyRemoved(address indexed account, bytes32 indexed id);

    // ---------------------------------------------------------------- ERC-7579 module (type 5 = policy)

    function isModuleType(uint256 typeId) external pure returns (bool) {
        return typeId == 5;
    }

    function isInitialized(address account) external view returns (bool) {
        return installed[account] > 0;
    }

    /// data = permissionId (32) ++ abi.encode(payRun, perRunCap, validUntil, maxFeePerGas, gasBudget)
    /// Re-installing an id overwrites it (Kernel's nonce and the owner's enable signature already gate installs; an id whose
    /// uninstall was skipped, e.g. revoked by nonce, must not get stuck).
    function onInstall(bytes calldata data) external payable {
        bytes32 id = bytes32(data[0:32]);
        (address payRun, uint128 perRunCap, uint48 validUntil, uint128 maxFeePerGas, uint128 gasBudget) =
            abi.decode(data[32:], (address, uint128, uint48, uint128, uint128));
        if (payRun == address(0) || perRunCap == 0 || validUntil == 0 || maxFeePerGas == 0 || gasBudget == 0) revert BadConfig();
        if (configs[id][msg.sender].validUntil == 0) installed[msg.sender]++;
        configs[id][msg.sender] = Config({payRun: payRun, validUntil: validUntil, perRunCap: perRunCap,
            maxFeePerGas: maxFeePerGas, gasBudget: gasBudget});
        emit ClerkPolicyInstalled(msg.sender, id, payRun, perRunCap, validUntil, maxFeePerGas, gasBudget);
    }

    function onUninstall(bytes calldata data) external payable {
        bytes32 id = bytes32(data[0:32]);
        if (configs[id][msg.sender].validUntil == 0) return;
        delete configs[id][msg.sender];
        installed[msg.sender]--;
        emit ClerkPolicyRemoved(msg.sender, id);
    }

    // ---------------------------------------------------------------- the check

    /// @dev Called by the Kernel account during validation; msg.sender is the account.
    function checkUserOpPolicy(bytes32 id, PackedUserOperation calldata userOp) external payable returns (uint256) {
        Config storage c = configs[id][msg.sender];
        if (c.validUntil == 0) return FAIL;
        if (userOp.paymasterAndData.length != 0) return FAIL;          // the account pays; no sponsor credit to burn
        uint256 maxFee = uint128(uint256(userOp.gasFees));             // v0.7: low 128 bits = maxFeePerGas
        if (maxFee > c.maxFeePerGas) return FAIL;
        uint256 limits = uint256(userOp.accountGasLimits);             // verificationGasLimit (high) | callGasLimit (low)
        uint256 cost = ((limits >> 128) + uint128(limits) + userOp.preVerificationGas) * maxFee;
        if (cost > c.gasBudget) return FAIL;
        if (!allowed(c.payRun, c.perRunCap, userOp.callData)) return FAIL;
        c.gasBudget -= uint128(cost);
        return uint256(c.validUntil) << 160;
    }

    /// @notice The permission never signs ERC-1271 messages (no approvals, no permits, no enable signatures).
    function checkSignaturePolicy(bytes32, address, bytes32, bytes calldata) external pure returns (uint256) {
        return FAIL;
    }

    /// @notice Whether `callData` (the account's own calldata) is one `PayRunV2.stage` call within the cap.
    function allowed(address payRun, uint128 perRunCap, bytes calldata callData) public pure returns (bool) {
        if (callData.length < 4 || bytes4(callData[0:4]) != KERNEL_EXECUTE) return false;
        (bytes32 mode, bytes memory exec) = abi.decode(callData[4:], (bytes32, bytes));
        if (mode != bytes32(0)) return false; // single call, default exec type, no selector or context: nothing else
        if (exec.length < 56) return false;   // target (20) + value (32) + selector (4); defence in depth: without it the
                                              // length below would wrap and abi.decode would revert anyway
        address target;
        uint256 value;
        bytes4 sel;
        assembly {
            target := shr(96, mload(add(exec, 32)))
            value := mload(add(exec, 52))
            sel := mload(add(exec, 84))
        }
        if (target != payRun || value != 0 || sel != PayRunV2.stage.selector) return false;
        // The stage arguments start 56 bytes into `exec`: reuse that memory as a `bytes` (its length word overwrites the
        // already-read `value` field) instead of copying it byte by byte.
        bytes memory args;
        assembly {
            args := add(exec, 56)
            mstore(args, sub(mload(exec), 56))
        }
        PayRunV2.Line[] memory lines = abi.decode(args, (PayRunV2.Line[]));
        uint256 n = lines.length;
        if (n == 0 || n > MAX_LINES) return false;
        uint256 total = 0;
        for (uint256 i = 0; i < n; i++) total += lines[i].amount;
        return total <= perRunCap;
    }
}

/// ERC-4337 v0.7 packed user operation (the layout Kernel v3.1 passes to policies).
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}
