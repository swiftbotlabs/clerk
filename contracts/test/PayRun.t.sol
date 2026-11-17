// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PayRun, IERC20, IAgentIdentity} from "../src/PayRun.sol";

contract MockUSD is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(allowance[f][msg.sender] >= a, "allowance");
        require(balanceOf[f] >= a, "balance");
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

contract MockRegistry is IAgentIdentity {
    mapping(uint256 => address) public w;
    function set(uint256 id, address a) external { w[id] = a; }
    function getAgentWallet(uint256 id) external view returns (address) { return w[id]; }
}

contract PayRunTest is Test {
    MockUSD usd; MockRegistry reg; PayRun pr;
    address owner = makeAddr("owner"); address treasury = makeAddr("treasury");
    address clerk = makeAddr("clerk"); address mallory = makeAddr("mallory");
    address acme = makeAddr("acme"); address globex = makeAddr("globex");
    uint256 constant ACME = 7; uint256 constant GLOBEX = 9;
    uint128 constant USD = 1e6;

    function setUp() public {
        vm.warp(1_763_400_000);
        usd = new MockUSD(); reg = new MockRegistry();
        pr = new PayRun(usd, reg, owner, treasury);
        reg.set(ACME, acme); reg.set(GLOBEX, globex);
        usd.mint(treasury, 10_000 * USD);
        vm.prank(treasury); usd.approve(address(pr), type(uint256).max);
        vm.prank(owner); pr.grantSession(clerk, uint64(block.timestamp + 7 days), 500 * USD, 800 * USD);
    }

    function line(uint256 id, address payee, uint128 amt, string memory inv) internal pure returns (PayRun.Line memory) {
        return PayRun.Line({payeeAgentId: id, payee: payee, amount: amt, invoiceHash: keccak256(bytes(inv)), invoiceRef: bytes32(bytes(inv))});
    }
    function one(PayRun.Line memory l) internal pure returns (PayRun.Line[] memory a) { a = new PayRun.Line[](1); a[0] = l; }
    function two(PayRun.Line memory l1, PayRun.Line memory l2) internal pure returns (PayRun.Line[] memory a) { a = new PayRun.Line[](2); a[0] = l1; a[1] = l2; }

    function test_stage_then_execute_pays_registered_wallets_once() public {
        vm.prank(clerk);
        uint256 id = pr.stage(two(line(ACME, acme, 120 * USD, "INV-1001"), line(GLOBEX, globex, 80 * USD, "G-77")));
        assertEq(usd.balanceOf(acme), 0, "staging moves no money");
        vm.expectEmit(true, true, true, true);
        emit PayRun.Paid(id, 0, keccak256("INV-1001"), bytes32("INV-1001"), ACME, acme, 120 * USD);
        vm.prank(owner); pr.execute(id);
        assertEq(usd.balanceOf(acme), 120 * USD); assertEq(usd.balanceOf(globex), 80 * USD);
        assertEq(pr.paidInRun(keccak256("INV-1001")), id);
        vm.prank(owner); vm.expectRevert(abi.encodeWithSelector(PayRun.NotStaged.selector, id)); pr.execute(id);
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRun.AlreadyPaid.selector, 0, keccak256("INV-1001"), id));
        pr.stage(one(line(ACME, acme, 120 * USD, "INV-1001")));
    }

    function test_unregistered_payee_cannot_be_staged() public {
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRun.PayeeNotRegistered.selector, 0, ACME, mallory, acme));
        pr.stage(one(line(ACME, mallory, 120 * USD, "INV-1001")));
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRun.PayeeNotRegistered.selector, 0, 404, mallory, address(0)));
        pr.stage(one(line(404, mallory, 1 * USD, "X")));
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRun.PayeeNotRegistered.selector, 0, 404, address(0), address(0)));
        pr.stage(one(line(404, address(0), 1 * USD, "Y")));
    }

    function test_wallet_changed_after_staging_blocks_execution() public {
        vm.prank(clerk); uint256 id = pr.stage(one(line(ACME, acme, 100 * USD, "INV-1")));
        reg.set(ACME, mallory);   // vendor's registered wallet changes (or is hijacked) before approval
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayRun.PayeeNotRegistered.selector, 0, ACME, acme, mallory));
        pr.execute(id);
        assertEq(usd.balanceOf(acme) + usd.balanceOf(mallory), 0);
    }

    function test_caps_per_run_and_per_day_with_reset() public {
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRun.RunCapExceeded.selector, 501 * USD, 500 * USD));
        pr.stage(one(line(ACME, acme, 501 * USD, "big")));
        vm.prank(clerk); pr.stage(one(line(ACME, acme, 500 * USD, "a1")));
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRun.DayCapExceeded.selector, 801 * USD, 800 * USD));
        pr.stage(one(line(ACME, acme, 301 * USD, "a2")));
        vm.prank(clerk); pr.stage(one(line(ACME, acme, 300 * USD, "a3")));
        (uint256 perRun, uint256 today) = pr.headroom(clerk);
        assertEq(today, 0); assertEq(perRun, 0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(clerk); pr.stage(one(line(ACME, acme, 500 * USD, "a4")));
    }

    function test_only_session_keys_stage_and_expiry_and_revoke_bite() public {
        vm.prank(mallory); vm.expectRevert(PayRun.NoSession.selector); pr.stage(one(line(ACME, acme, 1 * USD, "m")));
        vm.prank(owner); pr.revokeSession(clerk);
        vm.prank(clerk); vm.expectRevert(PayRun.SessionRevokedErr.selector); pr.stage(one(line(ACME, acme, 1 * USD, "r")));
        vm.prank(owner); pr.grantSession(clerk, uint64(block.timestamp + 1 hours), 10 * USD, 10 * USD);
        vm.prank(clerk); pr.stage(one(line(ACME, acme, 1 * USD, "ok")));
        vm.warp(block.timestamp + 1 hours);
        vm.prank(clerk); vm.expectRevert(PayRun.SessionExpired.selector); pr.stage(one(line(ACME, acme, 1 * USD, "late")));
    }

    function test_clerk_and_strangers_cannot_execute_reject_or_grant() public {
        vm.prank(clerk); uint256 id = pr.stage(one(line(ACME, acme, 10 * USD, "i")));
        vm.prank(clerk); vm.expectRevert(PayRun.NotOwner.selector); pr.execute(id);
        vm.prank(mallory); vm.expectRevert(PayRun.NotOwner.selector); pr.execute(id);
        vm.prank(clerk); vm.expectRevert(PayRun.NotOwner.selector); pr.reject(id, "x");
        vm.prank(clerk); vm.expectRevert(PayRun.NotOwner.selector); pr.grantSession(clerk, uint64(block.timestamp + 9 days), 1e30, 1e30);
        vm.prank(clerk); vm.expectRevert(PayRun.NotOwner.selector); pr.setTreasury(clerk);
    }

    function test_duplicates_and_reject_frees_invoices() public {
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRun.AlreadyStaged.selector, 1, keccak256("dup"), 1));
        pr.stage(two(line(ACME, acme, 1 * USD, "dup"), line(ACME, acme, 1 * USD, "dup")));
        vm.prank(clerk); uint256 id = pr.stage(one(line(ACME, acme, 5 * USD, "inv")));
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRun.AlreadyStaged.selector, 0, keccak256("inv"), id));
        pr.stage(one(line(ACME, acme, 5 * USD, "inv")));
        vm.prank(owner); pr.reject(id, "wrong amount");
        vm.prank(owner); vm.expectRevert(abi.encodeWithSelector(PayRun.NotStaged.selector, id)); pr.execute(id);
        vm.prank(clerk); pr.stage(one(line(ACME, acme, 4 * USD, "inv")));   // corrected line can be staged again
        vm.prank(clerk); vm.expectRevert(abi.encodeWithSelector(PayRun.ZeroAmount.selector, 0)); pr.stage(one(line(ACME, acme, 0, "z")));
    }

    function test_stale_runs_and_short_treasury_are_all_or_nothing() public {
        vm.prank(clerk); uint256 id = pr.stage(one(line(ACME, acme, 10 * USD, "old")));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(owner); vm.expectRevert(abi.encodeWithSelector(PayRun.RunStale.selector, id)); pr.execute(id);
        vm.prank(owner); pr.grantSession(clerk, uint64(block.timestamp + 7 days), 500 * USD, 800 * USD);
        vm.prank(clerk); uint256 id2 = pr.stage(two(line(ACME, acme, 100 * USD, "p1"), line(GLOBEX, globex, 100 * USD, "p2")));
        vm.prank(treasury); usd.approve(address(pr), 150 * USD);   // enough for line 0 only
        vm.prank(owner); vm.expectRevert(); pr.execute(id2);
        assertEq(usd.balanceOf(acme), 0, "nothing paid when one line fails");
        assertEq(pr.paidInRun(keccak256("p1")), 0);
    }

    function test_bad_session_params_refused() public {
        vm.startPrank(owner);
        vm.expectRevert(PayRun.BadSession.selector); pr.grantSession(address(0), uint64(block.timestamp + 1), 1, 1);
        vm.expectRevert(PayRun.BadSession.selector); pr.grantSession(clerk, uint64(block.timestamp), 1, 1);
        vm.expectRevert(PayRun.BadSession.selector); pr.grantSession(clerk, uint64(block.timestamp + 1), 0, 1);
        vm.expectRevert(PayRun.BadSession.selector); pr.grantSession(clerk, uint64(block.timestamp + 1), 2, 1);
        vm.stopPrank();
    }
}
