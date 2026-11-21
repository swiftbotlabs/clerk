// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PayRunV2, IERC20, IAgentIdentity} from "../../src/PayRunV2.sol";
import {ClerkStagePolicy, PackedUserOperation} from "../../src/ClerkStagePolicy.sol";

/// The clerk's session key as a Kernel v3.1 PERMISSION inside the owner's smart account, on a fork of Aevum testnet with Aevum's
/// own EntryPoint v0.7, Kernel v3.1 factory, ECDSA validator and ZeroDev's ECDSASigner (deployed at its canonical address):
///   forge test --match-path test/fork/ClerkPermissionFork.t.sol --fork-url https://rpc-test.qday.info
/// The permission (ECDSASigner bound to the clerk key + ClerkStagePolicy) is enabled by the clerk's first UserOperation, carrying
/// the owner's EIP-712 "Enable" signature (Kernel enable mode). From then on the clerk's key can make the account call
/// PayRunV2.stage, and nothing else.
contract ClerkPermissionForkTest is Test {
    IAgentIdentity constant REG = IAgentIdentity(0xF45E7f39Caba1d2055f613970575a7e7069636Be);
    IERC20 constant TUSD8 = IERC20(0x456569838f1d43009A91ebA4263147Afd7233483);
    IEP constant EP = IEP(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
    IFactory constant FACTORY = IFactory(0xaac5D4240AF87249B3f71BC8E4A2cae074A3E419);
    address constant ECDSA_VALIDATOR = 0x845ADb2C711129d4f3966735eD98a9F09fC4cE57;
    address constant ECDSA_SIGNER = 0x6A6F069E2a08c2468e7724Ab3250CdBFBA14D4FF;
    bytes32 constant ENABLE_TYPE_HASH = 0xb17ab1224aca0d4255ef8161acaf2ac121b8faa32a4b2258c912cc5f8308c505;
    bytes4 constant EXECUTE = 0xe9ae5c53;
    bytes4 constant PID = 0xc1e4c001; // the clerk's permission id

    uint256 ownerPk;
    address ownerKey;
    uint256 clerkPk;
    address clerkKey;
    address account;
    address bundler;
    PayRunV2 pr;
    ClerkStagePolicy policy;
    uint48 until;

    function setUp() public {
        if (block.chainid != 44005) return;
        (ownerKey, ownerPk) = makeAddrAndKey("owner key");
        (clerkKey, clerkPk) = makeAddrAndKey("clerk key");
        bundler = makeAddr("bundler");
        bytes memory init = abi.encodeWithSelector(
            IK.initialize.selector, bytes21(abi.encodePacked(bytes1(0x01), ECDSA_VALIDATOR)), address(0),
            abi.encodePacked(ownerKey), bytes(""), new bytes[](0)
        );
        account = FACTORY.createAccount(init, bytes32(uint256(44005_2)));
        vm.deal(account, 1 ether);
        pr = new PayRunV2(TUSD8, REG, account, account);
        policy = new ClerkStagePolicy();
        deal(address(TUSD8), account, 1_000e6);
        until = uint48(block.timestamp + 1 days);
        // The owner (root key) makes the ACCOUNT itself PayRun's staging session, with caps; only the permission can use it.
        Exec[] memory calls = new Exec[](2);
        calls[0] = Exec(address(TUSD8), 0, abi.encodeWithSignature("approve(address,uint256)", address(pr), 500e6));
        calls[1] = Exec(address(pr), 0, abi.encodeWithSelector(PayRunV2.grantSession.selector, account, uint64(until), uint128(5e6), uint128(5e6)));
        _send(_rootOp(abi.encodeWithSelector(IK.execute.selector, bytes32(bytes1(0x01)), abi.encode(calls))));
    }

    // ------------------------------------------------------------------ helpers

    function _ops(PackedUserOperation memory op) internal pure returns (PackedUserOperation[] memory ops) {
        ops = new PackedUserOperation[](1);
        ops[0] = op;
    }

    function _send(PackedUserOperation memory op) internal {
        vm.prank(bundler, bundler);
        EP.handleOps(_ops(op), payable(bundler));
    }

    function _base(bytes memory callData, uint256 nonce) internal view returns (PackedUserOperation memory op) {
        op.sender = account;
        op.nonce = nonce;
        op.callData = callData;
        op.accountGasLimits = bytes32((uint256(1_500_000) << 128) | 1_500_000);
        op.preVerificationGas = 80_000;
        op.gasFees = bytes32((uint256(1 gwei) << 128) | 1 gwei);
    }

    function _ethSign(uint256 pk, bytes32 h) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h)));
        return abi.encodePacked(r, s, v);
    }

    function _rootOp(bytes memory callData) internal view returns (PackedUserOperation memory op) {
        op = _base(callData, EP.getNonce(account, 0));
        op.signature = _ethSign(ownerPk, EP.getUserOpHash(op));
    }

    /// Kernel v3 nonce key: mode (1) | validation type (1) | validation id without type (20, here the 4-byte permission id) | key (2).
    function _permKey(bytes1 mode) internal pure returns (uint192) {
        return uint192((uint256(uint8(mode)) << 184) | (uint256(2) << 176) | (uint256(uint32(PID)) << 144));
    }

    function _stageCall(uint128 amount, bytes32 inv) internal view returns (bytes memory) {
        PayRunV2.Line[] memory ls = new PayRunV2.Line[](1);
        ls[0] = PayRunV2.Line({payeeAgentId: 1, payee: REG.getAgentWallet(1), amount: amount, invoiceHash: inv, invoiceRef: bytes32("INV")});
        return abi.encodeWithSelector(IK.execute.selector, bytes32(0), abi.encodePacked(address(pr), uint256(0), abi.encodeWithSelector(PayRunV2.stage.selector, ls)));
    }

    function _permissionData() internal view returns (bytes memory) {
        bytes[] memory entries = new bytes[](2);
        entries[0] = abi.encodePacked(bytes2(0), address(policy), abi.encode(address(pr), uint128(5e6), until, uint128(5 gwei), uint128(0.05 ether)));
        entries[1] = abi.encodePacked(bytes2(0), ECDSA_SIGNER, clerkKey);
        return abi.encode(entries);
    }

    function _domainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version,,,,) = IK(account).eip712Domain();
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)), keccak256(bytes(version)), block.chainid, account));
    }

    function _enableSig(bytes memory validatorData, bytes memory selectorData) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(ENABLE_TYPE_HASH, bytes21(abi.encodePacked(bytes1(0x02), PID, bytes16(0))),
            IK(account).currentNonce(), address(1), keccak256(validatorData), keccak256(""), keccak256(selectorData)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    /// The clerk's first UserOperation: enables the permission (owner's EIP-712 Enable signature) and stages in the same op.
    /// packedData = hook (20) ++ abi.encode(validatorData, hookData, selectorData, enableSig, userOpSig). The clerk's signature
    /// covers the userOpHash, which excludes `signature`, so it can be computed first.
    function _enableAndStageOp(uint128 amount, bytes32 inv) internal view returns (PackedUserOperation memory op) {
        bytes memory validatorData = _permissionData();
        bytes memory selectorData = abi.encodePacked(EXECUTE);
        bytes memory enableSig = _enableSig(validatorData, selectorData);
        op = _base(_stageCall(amount, inv), EP.getNonce(account, _permKey(0x01)));
        bytes memory userOpSig = abi.encodePacked(bytes1(0xff), _ethSign(clerkPk, EP.getUserOpHash(op)));
        op.signature = abi.encodePacked(address(1), abi.encode(validatorData, bytes(""), selectorData, enableSig, userOpSig));
    }

    function _clerkOp(bytes memory callData) internal view returns (PackedUserOperation memory op) {
        op = _base(callData, EP.getNonce(account, _permKey(0x00)));
        op.signature = abi.encodePacked(bytes1(0xff), _ethSign(clerkPk, EP.getUserOpHash(op)));
    }

    error FailedOpWithRevert(uint256 opIndex, string reason, bytes inner);
    error PolicyFailed(uint256 i);

    /// Refused by the clerk's policy at validation: the EntryPoint reports AA23 with Kernel's PolicyFailed(0).
    function _expectRefused(PackedUserOperation memory op) internal {
        _expectRefusedWith(op, abi.encodeWithSelector(PolicyFailed.selector, uint256(0)));
    }

    function _expectRefusedWith(PackedUserOperation memory op, bytes memory inner) internal {
        vm.prank(bundler, bundler);
        vm.expectRevert(abi.encodeWithSelector(FailedOpWithRevert.selector, uint256(0), "AA23 reverted", inner));
        EP.handleOps(_ops(op), payable(bundler));
    }

    // ------------------------------------------------------------------ tests

    function test_signer_module_is_deployed_on_aevum() public {
        if (block.chainid != 44005) { vm.skip(true); return; }
        assertGt(ECDSA_SIGNER.code.length, 0);
    }

    function test_clerk_permission_stages_through_the_account() public {
        if (block.chainid != 44005) { vm.skip(true); return; }
        _send(_enableAndStageOp(1_200_000, keccak256("INV-1")));
        (,, uint64 stagedAt, uint128 total,) = pr.runs(1);
        assertGt(stagedAt, 0, "run 1 staged");
        assertEq(total, 1_200_000);
        // A second run by the same permission, now installed (default mode).
        _send(_clerkOp(_stageCall(900_000, keccak256("INV-2"))));
        (,,, uint128 total2,) = pr.runs(2);
        assertEq(total2, 900_000);
    }

    function test_clerk_permission_cannot_pay_transfer_or_exceed_the_cap() public {
        if (block.chainid != 44005) { vm.skip(true); return; }
        _send(_enableAndStageOp(1_200_000, keccak256("INV-1")));
        uint256 before = IBal(address(TUSD8)).balanceOf(account);
        _expectRefused(_clerkOp(abi.encodeWithSelector(IK.execute.selector, bytes32(0),
            abi.encodePacked(address(pr), uint256(0), abi.encodeWithSelector(PayRunV2.execute.selector, uint256(1))))));
        _expectRefused(_clerkOp(abi.encodeWithSelector(IK.execute.selector, bytes32(0),
            abi.encodePacked(address(TUSD8), uint256(0), abi.encodeWithSignature("transfer(address,uint256)", clerkKey, uint256(1e6))))));
        _expectRefused(_clerkOp(_stageCall(5e6 + 1, keccak256("INV-BIG"))));
        assertEq(IBal(address(TUSD8)).balanceOf(account), before, "nothing moved");
        assertEq(pr.runCount(), 1, "nothing else staged");
    }

    function test_owner_revokes_the_permission_and_the_clerk_is_refused() public {
        if (block.chainid != 44005) { vm.skip(true); return; }
        _send(_enableAndStageOp(1_200_000, keccak256("INV-1")));
        bytes21 vId = bytes21(abi.encodePacked(bytes1(0x02), PID, bytes16(0)));
        bytes[] memory disable = new bytes[](2);
        _send(_rootOp(abi.encodeWithSelector(IK.uninstallValidation.selector, vId, abi.encode(disable), bytes(""))));
        _expectRefusedWith(_clerkOp(_stageCall(900_000, keccak256("INV-2"))), "");
        assertEq(pr.runCount(), 1);
    }

    function test_clerk_cannot_drain_the_account_through_gas_fields() public {
        if (block.chainid != 44005) { vm.skip(true); return; }
        _send(_enableAndStageOp(1_200_000, keccak256("INV-1")));
        uint256 before = account.balance;
        PackedUserOperation memory op = _base(_stageCall(900_000, keccak256("INV-2")), EP.getNonce(account, _permKey(0x00)));
        op.preVerificationGas = 9_000_000;
        op.gasFees = bytes32((uint256(5 gwei) << 128) | 5 gwei);
        op.signature = abi.encodePacked(bytes1(0xff), _ethSign(clerkPk, EP.getUserOpHash(op)));
        _expectRefused(op);
        PackedUserOperation memory pm = _clerkOp(_stageCall(900_000, keccak256("INV-3")));
        pm.paymasterAndData = abi.encodePacked(makeAddr("some paymaster"), uint128(1e5), uint128(1e5));
        pm.signature = abi.encodePacked(bytes1(0xff), _ethSign(clerkPk, EP.getUserOpHash(pm)));
        _expectRefused(pm);
        assertEq(account.balance, before, "nothing paid out");
    }

    function test_replayed_enable_signature_cannot_reset_the_budget() public {
        if (block.chainid != 44005) { vm.skip(true); return; }
        bytes memory validatorData = _permissionData();
        bytes memory selectorData = abi.encodePacked(EXECUTE);
        bytes memory enableSig = _enableSig(validatorData, selectorData);
        _send(_enableAndStageOp(1_200_000, keccak256("INV-1")));
        (,,,, uint128 budgetAfter) = policy.configs(bytes32(PID), account);
        // Same owner signature, new UserOperation in enable mode: Kernel's currentNonce has moved, so it must fail.
        PackedUserOperation memory op = _base(_stageCall(900_000, keccak256("INV-2")), EP.getNonce(account, _permKey(0x01)));
        bytes memory userOpSig = abi.encodePacked(bytes1(0xff), _ethSign(clerkPk, EP.getUserOpHash(op)));
        op.signature = abi.encodePacked(address(1), abi.encode(validatorData, bytes(""), selectorData, enableSig, userOpSig));
        vm.prank(bundler, bundler);
        vm.expectRevert();
        EP.handleOps(_ops(op), payable(bundler));
        (,,,, uint128 budgetNow) = policy.configs(bytes32(PID), account);
        assertEq(budgetNow, budgetAfter, "budget not reset");
        assertEq(pr.runCount(), 1);
    }

    function test_owner_root_key_still_pays_the_staged_run() public {
        if (block.chainid != 44005) { vm.skip(true); return; }
        _send(_enableAndStageOp(1_200_000, keccak256("INV-1")));
        // Payee 1 is new to this PayRunV2, so it is on hold: the owner confirms it, then pays (root key, not the clerk).
        address payee = REG.getAgentWallet(1);
        _send(_rootOp(abi.encodeWithSelector(IK.execute.selector, bytes32(0),
            abi.encodePacked(address(pr), uint256(0), abi.encodeWithSelector(PayRunV2.confirmPayee.selector, uint256(1), payee)))));
        uint256 before = IBal(address(TUSD8)).balanceOf(payee);
        _send(_rootOp(abi.encodeWithSelector(IK.execute.selector, bytes32(0),
            abi.encodePacked(address(pr), uint256(0), abi.encodeWithSelector(PayRunV2.execute.selector, uint256(1))))));
        assertEq(IBal(address(TUSD8)).balanceOf(payee) - before, 1_200_000, "paid by the owner's root key");
    }
}

struct Exec {
    address target;
    uint256 value;
    bytes callData;
}

interface IEP {
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;
    function getUserOpHash(PackedUserOperation calldata op) external view returns (bytes32);
    function getNonce(address sender, uint192 key) external view returns (uint256);
}

interface IFactory {
    function createAccount(bytes calldata data, bytes32 salt) external payable returns (address);
}

interface IK {
    function initialize(bytes21 rootValidator, address hook, bytes calldata validatorData, bytes calldata hookData, bytes[] calldata initConfig) external;
    function execute(bytes32 execMode, bytes calldata executionCalldata) external payable;
    function uninstallValidation(bytes21 vId, bytes calldata deinitData, bytes calldata hookDeinitData) external payable;
    function currentNonce() external view returns (uint32);
    function eip712Domain() external view returns (bytes1, string memory, string memory, uint256, address, bytes32, uint256[] memory);
}

interface IBal {
    function balanceOf(address who) external view returns (uint256);
}
