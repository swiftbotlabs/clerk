// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PayRun, IERC20, IAgentIdentity} from "../../src/PayRun.sol";

/// The owner of a PayRun as an ERC-4337 smart account: a Kernel v3.1 account on Aevum, validated by Kernel's ECDSA validator,
/// driven through Aevum's EntryPoint v0.7. Runs against a fork of Aevum testnet (chain 44005), with the REAL EntryPoint, Kernel
/// factory and implementation, ECDSA validator, ERC-8004 registry and tUSD8:
///   forge test --match-path 'test/fork/*' --fork-url https://rpc-test.qday.info
/// The account is also the treasury: one batched UserOperation approves PayRun and grants the agent's staging-only session key.
contract KernelOwnerForkTest is Test {
    IAgentIdentity constant REG = IAgentIdentity(0xF45E7f39Caba1d2055f613970575a7e7069636Be);
    IERC20 constant TUSD8 = IERC20(0x456569838f1d43009A91ebA4263147Afd7233483);
    IEntryPointV07 constant EP = IEntryPointV07(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
    IKernelFactory constant FACTORY = IKernelFactory(0xaac5D4240AF87249B3f71BC8E4A2cae074A3E419);
    address constant ECDSA_VALIDATOR = 0x845ADb2C711129d4f3966735eD98a9F09fC4cE57;

    uint256 ownerPk;
    address ownerKey;
    address account; // the Kernel smart account: PayRun owner and treasury
    address bundler;
    PayRun pr;

    function setUp() public {
        if (block.chainid != 44005) return;
        (ownerKey, ownerPk) = makeAddrAndKey("owner key");
        bundler = makeAddr("bundler");
        // initialize(rootValidator = 0x01 ++ validator, hook = none, validatorData = owner key, hookData, initConfig)
        bytes memory init = abi.encodeWithSelector(
            IKernel.initialize.selector, bytes21(abi.encodePacked(bytes1(0x01), ECDSA_VALIDATOR)), address(0),
            abi.encodePacked(ownerKey), bytes(""), new bytes[](0)
        );
        account = FACTORY.createAccount(init, bytes32(uint256(44005)));
        vm.deal(account, 1 ether); // pays its own gas (prefund) to the EntryPoint
        pr = new PayRun(TUSD8, REG, account, account);
        deal(address(TUSD8), account, 1_000e6);
    }

    // ------------------------------------------------------------------ helpers

    function _userOp(bytes memory callData, uint256 signerPk) internal view returns (PackedUserOperation memory op) {
        op.sender = account;
        op.nonce = EP.getNonce(account, 0); // key 0 = the root validator (ECDSA owner key)
        op.callData = callData;
        op.accountGasLimits = bytes32((uint256(600_000) << 128) | 600_000);
        op.preVerificationGas = 60_000;
        op.gasFees = bytes32((uint256(1 gwei) << 128) | 1 gwei);
        bytes32 h = EP.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerPk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h)));
        op.signature = abi.encodePacked(r, s, v);
    }

    function _send(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        EP.handleOps(ops, payable(bundler));
    }

    /// Kernel v3 execute, single call (exec mode 0).
    function _single(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IKernel.execute.selector, bytes32(0), abi.encodePacked(to, uint256(0), data));
    }

    /// Kernel v3 execute, batch (call type 0x01).
    function _batch(Execution[] memory calls) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IKernel.execute.selector, bytes32(bytes1(0x01)), abi.encode(calls));
    }

    function _setUpSession(address clerk) internal {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(address(TUSD8), 0, abi.encodeWithSelector(IERC20Approve.approve.selector, address(pr), 500e6));
        calls[1] = Execution(
            address(pr), 0,
            abi.encodeWithSelector(PayRun.grantSession.selector, clerk, uint64(block.timestamp + 1 days), uint128(5e6), uint128(5e6))
        );
        _send(_userOp(_batch(calls), ownerPk));
    }

    // ------------------------------------------------------------------ tests

    function test_kernel_account_is_a_real_smart_account() public {
        if (block.chainid != 44005) { vm.skip(true); return; }
        assertGt(account.code.length, 0, "account deployed by the real Kernel factory");
        assertEq(pr.owner(), account);
    }

    function test_batch_userop_grants_session_then_userop_pays_the_run() public {
        if (block.chainid != 44005) { vm.skip(true); return; }
        address clerk = makeAddr("clerk");
        _setUpSession(clerk);
        assertEq(IERC20Approve(address(TUSD8)).allowance(account, address(pr)), 500e6, "approve ran inside the batch");

        address payee = REG.getAgentWallet(1);
        PayRun.Line[] memory ls = new PayRun.Line[](1);
        ls[0] = PayRun.Line({payeeAgentId: 1, payee: payee, amount: 1_200_000, invoiceHash: keccak256("INV-1"), invoiceRef: bytes32("INV-1")});
        vm.prank(clerk);
        uint256 runId = pr.stage(ls);

        // The session key can stage but never pay.
        vm.prank(clerk);
        vm.expectRevert(PayRun.NotOwner.selector);
        pr.execute(runId);

        uint256 before = IERC20Approve(address(TUSD8)).balanceOf(payee);
        _send(_userOp(_single(address(pr), abi.encodeWithSelector(PayRun.execute.selector, runId)), ownerPk));
        assertEq(IERC20Approve(address(TUSD8)).balanceOf(payee) - before, 1_200_000, "paid through the smart account");
    }

    function test_userop_signed_by_another_key_is_refused_by_the_entrypoint() public {
        if (block.chainid != 44005) { vm.skip(true); return; }
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        PackedUserOperation memory op =
            _userOp(_single(address(pr), abi.encodeWithSelector(PayRun.setOwner.selector, makeAddr("thief"))), strangerPk);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        vm.expectRevert(abi.encodeWithSelector(IEntryPointV07.FailedOp.selector, 0, "AA24 signature error"));
        EP.handleOps(ops, payable(bundler));
        assertEq(pr.owner(), account, "owner unchanged");
    }

    function test_owner_key_alone_cannot_call_payrun_directly() public {
        if (block.chainid != 44005) { vm.skip(true); return; }
        vm.prank(ownerKey);
        vm.expectRevert(PayRun.NotOwner.selector);
        pr.setOwner(ownerKey);
    }
}

// ---------------------------------------------------------------------- minimal interfaces (ERC-4337 v0.7, Kernel v3.1)

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

struct Execution {
    address target;
    uint256 value;
    bytes callData;
}

interface IEntryPointV07 {
    error FailedOp(uint256 opIndex, string reason);
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;
    function getUserOpHash(PackedUserOperation calldata op) external view returns (bytes32);
    function getNonce(address sender, uint192 key) external view returns (uint256);
}

interface IKernelFactory {
    function createAccount(bytes calldata data, bytes32 salt) external payable returns (address);
}

interface IKernel {
    function initialize(bytes21 rootValidator, address hook, bytes calldata validatorData, bytes calldata hookData, bytes[] calldata initConfig)
        external;
    function execute(bytes32 execMode, bytes calldata executionCalldata) external payable;
}

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address who) external view returns (uint256);
}
