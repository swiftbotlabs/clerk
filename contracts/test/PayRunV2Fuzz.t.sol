// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PayRunV2} from "../src/PayRunV2.sol";
import {MockUSD, MockRegistry} from "./PayRun.t.sol";

/// Property tests: whatever the clerk's key sends, the caps, the payee check and pay-once hold.
contract PayRunV2FuzzTest is Test {
    MockUSD usd; MockRegistry reg; PayRunV2 pr;
    address owner = makeAddr("owner"); address treasury = makeAddr("treasury");
    address clerk = makeAddr("clerk"); address acme = makeAddr("acme");
    uint256 constant ACME = 7;
    uint128 constant USD = 1e6;
    uint128 constant RUN_CAP = 500 * USD; uint128 constant DAY_CAP = 800 * USD;

    function setUp() public {
        vm.warp(1_763_400_000);
        usd = new MockUSD(); reg = new MockRegistry();
        pr = new PayRunV2(usd, reg, owner, treasury);
        reg.set(ACME, acme);
        usd.mint(treasury, 1_000_000 * USD);
        vm.prank(treasury); usd.approve(address(pr), type(uint256).max);
        vm.prank(owner); pr.grantSession(clerk, uint64(block.timestamp + 7 days), RUN_CAP, DAY_CAP);
        vm.prank(owner); pr.confirmPayee(ACME, acme);   // v2: onboard the known vendor (no hold)
    }

    function lines(uint256 n, uint128 each, uint256 salt) internal view returns (PayRunV2.Line[] memory a) {
        a = new PayRunV2.Line[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 h = keccak256(abi.encode(salt, i));
            a[i] = PayRunV2.Line({payeeAgentId: ACME, payee: acme, amount: each, invoiceHash: h, invoiceRef: h});
        }
    }

    /// A run over the per-run cap never stages; at or under it always does.
    function testFuzz_run_cap(uint8 n, uint128 each) public {
        n = uint8(bound(n, 1, 25)); each = uint128(bound(each, 1, 100 * USD));
        uint256 total = uint256(n) * each;
        vm.prank(clerk);
        if (total > RUN_CAP) { vm.expectRevert(abi.encodeWithSelector(PayRunV2.RunCapExceeded.selector, total, RUN_CAP)); pr.stage(lines(n, each, 1)); }
        else { uint256 id = pr.stage(lines(n, each, 1)); (, , , uint128 t, uint32 c) = pr.runs(id); assertEq(t, total); assertEq(c, n); }
    }

    /// Across any sequence of runs in one day, the staged total never passes the day cap; the next UTC day starts fresh.
    function testFuzz_day_cap(uint128[6] memory amts) public {
        uint256 staged;
        for (uint256 k = 0; k < amts.length; k++) {
            uint128 a = uint128(bound(amts[k], 1, RUN_CAP));
            vm.prank(clerk);
            try pr.stage(lines(1, a, 100 + k)) { staged += a; } catch {}
            assertLe(staged, DAY_CAP);
        }
        (, uint256 today) = pr.headroom(clerk);
        assertEq(today, DAY_CAP - staged);
        vm.warp(block.timestamp + 1 days);
        (, today) = pr.headroom(clerk);
        assertEq(today, DAY_CAP);
    }

    /// Any payee that is not the agent's registered wallet is refused, for any agent id.
    function testFuzz_wrong_payee_refused(address payee, uint256 agentId) public {
        vm.assume(payee != acme || agentId != ACME);
        PayRunV2.Line[] memory l = new PayRunV2.Line[](1);
        l[0] = PayRunV2.Line({payeeAgentId: agentId, payee: payee, amount: USD, invoiceHash: bytes32(uint256(1)), invoiceRef: bytes32(0)});
        address registered = reg.w(agentId);
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRunV2.PayeeNotRegistered.selector, 0, agentId, payee, registered));
        pr.stage(l);
    }

    /// Whoever calls, only the owner can execute, reject, grant, revoke or change owner/treasury.
    function testFuzz_only_owner(address who) public {
        vm.assume(who != owner);
        vm.prank(clerk); uint256 id = pr.stage(lines(1, USD, 7));
        vm.startPrank(who);
        vm.expectRevert(PayRunV2.NotOwner.selector); pr.execute(id);
        vm.expectRevert(PayRunV2.NotOwner.selector); pr.reject(id, "x");
        vm.expectRevert(PayRunV2.NotOwner.selector); pr.grantSession(who, uint64(block.timestamp + 1), 1, 1);
        vm.expectRevert(PayRunV2.NotOwner.selector); pr.revokeSession(clerk);
        vm.expectRevert(PayRunV2.NotOwner.selector); pr.setOwner(who);
        vm.expectRevert(PayRunV2.NotOwner.selector); pr.setTreasury(who);
        vm.stopPrank();
    }

    /// Executing pays exactly the staged total to the registered wallet, once; the treasury loses exactly that.
    function testFuzz_execute_moves_exactly_the_total(uint8 n, uint128 each) public {
        n = uint8(bound(n, 1, 25)); each = uint128(bound(each, 1, RUN_CAP / 25));
        vm.prank(clerk); uint256 id = pr.stage(lines(n, each, 3));
        uint256 before = usd.balanceOf(treasury);
        vm.prank(owner); pr.execute(id);
        assertEq(usd.balanceOf(acme), uint256(n) * each);
        assertEq(before - usd.balanceOf(treasury), uint256(n) * each);
        vm.prank(owner); vm.expectRevert(abi.encodeWithSelector(PayRunV2.NotStaged.selector, id)); pr.execute(id);
    }

    /// Line counts outside 1..25 never stage.
    function test_line_count_bounds() public {
        vm.startPrank(clerk);
        vm.expectRevert(PayRunV2.BadLines.selector); pr.stage(new PayRunV2.Line[](0));
        vm.expectRevert(PayRunV2.BadLines.selector); pr.stage(lines(26, 1, 9));
        pr.stage(lines(25, 1, 9));
        vm.stopPrank();
    }

    /// A zero amount line is refused (it would let an invoice be marked paid for nothing).
    function test_zero_amount_refused() public {
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRunV2.ZeroAmount.selector, 0));
        pr.stage(lines(1, 0, 11));
    }

    /// After setOwner the old owner has no power and the new one has all of it.
    function test_owner_handover() public {
        address next = makeAddr("next");
        vm.prank(owner); pr.setOwner(next);
        vm.prank(clerk); uint256 id = pr.stage(lines(1, USD, 12));
        vm.prank(owner); vm.expectRevert(PayRunV2.NotOwner.selector); pr.execute(id);
        vm.prank(next); pr.execute(id);
        assertEq(usd.balanceOf(acme), USD);
    }

    /// A run staged just inside the 7-day window can be executed; one second later it is stale.
    function test_run_ttl_edge() public {
        vm.prank(clerk); uint256 a = pr.stage(lines(1, USD, 13));
        vm.prank(clerk); uint256 b = pr.stage(lines(1, USD, 14));
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner); pr.execute(a);
        vm.warp(block.timestamp + 1);
        vm.prank(owner); vm.expectRevert(abi.encodeWithSelector(PayRunV2.RunStale.selector, b)); pr.execute(b);
    }

    /// A revoked or expired key shows zero headroom, and re-granting restores it.
    function test_headroom_tracks_session_state() public {
        vm.prank(owner); pr.revokeSession(clerk);
        (uint256 r, uint256 d) = pr.headroom(clerk); assertEq(r + d, 0);
        vm.prank(owner); pr.grantSession(clerk, uint64(block.timestamp + 1 hours), RUN_CAP, DAY_CAP);
        (r, d) = pr.headroom(clerk); assertEq(r, RUN_CAP); assertEq(d, DAY_CAP);
        vm.warp(block.timestamp + 1 hours);
        (r, d) = pr.headroom(clerk); assertEq(r + d, 0);
    }
}
