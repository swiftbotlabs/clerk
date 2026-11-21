// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClerkStagePolicy, PackedUserOperation} from "../src/ClerkStagePolicy.sol";
import {PayRunV2} from "../src/PayRunV2.sol";

/// Unit tests for the clerk's in-account permission policy. The policy is called by the account (msg.sender) during
/// validation; here the test pranks as the account and builds the account's own calldata (Kernel v3.1 `execute`).
contract ClerkStagePolicyTest is Test {
    ClerkStagePolicy policy;
    address account = makeAddr("kernel account");
    address payRun = makeAddr("payrun v2");
    bytes32 constant ID = bytes32(bytes4(0xc1e4c000));
    uint48 constant UNTIL = 2_000_000_000;
    uint128 constant CAP = 5e6;
    uint128 constant MAX_FEE = 5 gwei;
    uint128 constant BUDGET = 0.01 ether;

    function setUp() public {
        policy = new ClerkStagePolicy();
        vm.prank(account);
        policy.onInstall(abi.encodePacked(ID, abi.encode(payRun, CAP, UNTIL, MAX_FEE, BUDGET)));
    }

    function _lines(uint128 a, uint128 b) internal pure returns (PayRunV2.Line[] memory ls) {
        ls = new PayRunV2.Line[](2);
        ls[0] = PayRunV2.Line({payeeAgentId: 1, payee: address(0xA), amount: a, invoiceHash: keccak256("A"), invoiceRef: bytes32("A")});
        ls[1] = PayRunV2.Line({payeeAgentId: 2, payee: address(0xB), amount: b, invoiceHash: keccak256("B"), invoiceRef: bytes32("B")});
    }

    function _exec(bytes32 mode, address to, uint256 value, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(bytes4(0xe9ae5c53), mode, abi.encodePacked(to, value, data));
    }

    function _op(bytes memory callData, uint256 gasEach, uint256 pvg, uint256 fee) internal view returns (PackedUserOperation memory op) {
        op.sender = account;
        op.callData = callData;
        op.accountGasLimits = bytes32((gasEach << 128) | gasEach);
        op.preVerificationGas = pvg;
        op.gasFees = bytes32((uint256(1 gwei) << 128) | fee);
    }

    function _checkOp(PackedUserOperation memory op) internal returns (uint256) {
        vm.prank(account);
        return policy.checkUserOpPolicy(ID, op);
    }

    function _check(bytes memory callData) internal returns (uint256) {
        return _checkOp(_op(callData, 300_000, 50_000, 1 gwei));   // 650k gas x 1 gwei = 0.00065 ether worst case
    }

    function _budget() internal view returns (uint128 b) {
        (,,,, b) = policy.configs(ID, account);
    }

    function _stage(uint128 a, uint128 b) internal view returns (bytes memory) {
        return _exec(bytes32(0), payRun, 0, abi.encodeWithSelector(PayRunV2.stage.selector, _lines(a, b)));
    }

    function test_stage_within_cap_passes_with_the_keys_expiry() public {
        assertEq(_check(_stage(2e6, 3e6)), uint256(UNTIL) << 160);
    }

    function test_stage_over_cap_fails() public {
        assertEq(_check(_stage(2e6, 3e6 + 1)), 1);
    }

    function test_execute_on_payrun_fails() public {
        assertEq(_check(_exec(bytes32(0), payRun, 0, abi.encodeWithSelector(PayRunV2.execute.selector, uint256(1)))), 1);
    }

    function test_token_transfer_fails() public {
        assertEq(_check(_exec(bytes32(0), makeAddr("token"), 0, abi.encodeWithSignature("transfer(address,uint256)", address(1), 1))), 1);
    }

    function test_stage_on_another_contract_fails() public {
        assertEq(_check(_exec(bytes32(0), makeAddr("other payrun"), 0, abi.encodeWithSelector(PayRunV2.stage.selector, _lines(1, 1)))), 1);
    }

    function test_value_fails() public {
        assertEq(_check(_exec(bytes32(0), payRun, 1, abi.encodeWithSelector(PayRunV2.stage.selector, _lines(1, 1)))), 1);
    }

    function test_batch_and_delegatecall_modes_fail() public {
        bytes memory stageCall = abi.encodeWithSelector(PayRunV2.stage.selector, _lines(1, 1));
        assertEq(_check(_exec(bytes32(bytes1(0x01)), payRun, 0, stageCall)), 1, "batch");
        assertEq(_check(_exec(bytes32(bytes1(0xff)), payRun, 0, stageCall)), 1, "delegatecall");
        assertEq(_check(_exec(bytes32(uint256(1)), payRun, 0, stageCall)), 1, "mode payload");
    }

    function test_other_account_selectors_fail() public {
        bytes memory inner = _stage(1, 1);
        assertEq(_check(abi.encodePacked(bytes4(0x8dd7712f), inner)), 1, "executeUserOp wrapper");
        assertEq(_check(abi.encodeWithSignature("installModule(uint256,address,bytes)", 1, address(1), "")), 1, "install");
        assertEq(_check(""), 1, "empty");
    }

    function test_other_account_or_uninstalled_fails() public {
        PackedUserOperation memory op = _op(_stage(1, 1), 300_000, 50_000, 1 gwei);
        vm.prank(makeAddr("another account"));
        assertEq(policy.checkUserOpPolicy(ID, op), 1, "not installed there");
        vm.prank(account);
        policy.onUninstall(abi.encodePacked(ID));
        assertEq(_check(_stage(1, 1)), 1, "uninstalled");
        assertFalse(policy.isInitialized(account));
    }

    function test_uninstalled_permission_fails_even_for_an_all_zero_op() public {
        vm.prank(account);
        policy.onUninstall(abi.encodePacked(ID));
        // Every field matches a zeroed config: target 0, value 0, total 0, fee 0, gas 0. Only the "installed" check stops it.
        PackedUserOperation memory op =
            _op(_exec(bytes32(0), address(0), 0, abi.encodeWithSelector(PayRunV2.stage.selector, _lines(0, 0))), 0, 0, 0);
        assertEq(_checkOp(op), 1);
    }

    function test_never_signs_erc1271() public view {
        assertEq(policy.checkSignaturePolicy(ID, account, bytes32(0), ""), 1);
    }

    function test_reinstall_overwrites_and_bad_config_reverts() public {
        vm.prank(account);
        policy.onInstall(abi.encodePacked(ID, abi.encode(payRun, uint128(1), UNTIL, MAX_FEE, BUDGET)));
        assertEq(policy.installed(account), 1, "counted once");
        assertEq(_check(_stage(1, 1)), 1, "new cap 1 applies");
        vm.prank(account);
        vm.expectRevert(ClerkStagePolicy.BadConfig.selector);
        policy.onInstall(abi.encodePacked(bytes32(uint256(7)), abi.encode(address(0), CAP, UNTIL, MAX_FEE, BUDGET)));
        vm.prank(account);
        vm.expectRevert(ClerkStagePolicy.BadConfig.selector);
        policy.onInstall(abi.encodePacked(bytes32(uint256(7)), abi.encode(payRun, CAP, UNTIL, MAX_FEE, uint128(0))));
    }

    // ---------------------------------------------------------------- gas is money (security review 2026-11-21, finding 1)

    function test_paymaster_is_refused() public {
        PackedUserOperation memory op = _op(_stage(1, 1), 300_000, 50_000, 1 gwei);
        op.paymasterAndData = abi.encodePacked(makeAddr("paymaster"), uint128(1e5), uint128(1e5));
        assertEq(_checkOp(op), 1);
    }

    function test_fee_above_the_max_is_refused() public {
        assertEq(_checkOp(_op(_stage(1, 1), 300_000, 50_000, MAX_FEE + 1)), 1);
        assertEq(_checkOp(_op(_stage(1, 1), 300_000, 50_000, MAX_FEE)), uint256(UNTIL) << 160);
    }

    function test_drain_by_huge_preverification_gas_is_refused() public {
        // the reviewer's exploit shape: a valid stage call with ~7M preVerificationGas at the max fee -> 0.035 ether > budget
        assertEq(_checkOp(_op(_stage(1, 1), 300_000, 7_000_000, MAX_FEE)), 1);
        assertEq(_budget(), BUDGET, "a refused op costs the budget nothing");
    }

    function test_budget_is_spent_per_op_and_runs_out() public {
        uint256 per = (300_000 * 2 + 50_000) * uint256(1 gwei);
        assertEq(_check(_stage(1, 1)), uint256(UNTIL) << 160);
        assertEq(_budget(), BUDGET - per);
        uint256 more = (BUDGET - per) / per;
        for (uint256 i = 0; i < more; i++) assertEq(_check(_stage(1, 1)), uint256(UNTIL) << 160);
        assertEq(_check(_stage(1, 1)), 1, "budget exhausted");
    }

    function test_truncated_stage_args_are_refused() public {
        // Positive control for the in-place length rewrite: with the length not reduced, the decoder would read past `exec`.
        PayRunV2.Line[] memory ls = new PayRunV2.Line[](1);
        ls[0] = PayRunV2.Line(1, address(0xA), 1, keccak256("A"), bytes32("A"));
        bytes memory full = abi.encodePacked(payRun, uint256(0), abi.encodeWithSelector(PayRunV2.stage.selector, ls));
        bytes memory cut = new bytes(full.length - 32);
        for (uint256 i; i < cut.length; i++) cut[i] = full[i];
        assertEq(_check(abi.encodeWithSelector(bytes4(0xe9ae5c53), bytes32(0), full)), uint256(UNTIL) << 160, "full passes");
        try this.checkCut(cut) returns (uint256 r) { assertEq(r, 1, "truncated refused"); } catch {}
    }

    function checkCut(bytes memory exec) external returns (uint256) {
        return _check(abi.encodeWithSelector(bytes4(0xe9ae5c53), bytes32(0), exec));
    }

    function test_26_lines_fail() public {
        PayRunV2.Line[] memory ls = new PayRunV2.Line[](26);
        for (uint256 i = 0; i < 26; i++) ls[i] = PayRunV2.Line({payeeAgentId: i, payee: address(uint160(i + 1)), amount: 1, invoiceHash: bytes32(i), invoiceRef: bytes32(i)});
        assertEq(_check(_exec(bytes32(0), payRun, 0, abi.encodeWithSelector(PayRunV2.stage.selector, ls))), 1);
    }

    function test_25_line_run_validates_cheaply() public {
        PayRunV2.Line[] memory ls = new PayRunV2.Line[](25);
        for (uint256 i = 0; i < 25; i++) ls[i] = PayRunV2.Line({payeeAgentId: i, payee: address(uint160(i + 1)), amount: 1, invoiceHash: bytes32(i), invoiceRef: bytes32(i)});
        PackedUserOperation memory op = _op(_exec(bytes32(0), payRun, 0, abi.encodeWithSelector(PayRunV2.stage.selector, ls)), 300_000, 50_000, 1 gwei);
        vm.prank(account);
        uint256 g = gasleft();
        uint256 r = policy.checkUserOpPolicy(ID, op);
        g -= gasleft();
        assertEq(r, uint256(UNTIL) << 160);
        assertLt(g, 200_000, "policy gas for 25 lines");
    }

    function testFuzz_any_selector_but_stage_fails(bytes4 sel, bytes calldata rest) public {
        vm.assume(sel != PayRunV2.stage.selector);
        assertEq(_check(_exec(bytes32(0), payRun, 0, abi.encodePacked(sel, rest))), 1);
    }

    function testFuzz_cap(uint128 a, uint128 b) public {
        a = uint128(bound(a, 1, 10e6));
        b = uint128(bound(b, 1, 10e6));
        uint256 r = _check(_stage(a, b));
        if (uint256(a) + b <= CAP) assertEq(r, uint256(UNTIL) << 160);
        else assertEq(r, 1);
    }
}
