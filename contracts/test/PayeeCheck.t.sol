// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAgentIdentity} from "../src/PayRun.sol";
import {PayeeCheck, PayeeChecker, IPayeeHold} from "../src/PayeeCheck.sol";
import {VendorRegistry} from "../src/VendorRegistry.sol";
import {VendorRegistryV2} from "../src/VendorRegistryV2.sol";
import {PayRunV3} from "../src/PayRunV3.sol";
import {MockUSD} from "./PayRun.t.sol";

/// The README example: a marketplace escrow that releases funds only to the seller's registered, settled wallet.
contract ExampleEscrow {
    using PayeeCheck for IAgentIdentity;
    IAgentIdentity public immutable registry;
    IPayeeHold public immutable hold;
    event Released(uint256 agentId, address to, uint256 amount);
    constructor(IAgentIdentity r, IPayeeHold h) { registry = r; hold = h; }
    function release(uint256 sellerAgentId, address to, uint256 amount) external {
        registry.requireOk(hold, sellerAgentId, to);   // reverts PayeeCheckFailed(...) unless Ok
        emit Released(sellerAgentId, to, amount);      // ...transfer here
    }
}

/// An ERC-8004 registry with only the read function (like QDay's): no pending-change view.
contract PlainRegistry is IAgentIdentity {
    mapping(uint256 => address) public w;
    function set(uint256 id, address a) external { w[id] = a; }
    function getAgentWallet(uint256 id) external view returns (address) { return w[id]; }
}

/// A registry whose pendingWallet answer is malformed (dirty address bits) or burns gas: PayeeCheck must ignore it, not revert.
contract WeirdRegistry is IAgentIdentity {
    address public wallet; uint8 public mode;
    constructor(address a) { wallet = a; }
    function setMode(uint8 m) external { mode = m; }
    function getAgentWallet(uint256) external view returns (address) { return wallet; }
    function pendingWallet(uint256) external view returns (uint256, uint256) {
        if (mode == 1) return (type(uint256).max, 1);                    // dirty address bits
        if (mode == 2) { uint256 x; while (true) { x++; } }             // gas bomb
        if (mode == 3) return (uint256(uint160(address(0xBEEF))), uint256(1) << 70); // eta overflows uint64
        return (0, 0);
    }
}

contract Harness {
    function check(IAgentIdentity r, uint256 id, address p) external view returns (PayeeCheck.Result memory) {
        return PayeeCheck.check(r, id, p);
    }
    function checkHold(IAgentIdentity r, IPayeeHold h, uint256 id, address p) external view returns (PayeeCheck.Result memory) {
        return PayeeCheck.check(r, h, id, p);
    }
    function requireOk(IAgentIdentity r, uint256 id, address p) external view { PayeeCheck.requireOk(r, id, p); }
}

