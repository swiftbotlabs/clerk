// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PayRunV2} from "../src/PayRunV2.sol";
import {MockUSD, MockRegistry} from "./PayRun.t.sol";

/// The payee-change hold: new payees and the first payment after any wallet change wait for the hold or the owner.
contract PayRunV2HoldTest is Test {
    MockUSD usd; MockRegistry reg; PayRunV2 pr;
    address owner = makeAddr("owner"); address treasury = makeAddr("treasury");
    address clerk = makeAddr("clerk"); address mallory = makeAddr("mallory");
    address acme = makeAddr("acme"); address acme2 = makeAddr("acme-new-bank");
    uint256 constant ACME = 7;
    uint128 constant USD = 1e6;
    uint64 constant HOLD = 24 hours;
    uint8 constant HOLD_R = 1; uint8 constant CONFIRM_R = 2; uint8 constant CHANGED_R = 3;

    function setUp() public {
        vm.warp(1_763_400_000);
        usd = new MockUSD(); reg = new MockRegistry();
        pr = new PayRunV2(usd, reg, owner, treasury);
        reg.set(ACME, acme);
        usd.mint(treasury, 1_000_000 * USD);
        vm.prank(treasury); usd.approve(address(pr), type(uint256).max);
        vm.prank(owner); pr.grantSession(clerk, uint64(block.timestamp + 30 days), 500 * USD, 100_000 * USD);
    }

    function one(address payee, uint128 amt, string memory inv) internal pure returns (PayRunV2.Line[] memory a) {
        a = new PayRunV2.Line[](1);
        a[0] = PayRunV2.Line({payeeAgentId: ACME, payee: payee, amount: amt, invoiceHash: keccak256(bytes(inv)), invoiceRef: bytes32(bytes(inv))});
    }
    function stage(address payee, string memory inv) internal returns (uint256 id) {
        vm.prank(clerk); id = pr.stage(one(payee, 10 * USD, inv));
    }
    function exec(uint256 id) internal returns (bool ok) { vm.prank(owner); ok = pr.execute(id); }
    function status(uint256 id) internal view returns (PayRunV2.Status st) { (st, , , , ) = pr.runs(id); }
    function state() internal view returns (PayRunV2.PayeeState s) { (s, , , ) = pr.payeeStatus(ACME); }
    /// Acme is trusted and has been paid once at its first wallet.
    function trustAcme() internal {
        vm.prank(owner); pr.confirmPayee(ACME, acme);
        assertTrue(exec(stage(acme, "seed")));
    }

    // ------------------------------------------------------------ new payees

    function test_default_window_and_bounds() public {
        assertEq(pr.holdWindow(), HOLD);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayRunV2.BadHoldWindow.selector, uint64(1 hours - 1))); pr.setHoldWindow(1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(PayRunV2.BadHoldWindow.selector, uint64(3 days + 1))); pr.setHoldWindow(3 days + 1);
        vm.expectRevert(abi.encodeWithSelector(PayRunV2.BadHoldWindow.selector, uint64(0))); pr.setHoldWindow(0);
        vm.expectEmit(true, true, true, true); emit PayRunV2.HoldWindowChanged(HOLD, 3 days);
        pr.setHoldWindow(3 days);
        pr.setHoldWindow(1 hours);
        vm.stopPrank();
        assertEq(pr.holdWindow(), 1 hours);
    }

    function test_new_payee_is_held_with_events_and_payment_blocked() public {
        uint64 rel = uint64(block.timestamp) + HOLD;
        vm.expectEmit(true, true, true, true); emit PayRunV2.PayeeChanged(ACME, address(0), acme, 1);
        vm.expectEmit(true, true, true, true); emit PayRunV2.HoldStarted(ACME, acme, rel);
        vm.expectEmit(true, true, true, true); emit PayRunV2.StagedOnHold(1, 0, ACME, acme, rel);
        uint256 id = stage(acme, "INV-1");
        assertEq(uint8(state()), uint8(PayRunV2.PayeeState.Held));
        (bool ok, , uint8 why, uint64 until) = pr.canExecute(id);
        assertFalse(ok); assertEq(why, HOLD_R); assertEq(until, rel);
        vm.expectEmit(true, true, true, true); emit PayRunV2.PaymentBlocked(id, 0, ACME, acme, HOLD_R, rel);
        assertFalse(exec(id));
        assertEq(usd.balanceOf(acme), 0);
        assertEq(uint8(status(id)), uint8(PayRunV2.Status.Staged), "held run stays staged");
    }

    function test_run_staged_during_hold_cannot_be_paid_by_waiting() public {
        uint256 id = stage(acme, "INV-1");
        vm.warp(block.timestamp + 3 days);
        assertEq(uint8(state()), uint8(PayRunV2.PayeeState.Released));
        (bool ok, , uint8 why, ) = pr.canExecute(id);
        assertFalse(ok); assertEq(why, CONFIRM_R);
        assertFalse(exec(id));
        assertEq(usd.balanceOf(acme), 0);
        vm.prank(owner); pr.confirmPayee(ACME, acme);
        assertTrue(exec(id));
        assertEq(usd.balanceOf(acme), 10 * USD);
    }

    function test_hold_releases_by_time_for_runs_staged_after_it() public {
        pr.observePayee(ACME);                         // a watcher sees the new vendor: the clock starts now
        vm.warp(block.timestamp + HOLD - 1);
        uint256 early = stage(acme, "early");
        assertFalse(exec(early));
        vm.warp(block.timestamp + 1);                  // hold over
        uint256 id = stage(acme, "INV-2");
        vm.expectEmit(true, true, true, true); emit PayRunV2.HoldReleased(ACME, acme, false);
        assertTrue(exec(id));
        assertEq(usd.balanceOf(acme), 10 * USD);
        assertEq(uint8(state()), uint8(PayRunV2.PayeeState.Trusted), "paid after its hold: now trusted");
        assertFalse(exec(early), "the run staged during the hold still needs the owner");
        vm.prank(owner); pr.confirmPayee(ACME, acme);
        assertTrue(exec(early));
        assertEq(usd.balanceOf(acme), 20 * USD);
    }

    function test_clock_starts_when_first_seen_not_when_registered() public {
        vm.warp(block.timestamp + 20 days);            // registered long ago, never seen by this contract
        uint256 id = stage(acme, "INV-1");
        assertFalse(exec(id));
        (, , uint64 rel, ) = pr.payeeStatus(ACME);
        assertEq(rel, uint64(block.timestamp) + HOLD);
    }

    // ------------------------------------------------------------ payee changes

    function test_first_payment_after_a_change_is_held() public {
        trustAcme();
        assertEq(uint8(state()), uint8(PayRunV2.PayeeState.Trusted));
        reg.set(ACME, acme2);                          // "we have new bank details"
        uint64 rel = uint64(block.timestamp) + HOLD;
        vm.expectEmit(true, true, true, true); emit PayRunV2.PayeeChanged(ACME, acme, acme2, 2);
        vm.expectEmit(true, true, true, true); emit PayRunV2.HoldStarted(ACME, acme2, rel);
        uint256 id = stage(acme2, "INV-2");
        assertFalse(exec(id));
        assertEq(usd.balanceOf(acme2), 0);
        (PayRunV2.PayeeState s, address w, , uint32 changes) = pr.payeeStatus(ACME);
        assertEq(uint8(s), uint8(PayRunV2.PayeeState.Held)); assertEq(w, acme2); assertEq(changes, 2);
    }

    function test_owner_confirmation_releases_early_and_is_logged() public {
        trustAcme();
        reg.set(ACME, acme2);
        uint256 id = stage(acme2, "INV-2");
        (, , uint64 rel, ) = pr.payeeStatus(ACME);
        vm.warp(block.timestamp + 1 hours);
        vm.expectEmit(true, true, true, true); emit PayRunV2.PayeeConfirmed(ACME, acme2, owner, rel);
        vm.expectEmit(true, true, true, true); emit PayRunV2.HoldReleased(ACME, acme2, true);
        vm.prank(owner); pr.confirmPayee(ACME, acme2);
        assertTrue(exec(id));
        assertEq(usd.balanceOf(acme2), 10 * USD);
        vm.prank(owner); vm.expectRevert(abi.encodeWithSelector(PayRunV2.AlreadyTrusted.selector, ACME, acme2)); pr.confirmPayee(ACME, acme2);
    }

    function test_confirm_only_the_wallet_registered_now() public {
        trustAcme();
        reg.set(ACME, acme2);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayRunV2.ConfirmMismatch.selector, ACME, mallory, acme2)); pr.confirmPayee(ACME, mallory);
        vm.expectRevert(abi.encodeWithSelector(PayRunV2.ConfirmMismatch.selector, ACME, acme, acme2)); pr.confirmPayee(ACME, acme);
        vm.expectRevert(abi.encodeWithSelector(PayRunV2.ConfirmMismatch.selector, 404, address(0), address(0))); pr.confirmPayee(404, address(0));
        vm.stopPrank();
    }

    function test_clerk_can_never_confirm_or_change_the_window() public {
        uint256 id = stage(acme, "INV-1");
        vm.startPrank(clerk);
        vm.expectRevert(PayRunV2.NotOwner.selector); pr.confirmPayee(ACME, acme);
        vm.expectRevert(PayRunV2.NotOwner.selector); pr.setHoldWindow(1 hours);
        vm.expectRevert(PayRunV2.NotOwner.selector); pr.execute(id);
        pr.observePayee(ACME);                         // observing is harmless: it changes nothing here
        vm.stopPrank();
        assertEq(uint8(state()), uint8(PayRunV2.PayeeState.Held));
    }

    function test_window_change_does_not_shorten_a_running_hold() public {
        uint256 id = stage(acme, "INV-1");
        (, , uint64 rel, ) = pr.payeeStatus(ACME);
        vm.prank(owner); pr.setHoldWindow(1 hours);
        vm.warp(block.timestamp + 2 hours);
        (bool ok, , uint8 why, uint64 until) = pr.canExecute(id);
        assertFalse(ok); assertEq(why, HOLD_R); assertEq(until, rel);
    }

    // ------------------------------------------------------------ no bypass

    function test_ABA_withdraws_trust_and_restarts_the_hold() public {
        trustAcme();
        reg.set(ACME, mallory); pr.observePayee(ACME);
        vm.warp(block.timestamp + 23 hours);
        reg.set(ACME, acme);                           // back to the old wallet
        uint64 rel = uint64(block.timestamp) + HOLD;
        vm.expectEmit(true, true, true, true); emit PayRunV2.PayeeChanged(ACME, mallory, acme, 3);
        vm.expectEmit(true, true, true, true); emit PayRunV2.HoldStarted(ACME, acme, rel);
        uint256 id = stage(acme, "INV-2");
        assertEq(uint8(state()), uint8(PayRunV2.PayeeState.Held), "A is not 'known' again");
        assertFalse(exec(id));
        vm.warp(block.timestamp + 2 hours);            // mallory's 24 h would have passed by now; acme's has not
        (bool ok, , uint8 why, ) = pr.canExecute(id);
        assertFalse(ok); assertEq(why, HOLD_R);
    }

    function test_change_to_no_wallet_and_back_is_held() public {
        trustAcme();
        reg.set(ACME, address(0)); pr.observePayee(ACME);
        assertEq(uint8(state()), uint8(PayRunV2.PayeeState.None));
        reg.set(ACME, acme);
        assertFalse(exec(stage(acme, "INV-2")));
    }

    function test_run_targeting_a_wallet_changed_after_staging_is_refused() public {
        trustAcme();
        uint256 id = stage(acme, "INV-2");             // staged to the trusted wallet: payable
        (bool ok, , , ) = pr.canExecute(id); assertTrue(ok);
        reg.set(ACME, acme2);                          // changed after staging
        (ok, , , ) = pr.canExecute(id); assertFalse(ok);
        vm.expectEmit(true, true, true, true); emit PayRunV2.PaymentBlocked(id, 0, ACME, acme, CHANGED_R, uint64(block.timestamp) + HOLD);
        assertFalse(exec(id));
        assertEq(uint8(status(id)), uint8(PayRunV2.Status.Rejected), "closed for good");
        assertEq(pr.stagedInRun(keccak256("INV-2")), 0, "invoice freed for a restage");
        (PayRunV2.PayeeState s, address w, , ) = pr.payeeStatus(ACME);
        assertEq(uint8(s), uint8(PayRunV2.PayeeState.Held), "the change was recorded"); assertEq(w, acme2);
        vm.prank(owner); vm.expectRevert(abi.encodeWithSelector(PayRunV2.NotStaged.selector, id)); pr.execute(id);
        assertFalse(exec(stage(acme2, "INV-2")), "restaged to the new wallet: held");
    }

    function test_ABA_between_staging_and_execution_is_refused() public {
        trustAcme();
        uint256 id = stage(acme, "INV-2");
        reg.set(ACME, mallory); pr.observePayee(ACME);
        reg.set(ACME, acme); pr.observePayee(ACME);    // the registry shows the staged wallet again
        (bool ok, , uint8 why, ) = pr.canExecute(id);
        assertFalse(ok); assertEq(why, CHANGED_R);
        vm.prank(owner); pr.confirmPayee(ACME, acme);  // even a confirmation of A does not revive the old run
        assertFalse(exec(id));
        assertEq(uint8(status(id)), uint8(PayRunV2.Status.Rejected));
        assertEq(usd.balanceOf(acme), 10 * USD, "only the seed payment");
    }

    function test_trusted_payee_pays_without_a_hold() public {
        trustAcme();
        uint256 id = stage(acme, "INV-2");
        assertTrue(exec(id));
        assertEq(usd.balanceOf(acme), 20 * USD);
    }

    // ------------------------------------------------------------ properties

    /// Any sequence of wallet changes the contract sees (A -> X1 -> ... -> A) leaves A untrusted: a payment staged right
    /// after is blocked, waiting any time does not release it, and only the owner's confirmation does.
    function testFuzz_no_bypass_by_flipping_back(uint8 flips, uint256 seed) public {
        trustAcme();
        flips = uint8(bound(flips, 1, 12));
        address[3] memory ws = [mallory, acme2, acme];
        reg.set(ACME, mallory); pr.observePayee(ACME);  // at least one change seen
        for (uint256 k = 0; k < flips; k++) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            reg.set(ACME, ws[r % 3]);
            if ((r >> 8) & 1 == 1) pr.observePayee(ACME);
            vm.warp(block.timestamp + ((r >> 16) % 1 hours));
        }
        reg.set(ACME, acme);
        uint256 id = stage(acme, "after-flips");
        assertTrue(uint8(state()) != uint8(PayRunV2.PayeeState.Trusted), "never 'known' again by flipping back");
        assertFalse(exec(id));
        vm.warp(block.timestamp + 5 days);             // any wait (still inside the 7-day run TTL)
        assertFalse(exec(id));
        assertEq(usd.balanceOf(acme), 10 * USD, "only the seed payment");
        assertEq(usd.balanceOf(mallory) + usd.balanceOf(acme2), 0);
        vm.prank(owner); pr.confirmPayee(ACME, acme);
        assertTrue(exec(id));
    }

    /// Nobody but the owner can confirm a payee or set the window.
    function testFuzz_only_owner_confirms(address who) public {
        vm.assume(who != owner);
        reg.set(ACME, acme);
        vm.startPrank(who);
        vm.expectRevert(PayRunV2.NotOwner.selector); pr.confirmPayee(ACME, acme);
        vm.expectRevert(PayRunV2.NotOwner.selector); pr.setHoldWindow(2 hours);
        vm.stopPrank();
    }

    /// Any window outside 1 h .. 3 days is refused; any inside is applied to the next hold exactly.
    function testFuzz_window_bounds(uint64 w) public {
        vm.prank(owner);
        if (w < 1 hours || w > 3 days) { vm.expectRevert(abi.encodeWithSelector(PayRunV2.BadHoldWindow.selector, w)); pr.setHoldWindow(w); return; }
        pr.setHoldWindow(w);
        pr.observePayee(ACME);
        (, , uint64 rel, ) = pr.payeeStatus(ACME);
        assertEq(rel, uint64(block.timestamp) + w);
    }

    /// canExecute always agrees with what execute does, for a random history of changes, waits and confirmations.
    function testFuzz_canExecute_matches_execute(uint256 seed) public {
        trustAcme();
        uint256 id = stage(acme, "x");
        address[3] memory ws = [mallory, acme2, acme];
        for (uint256 k = 0; k < 4; k++) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            if (r & 3 == 0) reg.set(ACME, ws[(r >> 2) % 3]);
            if ((r >> 4) & 3 == 1) pr.observePayee(ACME);
            if ((r >> 6) & 3 == 2) { address cur = reg.w(ACME); vm.prank(owner); try pr.confirmPayee(ACME, cur) {} catch {} }
            vm.warp(block.timestamp + ((r >> 8) % 30 hours));
        }
        (bool ok, , , ) = pr.canExecute(id);
        uint256 before = usd.balanceOf(acme);
        vm.prank(owner);
        try pr.execute(id) returns (bool paid) { assertEq(paid, ok); assertEq(usd.balanceOf(acme) - before, ok ? 10 * USD : 0); }
        catch { assertFalse(ok); }     // only RunStale can revert here
    }
}
