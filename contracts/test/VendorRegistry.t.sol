// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VendorRegistry} from "../src/VendorRegistry.sol";
import {PayRunV3} from "../src/PayRunV3.sol";
import {MockUSD} from "./PayRun.t.sol";

/// Our own vendor registry (the kit: "keep the name-to-address mapping in your own contract"): owner-curated writes, ERC-8004
/// reads, and the payee-change hold of PayRunV3 working on top of it exactly as on QDay's registry.
contract VendorRegistryTest is Test {
    VendorRegistry reg; MockUSD usd; PayRunV3 pr;
    address owner = makeAddr("owner"); address treasury = makeAddr("treasury"); address clerk = makeAddr("clerk");
    address mallory = makeAddr("mallory");
    uint256 acmeKey = 0xA11CE; uint256 malloryKey = 0xBAD;
    address acme; address acmeNew;
    string constant URI = 'data:application/json,{"name":"Acme Supplies Ltd"}';
    uint128 constant USD = 1e6;
    uint32 constant DUE = 20261215;

    function setUp() public {
        vm.warp(1_763_400_000);
        acme = vm.addr(acmeKey); acmeNew = vm.addr(malloryKey);
        reg = new VendorRegistry(owner);
        usd = new MockUSD();
        pr = new PayRunV3(usd, reg, owner, treasury);
        usd.mint(treasury, 1_000_000 * USD);
        vm.prank(treasury); usd.approve(address(pr), type(uint256).max);
        vm.prank(owner); pr.grantSession(clerk, uint64(block.timestamp + 30 days), 500 * USD, 100_000 * USD);
    }

    function test_register_reads_like_erc8004() public {
        vm.expectEmit(true, true, true, true); emit VendorRegistry.Registered(1, acme, URI);
        vm.expectEmit(true, true, true, true); emit VendorRegistry.AgentWalletSet(1, address(0), acme);
        vm.prank(owner); uint256 id = reg.register(URI, acme);
        assertEq(id, 1); assertEq(reg.count(), 1);
        assertEq(reg.getAgentWallet(1), acme);
        assertEq(reg.tokenURI(1), URI);
        assertEq(reg.getAgentWallet(2), address(0), "unknown vendor reads as zero");
        vm.expectRevert(abi.encodeWithSelector(VendorRegistry.UnknownAgent.selector, 2)); reg.tokenURI(2);
        vm.expectRevert(abi.encodeWithSelector(VendorRegistry.UnknownAgent.selector, 0)); reg.tokenURI(0);
        vm.prank(owner); assertEq(reg.register(URI, acme), 2, "ids are never reused");
    }

    function test_only_owner_writes() public {
        vm.prank(owner); reg.register(URI, acme);
        vm.startPrank(mallory);
        vm.expectRevert(VendorRegistry.NotOwner.selector); reg.register(URI, mallory);
        vm.expectRevert(VendorRegistry.NotOwner.selector); reg.setAgentWallet(1, mallory);
        vm.expectRevert(VendorRegistry.NotOwner.selector); reg.setAgentURI(1, URI);
        vm.expectRevert(VendorRegistry.NotOwner.selector); reg.setOwner(mallory);
        vm.stopPrank();
        // the clerk's session key is no registry admin either
        vm.prank(clerk); vm.expectRevert(VendorRegistry.NotOwner.selector); reg.setAgentWallet(1, clerk);
        assertEq(reg.getAgentWallet(1), acme);
    }

    function test_input_checks() public {
        vm.startPrank(owner);
        vm.expectRevert(VendorRegistry.ZeroAddress.selector); reg.register(URI, address(0));
        vm.expectRevert(VendorRegistry.BadURI.selector); reg.register("", acme);
        vm.expectRevert(VendorRegistry.BadURI.selector); reg.register(string(new bytes(4097)), acme);
        reg.register(URI, acme);
        vm.expectRevert(abi.encodeWithSelector(VendorRegistry.SameWallet.selector, 1, acme)); reg.setAgentWallet(1, acme);
        vm.expectRevert(abi.encodeWithSelector(VendorRegistry.UnknownAgent.selector, 9)); reg.setAgentWallet(9, acme);
        vm.expectRevert(VendorRegistry.ZeroAddress.selector); reg.setOwner(address(0));
        vm.expectRevert(VendorRegistry.ZeroAddress.selector); new VendorRegistry(address(0));
        vm.stopPrank();
    }

    function test_owner_handover() public {
        vm.expectEmit(true, true, true, true); emit VendorRegistry.OwnerChanged(owner, mallory);
        vm.prank(owner); reg.setOwner(mallory);
        vm.prank(owner); vm.expectRevert(VendorRegistry.NotOwner.selector); reg.register(URI, acme);
    }

    // ------------------------------------------------------------ with PayRunV3 on top

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
    function stageSigned(uint256 key, address payee, string memory inv) internal returns (uint256 id) {
        PayRunV3.Line[] memory l = line(payee, inv);
        vm.prank(clerk); id = pr.stageSigned(l, sig(key, l[0]));
    }
    function exec(uint256 id) internal returns (bool ok) { vm.prank(owner); ok = pr.execute(id); }

    /// The vendor master record changed (a social-engineered "new bank details" request, or a stolen admin key): the new wallet
    /// can sign, but PayRunV3 holds it; changing back to the old wallet does not restore trust.
    function test_wallet_change_in_our_registry_triggers_the_hold_and_A_B_A_does_not_reset() public {
        vm.startPrank(owner);
        reg.register(URI, acme);
        pr.confirmPayee(1, acme); pr.setSignedOnly(1, true);
        vm.stopPrank();
        assertTrue(exec(stageSigned(acmeKey, acme, "INV-1")));
        vm.expectEmit(true, true, true, true); emit VendorRegistry.AgentWalletSet(1, acme, acmeNew);   // audit trail of the change
        vm.prank(owner); reg.setAgentWallet(1, acmeNew);                               // A -> B
        uint256 held = stageSigned(malloryKey, acmeNew, "INV-2");
        assertFalse(exec(held), "new wallet held");
        assertEq(usd.balanceOf(acmeNew), 0);
        vm.prank(owner); reg.setAgentWallet(1, acme);                                  // B -> A
        uint256 back = stageSigned(acmeKey, acme, "INV-3");
        assertFalse(exec(back), "A -> B -> A: the old wallet is not trusted again");
        (, , uint8 why, ) = pr.canExecute(back);
        assertEq(why, 1);
        vm.prank(owner); pr.confirmPayee(1, acme);                                    // only the owner's re-confirmation releases it
        assertTrue(exec(back));
        assertEq(usd.balanceOf(acme), 20 * USD);
    }

    function test_suspended_vendor_is_refused() public {
        vm.startPrank(owner); reg.register(URI, acme); pr.confirmPayee(1, acme); reg.setAgentWallet(1, address(0)); vm.stopPrank();
        PayRunV3.Line[] memory l = line(acme, "INV-9");
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRunV3.PayeeNotRegistered.selector, 0, 1, acme, address(0)));
        pr.stage(l);
    }
}