contract PayeeCheckTest is Test {
    Harness h; PayeeChecker checker;
    address owner = makeAddr("owner"); address verifier = makeAddr("verifier");
    address acme = makeAddr("acme"); address evil = makeAddr("evil");
    string constant URI = 'data:application/json,{"name":"Acme Supplies Ltd"}';

    function setUp() public {
        vm.warp(1_763_400_000);
        h = new Harness(); checker = new PayeeChecker();
    }

    function v(PayeeCheck.Result memory r) internal pure returns (uint8) { return uint8(r.verdict); }

    function test_v1_registry_ok_mismatch_unregistered() public {
        VendorRegistry reg = new VendorRegistry(owner);
        vm.prank(owner); reg.register(URI, acme);
        PayeeCheck.Result memory r = h.check(reg, 1, acme);
        assertEq(v(r), uint8(PayeeCheck.Verdict.Ok)); assertEq(r.registered, acme); assertEq(r.pendingEta, 0);
        assertEq(v(h.check(reg, 1, evil)), uint8(PayeeCheck.Verdict.Mismatch));
        assertEq(v(h.check(reg, 2, acme)), uint8(PayeeCheck.Verdict.Unregistered));
        vm.prank(owner); reg.setAgentWallet(1, address(0));
        assertEq(v(h.check(reg, 1, acme)), uint8(PayeeCheck.Verdict.Unregistered), "suspended");
    }

    function test_requireOk_reverts_with_the_verdict() public {
        PlainRegistry reg = new PlainRegistry();
        reg.set(1, acme);
        h.requireOk(reg, 1, acme);
        vm.expectRevert(abi.encodeWithSelector(PayeeCheck.PayeeCheckFailed.selector, 1, evil, PayeeCheck.Verdict.Mismatch, acme));
        h.requireOk(reg, 1, evil);
        vm.expectRevert(abi.encodeWithSelector(PayeeCheck.PayeeCheckFailed.selector, 2, acme, PayeeCheck.Verdict.Unregistered, address(0)));
        h.requireOk(reg, 2, acme);
    }

    function test_v2_pending_change_is_reported() public {
        VendorRegistryV2 reg = new VendorRegistryV2(owner, verifier, 48 hours);
        vm.prank(owner); reg.register(URI, acme);
        PayeeCheck.Result memory r = h.check(reg, 1, acme);
        assertEq(v(r), uint8(PayeeCheck.Verdict.Unregistered), "not active during its first 48 h");
        assertEq(r.pendingWallet, acme);
        vm.warp(block.timestamp + 48 hours); reg.applyAgentWallet(1);
        assertEq(v(h.check(reg, 1, acme)), uint8(PayeeCheck.Verdict.Ok));
        vm.prank(owner); reg.proposeAgentWallet(1, evil);
        r = h.check(reg, 1, acme);
        assertEq(v(r), uint8(PayeeCheck.Verdict.ChangePending));
        assertEq(r.pendingWallet, evil); assertEq(r.pendingEta, uint64(block.timestamp + 48 hours));
        assertEq(v(h.check(reg, 1, evil)), uint8(PayeeCheck.Verdict.Mismatch), "the proposed wallet is not payable yet");
        vm.prank(verifier); reg.cancelAgentWallet(1);
        assertEq(v(h.check(reg, 1, acme)), uint8(PayeeCheck.Verdict.Ok));
    }

    function test_registries_without_or_with_a_broken_pending_view() public {
        PlainRegistry plain = new PlainRegistry(); plain.set(1, acme);
        assertEq(v(h.check(plain, 1, acme)), uint8(PayeeCheck.Verdict.Ok));
        WeirdRegistry weird = new WeirdRegistry(acme);
        for (uint8 m = 0; m < 4; m++) {
            weird.setMode(m);
            PayeeCheck.Result memory r = h.check(weird, 1, acme);
            assertEq(v(r), uint8(PayeeCheck.Verdict.Ok), "malformed pending answer is ignored");
            assertEq(r.pendingWallet, address(0));
        }
    }

    function test_hold_source_payrunv3() public {
        MockUSD usd = new MockUSD();
        VendorRegistry reg = new VendorRegistry(owner);
        PayRunV3 pr = new PayRunV3(usd, reg, owner, owner);
        vm.prank(owner); reg.register(URI, acme);
        PayeeCheck.Result memory r = h.checkHold(reg, IPayeeHold(address(pr)), 1, acme);
        assertEq(v(r), uint8(PayeeCheck.Verdict.Held), "a new vendor is held by PayRunV3");
        assertEq(r.holdUntil, uint64(block.timestamp + 24 hours));
        vm.prank(owner); pr.confirmPayee(1, acme);
        assertEq(v(h.checkHold(reg, IPayeeHold(address(pr)), 1, acme)), uint8(PayeeCheck.Verdict.Ok));
        vm.prank(owner); reg.setAgentWallet(1, evil);                       // registry changed: held again
        assertEq(v(h.checkHold(reg, IPayeeHold(address(pr)), 1, evil)), uint8(PayeeCheck.Verdict.Held));
        vm.warp(block.timestamp + 24 hours);
        assertEq(v(h.checkHold(reg, IPayeeHold(address(pr)), 1, evil)), uint8(PayeeCheck.Verdict.Held),
            "an unseen change counts as a hold starting now: waiting alone releases nothing");
        pr.observePayee(1);                                                  // PayRunV3 records the change: hold starts
        vm.warp(block.timestamp + 24 hours - 1);
        assertEq(v(h.checkHold(reg, IPayeeHold(address(pr)), 1, evil)), uint8(PayeeCheck.Verdict.Held));
        vm.warp(block.timestamp + 1);
        assertEq(v(h.checkHold(reg, IPayeeHold(address(pr)), 1, evil)), uint8(PayeeCheck.Verdict.Ok), "released by time");
        assertEq(v(h.checkHold(reg, IPayeeHold(address(0)), 1, evil)), uint8(PayeeCheck.Verdict.Ok), "no hold source");
        // the external wrapper gives the same answer in one eth_call
        assertEq(uint8(checker.check(reg, IPayeeHold(address(pr)), 1, acme).verdict), uint8(PayeeCheck.Verdict.Mismatch));
    }

    function test_readme_example_escrow() public {
        MockUSD usd = new MockUSD();
        VendorRegistry reg = new VendorRegistry(owner);
        PayRunV3 pr = new PayRunV3(usd, reg, owner, owner);
        ExampleEscrow esc = new ExampleEscrow(reg, IPayeeHold(address(pr)));
        vm.prank(owner); reg.register(URI, acme);
        vm.expectRevert(abi.encodeWithSelector(PayeeCheck.PayeeCheckFailed.selector, 1, acme, PayeeCheck.Verdict.Held, acme));
        esc.release(1, acme, 5);
        vm.prank(owner); pr.confirmPayee(1, acme);
        esc.release(1, acme, 5);
        vm.expectRevert(abi.encodeWithSelector(PayeeCheck.PayeeCheckFailed.selector, 1, evil, PayeeCheck.Verdict.Mismatch, acme));
        esc.release(1, evil, 5);
    }
}
