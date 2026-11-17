// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PayRun, IERC20, IAgentIdentity} from "../../src/PayRun.sol";

/// Runs against a fork of Aevum testnet (chain 44005): `forge test --match-path test/fork/* --fork-url https://rpc-test.qday.info`.
/// Uses the REAL ERC-8004 identity registry and the REAL tUSD8; skipped without a fork.
contract RegistryForkTest is Test {
    IAgentIdentity constant REG = IAgentIdentity(0xF45E7f39Caba1d2055f613970575a7e7069636Be);
    IERC20 constant TUSD8 = IERC20(0x456569838f1d43009A91ebA4263147Afd7233483);

    function test_stage_checks_the_real_registry() public {
        if (block.chainid != 44005) { vm.skip(true); return; }
        address registered = REG.getAgentWallet(1);
        assertTrue(registered != address(0), "agent 1 has a wallet");
        address owner = makeAddr("owner"); address clerk = makeAddr("clerk");
        PayRun pr = new PayRun(TUSD8, REG, owner, owner);
        vm.prank(owner); pr.grantSession(clerk, uint64(block.timestamp + 1 days), 5e6, 5e6);
        PayRun.Line[] memory ls = new PayRun.Line[](1);
        ls[0] = PayRun.Line({payeeAgentId: 1, payee: makeAddr("impostor"), amount: 1e6, invoiceHash: keccak256("f1"), invoiceRef: bytes32("F-1")});
        vm.prank(clerk);
        vm.expectRevert(abi.encodeWithSelector(PayRun.PayeeNotRegistered.selector, 0, 1, makeAddr("impostor"), registered));
        pr.stage(ls);
        ls[0].payee = registered;
        vm.prank(clerk); pr.stage(ls);
    }
}
