// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PayRunV3} from "../src/PayRunV3.sol";
import {MockUSD, MockRegistry} from "./PayRun.t.sol";

/// A vendor wallet that is a smart account: accepts a digest signed by its owner key (ERC-1271).
contract Mock1271Wallet {
    address public immutable signer;
    constructor(address s) { signer = s; }
    function isValidSignature(bytes32 digest, bytes calldata sig) external view returns (bytes4) {
        if (sig.length != 65) return 0xffffffff;
        (bytes32 r, bytes32 s, uint8 v) = (bytes32(sig[0:32]), bytes32(sig[32:64]), uint8(sig[64]));
        return ecrecover(digest, v, r, s) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// Vendor-signed invoices: for a signedOnly vendor, only a line signed by its registered wallet over exactly these values
/// is staged. Every attack below is also run with the check OFF (planted control) to show it would have been staged and paid.
contract PayRunV3Test is Test {
    MockUSD usd; MockRegistry reg; PayRunV3 pr;
    address owner = makeAddr("owner"); address treasury = makeAddr("treasury"); address clerk = makeAddr("clerk");
    uint256 acmeKey = 0xA11CE; uint256 globexKey = 0xB0B; uint256 malloryKey = 0xBAD;
    address acme; address globex; address mallory;
    uint256 constant ACME = 7; uint256 constant GLOBEX = 9;
    uint128 constant USD = 1e6;
    uint32 constant DUE = 20261215;

    function setUp() public {
        vm.warp(1_763_400_000);
        acme = vm.addr(acmeKey); globex = vm.addr(globexKey); mallory = vm.addr(malloryKey);
        usd = new MockUSD(); reg = new MockRegistry();
        pr = new PayRunV3(usd, reg, owner, treasury);
        reg.set(ACME, acme); reg.set(GLOBEX, globex);
        usd.mint(treasury, 1_000_000 * USD);
        vm.prank(treasury); usd.approve(address(pr), type(uint256).max);
        vm.startPrank(owner);
        pr.grantSession(clerk, uint64(block.timestamp + 30 days), 500 * USD, 100_000 * USD);
        pr.confirmPayee(ACME, acme); pr.confirmPayee(GLOBEX, globex);
        pr.setSignedOnly(ACME, true); pr.setSignedOnly(GLOBEX, true);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ helpers

    function line(uint256 id, address payee, uint128 amt, string memory inv) internal pure returns (PayRunV3.Line memory) {
        return PayRunV3.Line({payeeAgentId: id, payee: payee, amount: amt, invoiceHash: keccak256(bytes(inv)), invoiceRef: bytes32(bytes(inv))});
    }
    /// The vendor's own signature, as its invoicing system would produce it (struct hash per EIP-712, computed here independently).
    function sign(uint256 key, PayRunV3.Line memory l, uint32 due) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Invoice(uint256 payeeAgentId,address payee,uint128 amount,bytes32 invoiceHash,uint32 dueDate)"),
            l.payeeAgentId, l.payee, l.amount, l.invoiceHash, due));
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Clerk PayRun"), keccak256("3"), block.chainid, address(pr)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }
    function one(PayRunV3.Line memory l) internal pure returns (PayRunV3.Line[] memory a) { a = new PayRunV3.Line[](1); a[0] = l; }
    function proof(uint32 due, bytes memory sig) internal pure returns (PayRunV3.Proof[] memory p) {
        p = new PayRunV3.Proof[](1); p[0] = PayRunV3.Proof({dueDate: due, signature: sig});
    }
    function stageSigned(PayRunV3.Line memory l, uint32 due, bytes memory sig) internal returns (uint256 id) {
        vm.prank(clerk); id = pr.stageSigned(one(l), proof(due, sig));
    }
    function exec(uint256 id) internal returns (bool ok) { vm.prank(owner); ok = pr.execute(id); }
    function expectBadSig(PayRunV3.Line memory l, uint32 due, bytes memory sig) internal {
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRunV3.BadVendorSignature.selector, 0, l.payeeAgentId, l.payee));
        pr.stageSigned(one(l), proof(due, sig));
    }
    /// Planted control: the same line with the vendor's setting OFF and no signature is staged and paid.
    function controlPays(PayRunV3.Line memory l) internal {
        vm.prank(owner); pr.setSignedOnly(l.payeeAgentId, false);
        vm.prank(clerk); uint256 id = pr.stage(one(l));
        uint256 before = usd.balanceOf(l.payee);
        assertTrue(exec(id), "control: with the check off the attack pays");
        assertEq(usd.balanceOf(l.payee) - before, l.amount);
        vm.prank(owner); pr.setSignedOnly(l.payeeAgentId, true);
    }

    // ------------------------------------------------------------ the genuine path

    function test_signed_invoice_is_staged_and_paid() public {
        PayRunV3.Line memory l = line(ACME, acme, 120 * USD, "INV-1001");
        bytes memory sig = sign(acmeKey, l, DUE);
        vm.expectEmit(true, true, true, true); emit PayRunV3.InvoiceSigned(1, 0, ACME, acme, DUE);
        uint256 id = stageSigned(l, DUE, sig);
        assertTrue(exec(id));
        assertEq(usd.balanceOf(acme), 120 * USD);
        (bool req, bool valid) = pr.checkInvoice(l, PayRunV3.Proof({dueDate: DUE, signature: sig}));
        assertTrue(req); assertTrue(valid);
    }

    function test_multi_line_run_each_line_its_own_vendor_signature() public {
        PayRunV3.Line[] memory ls = new PayRunV3.Line[](2);
        ls[0] = line(ACME, acme, 100 * USD, "INV-1"); ls[1] = line(GLOBEX, globex, 50 * USD, "G-1");
        PayRunV3.Proof[] memory ps = new PayRunV3.Proof[](2);
        ps[0] = PayRunV3.Proof(DUE, sign(acmeKey, ls[0], DUE)); ps[1] = PayRunV3.Proof(DUE, sign(globexKey, ls[1], DUE));
        vm.prank(clerk); uint256 id = pr.stageSigned(ls, ps);
        assertTrue(exec(id));
        // swap the two signatures: each line is checked against its own vendor's wallet
        ls[0].invoiceHash = keccak256("INV-2"); ls[1].invoiceHash = keccak256("G-2");
        (ps[0], ps[1]) = (PayRunV3.Proof(DUE, sign(globexKey, ls[1], DUE)), PayRunV3.Proof(DUE, sign(acmeKey, ls[0], DUE)));
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRunV3.BadVendorSignature.selector, 0, ACME, acme));
        pr.stageSigned(ls, ps);
    }

    function test_unsigned_vendor_still_works_both_paths() public {
        vm.prank(owner); pr.setSignedOnly(ACME, false);
        vm.prank(clerk); uint256 a = pr.stage(one(line(ACME, acme, 10 * USD, "U-1")));
        vm.prank(clerk); uint256 b = pr.stageSigned(one(line(ACME, acme, 10 * USD, "U-2")), proof(0, ""));
        assertTrue(exec(a)); assertTrue(exec(b));
        // ...but a signature that IS attached must verify, whatever the setting
        expectBadSig(line(ACME, acme, 10 * USD, "U-3"), DUE, sign(malloryKey, line(ACME, acme, 10 * USD, "U-3"), DUE));
    }

    // ------------------------------------------------------------ the three families that were stopped off chain only

    /// model_edit: the extractor changes the amount, the invoice number, the due date or the vendor of a genuine invoice.
    function test_model_edits_are_refused() public {
        PayRunV3.Line memory g = line(ACME, acme, 120 * USD, "INV-1001");
        bytes memory sig = sign(acmeKey, g, DUE);                     // what the vendor signed
        PayRunV3.Line memory x = line(ACME, acme, 210 * USD, "INV-1001");   // digits swapped / x10
        expectBadSig(x, DUE, sig);
        x = line(ACME, acme, 120 * USD, "INV-7777");                  // invoice number changed
        expectBadSig(x, DUE, sig);
        expectBadSig(g, DUE + 1, sig);                                // due date changed
        x = line(GLOBEX, globex, 120 * USD, "INV-1001");              // vendor changed to another registered vendor
        expectBadSig(x, DUE, sig);
        // plain stage without the signature: refused too
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRunV3.VendorSignatureRequired.selector, 0, ACME));
        pr.stage(one(line(ACME, acme, 210 * USD, "INV-1001")));
        // planted control: with the check off, the edited amount is staged and paid
        controlPays(line(ACME, acme, 210 * USD, "INV-1001"));
    }

    /// doc_amount_edit: the amount inside the document was edited; the vendor's signature covers the real amount.
    function test_document_amount_edit_is_refused() public {
        PayRunV3.Line memory real = line(GLOBEX, globex, 80 * USD, "G-4410");
        bytes memory sig = sign(globexKey, real, DUE);
        PayRunV3.Line memory edited = line(GLOBEX, globex, 192 * USD, "G-4410");
        expectBadSig(edited, DUE, sig);
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRunV3.VendorSignatureRequired.selector, 0, GLOBEX));
        pr.stageSigned(one(edited), proof(DUE, ""));                 // signature stripped
        (, bool valid) = pr.checkInvoice(real, PayRunV3.Proof(DUE, sig));
        assertTrue(valid, "the real amount verifies");
        controlPays(edited);
    }

    /// lookalike: an impersonator's invoice mapped onto the real vendor and its registered wallet; it can only sign with its own key.
    function test_lookalike_mapped_onto_real_vendor_is_refused() public {
        PayRunV3.Line memory l = line(ACME, acme, 300 * USD, "INV-9100");
        expectBadSig(l, DUE, sign(malloryKey, l, DUE));
        expectBadSig(l, DUE, sign(globexKey, l, DUE));                // another real vendor's key is not Acme's
        controlPays(l);
    }

    // ------------------------------------------------------------ signature hygiene

    function test_signature_is_bound_to_contract_and_chain() public {
        PayRunV3.Line memory l = line(ACME, acme, 10 * USD, "INV-1");
        PayRunV3 other = new PayRunV3(usd, reg, owner, treasury);
        bytes memory forOther;
        { PayRunV3 keep = pr; pr = other; forOther = sign(acmeKey, l, DUE); pr = keep; }
        expectBadSig(l, DUE, forOther);                               // signed for another payer's PayRun
        uint256 cid = block.chainid;
        vm.chainId(cid + 1);
        bytes memory otherChain = sign(acmeKey, l, DUE);
        vm.chainId(cid);
        expectBadSig(l, DUE, otherChain);
    }

    function test_malleable_and_malformed_signatures_refused() public {
        PayRunV3.Line memory l = line(ACME, acme, 10 * USD, "INV-1");
        bytes memory sig = sign(acmeKey, l, DUE);
        (bytes32 r, bytes32 s) = (bytes32(_slice(sig, 0)), bytes32(_slice(sig, 32)));
        uint8 v = uint8(sig[64]);
        uint256 n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        expectBadSig(l, DUE, abi.encodePacked(r, bytes32(n - uint256(s)), v == 27 ? uint8(28) : uint8(27)));   // high-s twin
        expectBadSig(l, DUE, abi.encodePacked(r, s, uint8(v - 27)));                                          // v 0/1
        expectBadSig(l, DUE, abi.encodePacked(r, s));                                                           // 64 bytes
        expectBadSig(l, DUE, new bytes(65));                                                                    // zeros
        vm.prank(clerk); vm.expectRevert(PayRunV3.BadLines.selector);
        pr.stageSigned(one(l), new PayRunV3.Proof[](0));                                                        // count mismatch
        stageSigned(l, DUE, sig);
    }

    function _slice(bytes memory b, uint256 off) internal pure returns (uint256 x) { assembly { x := mload(add(add(b, 32), off)) } }

    function test_pay_once_still_holds_for_signed_invoices() public {
        PayRunV3.Line memory l = line(ACME, acme, 10 * USD, "INV-1");
        bytes memory sig = sign(acmeKey, l, DUE);
        uint256 id = stageSigned(l, DUE, sig);
        assertTrue(exec(id));
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRunV3.AlreadyPaid.selector, 0, l.invoiceHash, id));
        pr.stageSigned(one(l), proof(DUE, sig));                     // replaying the vendor's signature
    }

    function test_only_owner_sets_signed_only() public {
        vm.prank(clerk); vm.expectRevert(PayRunV3.NotOwner.selector); pr.setSignedOnly(ACME, false);
        vm.expectEmit(true, true, true, true); emit PayRunV3.SignedOnlySet(ACME, false);
        vm.prank(owner); pr.setSignedOnly(ACME, false);
        assertFalse(pr.signedOnly(ACME));
    }

    // ------------------------------------------------------------ with the payee-change hold

    /// A hijacked registry entry signs with the attacker's new wallet: the signature is valid, the hold still blocks payment.
    function test_hijacked_identity_signs_but_hold_blocks() public {
        reg.set(ACME, mallory);
        PayRunV3.Line memory l = line(ACME, mallory, 50 * USD, "INV-HIJACK");
        uint256 id = stageSigned(l, DUE, sign(malloryKey, l, DUE));
        assertFalse(exec(id));
        assertEq(usd.balanceOf(mallory), 0);
        // Acme's old-wallet signature for a line to its old wallet: the payee no longer matches the registry
        PayRunV3.Line memory old = line(ACME, acme, 50 * USD, "INV-OLD");
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRunV3.PayeeNotRegistered.selector, 0, ACME, acme, mallory));
        pr.stageSigned(one(old), proof(DUE, sign(acmeKey, old, DUE)));
    }

    // ------------------------------------------------------------ ERC-1271 vendor wallets

    function test_smart_account_vendor_signs_via_erc1271() public {
        Mock1271Wallet w = new Mock1271Wallet(vm.addr(0xC0FFEE));
        uint256 INITECH = 11;
        reg.set(INITECH, address(w));
        vm.startPrank(owner); pr.confirmPayee(INITECH, address(w)); pr.setSignedOnly(INITECH, true); vm.stopPrank();
        PayRunV3.Line memory l = line(INITECH, address(w), 40 * USD, "IT-1");
        assertTrue(exec(stageSigned(l, DUE, sign(0xC0FFEE, l, DUE))));
        assertEq(usd.balanceOf(address(w)), 40 * USD);
        PayRunV3.Line memory l2 = line(INITECH, address(w), 40 * USD, "IT-2");
        expectBadSig(l2, DUE, sign(malloryKey, l2, DUE));
    }

    // ------------------------------------------------------------ fuzz: any change to a signed value is refused

    function testFuzz_any_altered_value_is_refused(uint128 amt, bytes32 h, uint32 due, uint8 which, uint128 delta) public {
        amt = uint128(bound(amt, 1, 400 * USD));
        delta = uint128(bound(delta, 1, 100 * USD));
        PayRunV3.Line memory g = PayRunV3.Line({payeeAgentId: ACME, payee: acme, amount: amt, invoiceHash: h, invoiceRef: bytes32("INV")});
        bytes memory sig = sign(acmeKey, g, due);
        PayRunV3.Line memory x = PayRunV3.Line({payeeAgentId: ACME, payee: acme, amount: amt, invoiceHash: h, invoiceRef: bytes32("INV")});
        uint32 xdue = due;
        which = which % 3;
        if (which == 0) x.amount = amt + delta;
        else if (which == 1) x.invoiceHash = bytes32(uint256(h) ^ uint256(delta));
        else xdue = due ^ uint32(delta | 1);
        expectBadSig(x, xdue, sig);
        assertTrue(exec(stageSigned(g, due, sig)));
    }
}
