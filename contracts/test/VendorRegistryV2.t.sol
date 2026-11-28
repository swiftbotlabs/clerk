// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VendorRegistryV2} from "../src/VendorRegistryV2.sol";
import {PayRunV3} from "../src/PayRunV3.sol";
import {MockUSD} from "./PayRun.t.sol";

/// VendorRegistryV2: every change that can point money at a new wallet waits 48 hours in public and a second key (the
/// verifier) can cancel it; suspension is immediate; PayRunV3's payee-change hold still applies after a change lands.
contract VendorRegistryV2Test is Test {
    VendorRegistryV2 reg; MockUSD usd; PayRunV3 pr;
    address owner = makeAddr("owner"); address verifier = makeAddr("verifier");
    address treasury = makeAddr("treasury"); address clerk = makeAddr("clerk"); address mallory = makeAddr("mallory");
    uint256 acmeKey = 0xA11CE; uint256 malloryKey = 0xBAD;
    address acme; address evil;
    string constant URI = 'data:application/json,{"name":"Acme Supplies Ltd"}';
    uint64 constant DELAY = 48 hours;
    uint128 constant USD = 1e6;
    uint32 constant DUE = 20261215;

    function setUp() public {
        vm.warp(1_763_400_000);
        acme = vm.addr(acmeKey); evil = vm.addr(malloryKey);
        reg = new VendorRegistryV2(owner, verifier, DELAY);
        usd = new MockUSD();
        pr = new PayRunV3(usd, reg, owner, treasury);
        usd.mint(treasury, 1_000_000 * USD);
        vm.prank(treasury); usd.approve(address(pr), type(uint256).max);
        vm.prank(owner); pr.grantSession(clerk, uint64(block.timestamp + 30 days), 500 * USD, 100_000 * USD);
    }

    function _registerActive() internal returns (uint256 id) {
        vm.prank(owner); id = reg.register(URI, acme);
        vm.warp(block.timestamp + DELAY);
        reg.applyAgentWallet(id);
    }

    // ------------------------------------------------------------ timelock

    function test_new_vendor_wallet_is_pending_for_the_delay() public {
        uint64 eta = uint64(block.timestamp) + DELAY;
        vm.expectEmit(true, true, true, true); emit VendorRegistryV2.Registered(1, URI);
        vm.expectEmit(true, true, true, true); emit VendorRegistryV2.AgentWalletProposed(1, address(0), acme, eta);
        vm.prank(owner); assertEq(reg.register(URI, acme), 1);
        assertEq(reg.getAgentWallet(1), address(0), "not active yet: every PayRun refuses it");
        assertEq(reg.tokenURI(1), URI);
        (address w, uint64 e) = reg.pendingWallet(1);
        assertEq(w, acme); assertEq(e, eta);
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(VendorRegistryV2.TooEarly.selector, eta)); reg.applyAgentWallet(1);
        vm.warp(eta);
        vm.expectEmit(true, true, true, true); emit VendorRegistryV2.AgentWalletSet(1, address(0), acme);
        vm.prank(mallory); reg.applyAgentWallet(1);                // anyone may apply a matured change
        assertEq(reg.getAgentWallet(1), acme);
        (w, e) = reg.pendingWallet(1);
        assertEq(w, address(0)); assertEq(e, 0);
        vm.expectRevert(VendorRegistryV2.NothingPending.selector); reg.applyAgentWallet(1);
    }

    /// PLANTED CONTROL: the attack VendorRegistry v1 allowed (owner key changes the wallet in one transaction) does not land.
    function test_control_immediate_wallet_change_does_not_land() public {
        _registerActive();
        vm.prank(owner); reg.proposeAgentWallet(1, evil);
        assertEq(reg.getAgentWallet(1), acme, "the registry still answers the old wallet");
        uint64 eta = uint64(block.timestamp) + DELAY;
        vm.expectRevert(abi.encodeWithSelector(VendorRegistryV2.TooEarly.selector, eta)); reg.applyAgentWallet(1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VendorRegistryV2.TooEarly.selector, eta)); reg.applyAgentWallet(1);
        // there is no other wallet setter: the v1 one-step call is gone
        (bool ok,) = address(reg).call(abi.encodeWithSignature("setAgentWallet(uint256,address)", 1, evil));
        assertFalse(ok, "no one-step setter");
        assertEq(reg.getAgentWallet(1), acme);
    }

    function testFuzz_apply_before_delay_reverts(uint64 dt) public {
        _registerActive();
        vm.prank(owner); reg.proposeAgentWallet(1, evil);
        dt = uint64(bound(dt, 0, DELAY - 1));
        vm.warp(block.timestamp + dt);
        vm.expectRevert(); reg.applyAgentWallet(1);
        assertEq(reg.getAgentWallet(1), acme);
    }

    function test_new_proposal_restarts_the_delay() public {
        _registerActive();
        vm.prank(owner); reg.proposeAgentWallet(1, evil);
        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(owner); reg.proposeAgentWallet(1, mallory);       // replaces, eta moves out again
        vm.warp(block.timestamp + 1);
        vm.expectRevert(); reg.applyAgentWallet(1);
        vm.warp(block.timestamp + DELAY);
        reg.applyAgentWallet(1);
        assertEq(reg.getAgentWallet(1), mallory);
    }

    // ------------------------------------------------------------ second party

    function test_verifier_cancels_a_pending_change() public {
        _registerActive();
        vm.prank(owner); reg.proposeAgentWallet(1, evil);
        vm.expectEmit(true, true, true, true); emit VendorRegistryV2.AgentWalletProposalCancelled(1, evil, verifier);
        vm.prank(verifier); reg.cancelAgentWallet(1);
        vm.warp(block.timestamp + DELAY * 10);
        vm.expectRevert(VendorRegistryV2.NothingPending.selector); reg.applyAgentWallet(1);
        assertEq(reg.getAgentWallet(1), acme);
        // the owner can withdraw its own proposal too
        vm.prank(owner); reg.proposeAgentWallet(1, evil);
        vm.prank(owner); reg.cancelAgentWallet(1);
        vm.prank(verifier); vm.expectRevert(VendorRegistryV2.NothingPending.selector); reg.cancelAgentWallet(1);
    }

    function test_roles_are_separate() public {
        _registerActive();
        vm.startPrank(verifier);   // the verifier can only cancel or suspend
        vm.expectRevert(VendorRegistryV2.NotOwner.selector); reg.register(URI, verifier);
        vm.expectRevert(VendorRegistryV2.NotOwner.selector); reg.proposeAgentWallet(1, verifier);
        vm.expectRevert(VendorRegistryV2.NotOwner.selector); reg.setAgentURI(1, URI);
        vm.expectRevert(VendorRegistryV2.NotOwner.selector); reg.proposeOwner(verifier);
        vm.stopPrank();
        vm.startPrank(mallory);
        vm.expectRevert(VendorRegistryV2.NotOwner.selector); reg.register(URI, mallory);
        vm.expectRevert(VendorRegistryV2.NotOwner.selector); reg.proposeAgentWallet(1, mallory);
        vm.expectRevert(VendorRegistryV2.NotOwnerOrVerifier.selector); reg.cancelAgentWallet(1);
        vm.expectRevert(VendorRegistryV2.NotOwnerOrVerifier.selector); reg.suspend(1);
        vm.expectRevert(VendorRegistryV2.NotOwnerOrVerifier.selector); reg.cancelOwner();
        vm.expectRevert(VendorRegistryV2.NotVerifier.selector); reg.setVerifier(mallory);
        vm.stopPrank();
        // a stolen owner key can't remove the second party
        vm.prank(owner); vm.expectRevert(VendorRegistryV2.NotVerifier.selector); reg.setVerifier(owner);
        vm.prank(clerk); vm.expectRevert(VendorRegistryV2.NotOwner.selector); reg.proposeAgentWallet(1, clerk);
    }

    function test_verifier_handover_only_by_verifier() public {
        address v2 = makeAddr("v2");
        vm.prank(verifier); vm.expectRevert(VendorRegistryV2.BadVerifier.selector); reg.setVerifier(owner);
        vm.prank(verifier); vm.expectRevert(VendorRegistryV2.BadVerifier.selector); reg.setVerifier(address(0));
        vm.expectEmit(true, true, true, true); emit VendorRegistryV2.VerifierChanged(verifier, v2);
        vm.prank(verifier); reg.setVerifier(v2);
        assertEq(reg.verifier(), v2);
    }

    function test_suspend_is_immediate_and_cancels_the_pending_change() public {
        _registerActive();
        vm.prank(owner); reg.proposeAgentWallet(1, evil);
        vm.prank(verifier); reg.suspend(1);
        assertEq(reg.getAgentWallet(1), address(0));
        (, uint64 e) = reg.pendingWallet(1);
        assertEq(e, 0, "the suspicious change is gone with the suspension");
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(VendorRegistryV2.NothingPending.selector); reg.applyAgentWallet(1);
        // reinstating is a proposal like any other
        vm.prank(owner); reg.proposeAgentWallet(1, acme);
        assertEq(reg.getAgentWallet(1), address(0));
        vm.warp(block.timestamp + DELAY); reg.applyAgentWallet(1);
        assertEq(reg.getAgentWallet(1), acme);
        vm.prank(owner); reg.suspend(1);                            // the owner can suspend too
        assertEq(reg.getAgentWallet(1), address(0));
        vm.prank(owner); vm.expectRevert(abi.encodeWithSelector(VendorRegistryV2.UnknownAgent.selector, 7)); reg.suspend(7);
    }

    function test_owner_change_is_timelocked_accepted_and_cancellable() public {
        address next = makeAddr("next");
        vm.prank(owner); reg.proposeOwner(mallory);
        vm.prank(verifier); reg.cancelOwner();
        vm.warp(block.timestamp + DELAY);
        vm.prank(mallory); vm.expectRevert(VendorRegistryV2.NothingPending.selector); reg.acceptOwner();
        vm.prank(owner); reg.proposeOwner(next);
        vm.prank(next); vm.expectRevert(); reg.acceptOwner();                  // too early
        vm.warp(block.timestamp + DELAY);
        vm.prank(mallory); vm.expectRevert(VendorRegistryV2.NotOwner.selector); reg.acceptOwner();
        vm.prank(next); reg.acceptOwner();
        assertEq(reg.owner(), next);
        vm.prank(owner); vm.expectRevert(VendorRegistryV2.NotOwner.selector); reg.register(URI, acme);
    }

    function test_input_checks() public {
        vm.expectRevert(VendorRegistryV2.ZeroAddress.selector); new VendorRegistryV2(address(0), verifier, DELAY);
        vm.expectRevert(VendorRegistryV2.BadVerifier.selector); new VendorRegistryV2(owner, address(0), DELAY);
        vm.expectRevert(VendorRegistryV2.BadVerifier.selector); new VendorRegistryV2(owner, owner, DELAY);
        vm.expectRevert(VendorRegistryV2.BadDelay.selector); new VendorRegistryV2(owner, verifier, 0);
        vm.expectRevert(VendorRegistryV2.BadDelay.selector); new VendorRegistryV2(owner, verifier, 7 days + 1);
        _registerActive();
        vm.startPrank(owner);
        vm.expectRevert(VendorRegistryV2.ZeroAddress.selector); reg.register(URI, address(0));
        vm.expectRevert(VendorRegistryV2.BadURI.selector); reg.register("", acme);
        vm.expectRevert(VendorRegistryV2.BadURI.selector); reg.register(string(new bytes(4097)), acme);
        vm.expectRevert(abi.encodeWithSelector(VendorRegistryV2.SameWallet.selector, 1, acme)); reg.proposeAgentWallet(1, acme);
        vm.expectRevert(VendorRegistryV2.ZeroAddress.selector); reg.proposeAgentWallet(1, address(0));
        vm.expectRevert(abi.encodeWithSelector(VendorRegistryV2.UnknownAgent.selector, 9)); reg.proposeAgentWallet(9, acme);
        vm.expectRevert(VendorRegistryV2.BadVerifier.selector); reg.proposeOwner(verifier);
        vm.expectRevert(VendorRegistryV2.ZeroAddress.selector); reg.proposeOwner(address(0));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(VendorRegistryV2.UnknownAgent.selector, 0)); reg.tokenURI(0);
    }

    // ------------------------------------------------------------ with PayRunV3 on top (defence in depth)

    function line(address payee, string memory inv) internal pure returns (PayRunV3.Line[] memory a) {
        a = new PayRunV3.Line[](1);
        a[0] = PayRunV3.Line({payeeAgentId: 1, payee: payee, amount: 10 * USD, invoiceHash: keccak256(bytes(inv)), invoiceRef: bytes32(bytes(inv))});
    }
    function sig(uint256 key, PayRunV3.Line memory l) internal view returns (PayRunV3.Proof[] memory p) {
        bytes32 sh = keccak256(abi.encode(keccak256("Invoice(uint256 payeeAgentId,address payee,uint128 amount,bytes32 invoiceHash,uint32 dueDate)"),
            l.payeeAgentId, l.payee, l.amount, l.invoiceHash, DUE));
        bytes32 dom = keccak256(abi.encode(keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Clerk PayRun"), keccak256("3"), block.chainid, address(pr)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", dom, sh)));
        p = new PayRunV3.Proof[](1); p[0] = PayRunV3.Proof(DUE, abi.encodePacked(r, s, v));
    }

    /// A stolen owner key proposes the attacker's wallet. During the 48 h the registry still answers Acme's wallet, so the
    /// clerk can't stage to the attacker (PayeeNotRegistered) and the verifier cancels. Nothing is paid to the attacker.
    function test_stolen_owner_key_redirect_is_cancelled_in_the_window() public {
        _registerActive();
        vm.startPrank(owner); pr.confirmPayee(1, acme); pr.setSignedOnly(1, true); vm.stopPrank();
        vm.prank(owner); reg.proposeAgentWallet(1, evil);              // the attacker, holding the owner key
        PayRunV3.Line[] memory l = line(evil, "INV-X");
        PayRunV3.Proof[] memory p = sig(malloryKey, l[0]);
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRunV3.PayeeNotRegistered.selector, 0, 1, evil, acme));
        pr.stageSigned(l, p);
        vm.prank(verifier); reg.cancelAgentWallet(1);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(VendorRegistryV2.NothingPending.selector); reg.applyAgentWallet(1);
        assertEq(usd.balanceOf(evil), 0);
        // Acme is still paid as before
        PayRunV3.Line[] memory g = line(acme, "INV-1");
        vm.prank(clerk); uint256 id = pr.stageSigned(g, sig(acmeKey, g[0]));
        vm.prank(owner); assertTrue(pr.execute(id));
        assertEq(usd.balanceOf(acme), 10 * USD);
    }

    /// Nobody cancels: the change lands after 48 h, and PayRunV3 still holds the new wallet (24 h default) and needs the
    /// owner's confirmation for a line staged during that hold. Two independent brakes, in sequence.
    function test_uncancelled_change_still_meets_the_payrun_hold() public {
        _registerActive();
        vm.startPrank(owner); pr.confirmPayee(1, acme); pr.setSignedOnly(1, true); vm.stopPrank();
        vm.prank(owner); reg.proposeAgentWallet(1, evil);
        vm.warp(block.timestamp + DELAY);
        reg.applyAgentWallet(1);
        assertEq(reg.getAgentWallet(1), evil);
        PayRunV3.Line[] memory l = line(evil, "INV-X");
        vm.prank(clerk); uint256 id = pr.stageSigned(l, sig(malloryKey, l[0]));
        vm.prank(owner); assertFalse(pr.execute(id), "held by PayRunV3");
        assertEq(usd.balanceOf(evil), 0);
    }
}
