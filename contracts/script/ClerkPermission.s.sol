// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PayRunV2, IERC20, IAgentIdentity} from "../src/PayRunV2.sol";
import {ClerkStagePolicy, PackedUserOperation} from "../src/ClerkStagePolicy.sol";

/// The clerk's session key as a Kernel v3.1 permission inside the owner's smart account, on Aevum TESTNET (chain 44005).
/// Testnet only; keys come from env (TESTNET-ONLY keys, never printed). The owner EOA submits handleOps itself (self-bundled).
///
///   dry run on a fork with a fresh account (no keys, nothing sent):
///     forge script script/ClerkPermission.s.sol --sig "dryRun()" --fork-url https://rpc-test.qday.info
///   1) deploy the policy + make the account its own PayRunV2 staging session + the clerk's first UserOperation (enable + stage):
///     ACCOUNT=0x.. PAYRUN=0x.. VENDOR_ID=1698 AMOUNT=100000 OWNER_PK=.. CLERK_PK=.. \
///       forge script script/ClerkPermission.s.sol --sig "setUpAndStage()" --rpc-url https://rpc-test.qday.info --broadcast --legacy
///   2) prove the refusals against live testnet state (simulation only, nothing sent):
///     ACCOUNT=.. PAYRUN=.. POLICY=.. VENDOR_ID=.. OWNER_PK=.. CLERK_PK=.. forge script ... --sig "checkRefusals()" --rpc-url ...
///   3) revoke (owner UserOperation), then checkRefusals() again shows the stage refused too:
///     ... --sig "revoke()" --rpc-url ... --broadcast --legacy
contract ClerkPermission is Script {
    IAgentIdentity constant REG = IAgentIdentity(0xF45E7f39Caba1d2055f613970575a7e7069636Be);
    IERC20 constant TUSD8 = IERC20(0x456569838f1d43009A91ebA4263147Afd7233483);
    IEP constant EP = IEP(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
    IFactory constant FACTORY = IFactory(0xaac5D4240AF87249B3f71BC8E4A2cae074A3E419);
    address constant ECDSA_VALIDATOR = 0x845ADb2C711129d4f3966735eD98a9F09fC4cE57;
    address constant ECDSA_SIGNER = 0x6A6F069E2a08c2468e7724Ab3250CdBFBA14D4FF;
    bytes32 constant ENABLE_TYPE_HASH = 0xb17ab1224aca0d4255ef8161acaf2ac121b8faa32a4b2258c912cc5f8308c505;
    bytes4 constant EXECUTE = 0xe9ae5c53;
    bytes4 constant PID = 0xc1e4c001;
    uint128 constant RUN_CAP = 500_000;   // 0.50 tUSD8 per run, in the policy and in PayRun's session
    uint128 constant DAY_CAP = 1_000_000; // 1.00 tUSD8 per day, PayRun's session
    uint128 constant MAX_FEE = 5 gwei;          // highest maxFeePerGas the clerk may sign
    uint128 constant GAS_BUDGET = 0.05 ether;   // worst-case wei the clerk's UserOperations may cost the account, in total

    uint256 ownerPk;
    uint256 clerkPk;
    address account;
    PayRunV2 pr;
    ClerkStagePolicy policy;
    uint256 vendorId;
    uint48 until;

    // ------------------------------------------------------------------ entry points

    function dryRun() external {
        require(block.chainid == 44005, "fork Aevum testnet");
        ownerPk = uint256(keccak256("dry owner"));
        clerkPk = uint256(keccak256("dry clerk"));
        account = FACTORY.createAccount(abi.encodeWithSelector(IK.initialize.selector,
            bytes21(abi.encodePacked(bytes1(0x01), ECDSA_VALIDATOR)), address(0), abi.encodePacked(vm.addr(ownerPk)), bytes(""),
            new bytes[](0)), bytes32(uint256(77)));
        vm.deal(account, 1 ether);
        vm.deal(vm.addr(ownerPk), 1 ether);
        pr = new PayRunV2(TUSD8, REG, account, account);
        vendorId = 1;
        vm.startPrank(vm.addr(ownerPk), vm.addr(ownerPk));
        _setUp(false);
        _send(_enableAndStageOp(100_000, keccak256(abi.encode("dry", block.timestamp))));
        (, address by,, uint128 total,) = pr.runs(pr.runCount());
        console2.log("staged run", pr.runCount(), total);
        console2.log("staged by (the account)", by);
        _refusals(true);
        _send(_rootOp(_uninstallCall()));
        console2.log("after revoke:");
        _refusals(false);
        vm.stopPrank();
    }

    function setUpAndStage() external {
        _env();
        _setUp(true);
        vm.startBroadcast(ownerPk);
        _send(_enableAndStageOp(uint128(vm.envUint("AMOUNT")), keccak256(abi.encode("clerk-permission", block.timestamp))));
        vm.stopBroadcast();
        console2.log("policy", address(policy));
        console2.log("staged run", pr.runCount());
    }

    function checkRefusals() external {
        _env();
        policy = ClerkStagePolicy(vm.envAddress("POLICY"));
        _refusals(vm.envOr("REVOKED", uint256(0)) == 0);
    }

    function revoke() external {
        _env();
        vm.startBroadcast(ownerPk);
        _send(_rootOp(_uninstallCall()));
        vm.stopBroadcast();
    }

    // ------------------------------------------------------------------ steps

    function _env() internal {
        require(block.chainid == 44005, "Aevum testnet only");
        ownerPk = vm.envUint("OWNER_PK");
        clerkPk = vm.envUint("CLERK_PK");
        account = vm.envAddress("ACCOUNT");
        pr = PayRunV2(vm.envAddress("PAYRUN"));
        vendorId = vm.envUint("VENDOR_ID");
        require(pr.owner() == account, "PAYRUN's owner is not ACCOUNT");
    }

    /// Deploy the policy and make the account its own staging session on PayRunV2 (owner UserOperation, root key).
    function _setUp(bool broadcast) internal {
        until = uint48(block.timestamp + 7 days);
        if (broadcast) vm.startBroadcast(ownerPk);
        policy = new ClerkStagePolicy();
        _send(_rootOp(abi.encodeWithSelector(IK.execute.selector, bytes32(0), abi.encodePacked(address(pr), uint256(0),
            abi.encodeWithSelector(PayRunV2.grantSession.selector, account, uint64(until), RUN_CAP, DAY_CAP)))));
        if (broadcast) vm.stopBroadcast();
    }

    function _refusals(bool stageAllowed) internal {
        _expectRefused("clerk asks the account to execute (pay) run 1",
            _clerkOp(abi.encodeWithSelector(IK.execute.selector, bytes32(0), abi.encodePacked(address(pr), uint256(0),
                abi.encodeWithSelector(PayRunV2.execute.selector, uint256(1))))));
        _expectRefused("clerk asks the account to transfer 1 tUSD8 to itself",
            _clerkOp(abi.encodeWithSelector(IK.execute.selector, bytes32(0), abi.encodePacked(address(TUSD8), uint256(0),
                abi.encodeWithSignature("transfer(address,uint256)", vm.addr(clerkPk), uint256(1e6))))));
        _expectRefused("clerk stages over the per-run cap", _clerkOp(_stageCall(RUN_CAP + 1, keccak256("over cap"))));
        PackedUserOperation memory drain = _base(_stageCall(50_000, keccak256("drain")), EP.getNonce(account, _permKey(0x00)));
        drain.preVerificationGas = 9_000_000;
        drain.gasFees = bytes32((uint256(MAX_FEE) << 128) | MAX_FEE);
        drain.signature = abi.encodePacked(bytes1(0xff), _ethSign(clerkPk, EP.getUserOpHash(drain)));
        _expectRefused("clerk signs a stage with 9M preVerificationGas at the max fee (gas drain)", drain);
        string memory probe = "clerk stages 0.05 tUSD8 within the caps";
        PackedUserOperation memory ok = _clerkOp(_stageCall(50_000, keccak256(abi.encode("probe", block.timestamp))));
        if (stageAllowed) {
            (bool passed, bytes memory err) = _simulate(ok);
            if (!passed) { console2.logBytes(err); revert(string.concat("REFUSED but should pass: ", probe)); }
            console2.log(string.concat("ALLOWED (simulation, nothing sent): ", probe));
        } else {
            _expectRefused(probe, ok);
        }
    }

    Simulator sim;

    /// Runs the UserOperation through the EntryPoint in this script's local simulation (never broadcast). Returns the revert data.
    function _simulate(PackedUserOperation memory op) internal returns (bool ok, bytes memory err) {
        if (address(sim) == address(0)) sim = new Simulator();
        return sim.run(EP, op, vm.addr(ownerPk));
    }

    function _expectRefused(string memory what, PackedUserOperation memory op) internal {
        (bool ok, bytes memory err) = _simulate(op);
        if (ok) revert(string.concat("NOT REFUSED: ", what));
        console2.log(string.concat("REFUSED at validation: ", what));
        console2.logBytes(err);
    }

    // ------------------------------------------------------------------ UserOperations

    function _ops(PackedUserOperation memory op) internal pure returns (PackedUserOperation[] memory ops) {
        ops = new PackedUserOperation[](1);
        ops[0] = op;
    }

    function _send(PackedUserOperation memory op) internal {
        EP.handleOps(_ops(op), payable(vm.addr(ownerPk)));
    }

    function _base(bytes memory callData, uint256 nonce) internal view returns (PackedUserOperation memory op) {
        op.sender = account;
        op.nonce = nonce;
        op.callData = callData;
        op.accountGasLimits = bytes32((uint256(1_500_000) << 128) | 1_500_000);
        op.preVerificationGas = 80_000;
        op.gasFees = bytes32((uint256(2 gwei) << 128) | 2 gwei);
    }

    function _ethSign(uint256 pk, bytes32 h) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h)));
        return abi.encodePacked(r, s, v);
    }

    function _rootOp(bytes memory callData) internal view returns (PackedUserOperation memory op) {
        op = _base(callData, EP.getNonce(account, 0));
        op.signature = _ethSign(ownerPk, EP.getUserOpHash(op));
    }

    function _permKey(bytes1 mode) internal pure returns (uint192) {
        return uint192((uint256(uint8(mode)) << 184) | (uint256(2) << 176) | (uint256(uint32(PID)) << 144));
    }

    function _stageCall(uint128 amount, bytes32 inv) internal view returns (bytes memory) {
        PayRunV2.Line[] memory ls = new PayRunV2.Line[](1);
        ls[0] = PayRunV2.Line({payeeAgentId: vendorId, payee: REG.getAgentWallet(vendorId), amount: amount, invoiceHash: inv,
            invoiceRef: bytes32("CLERK-PERM")});
        return abi.encodeWithSelector(IK.execute.selector, bytes32(0), abi.encodePacked(address(pr), uint256(0),
            abi.encodeWithSelector(PayRunV2.stage.selector, ls)));
    }

    function _permissionData() internal view returns (bytes memory) {
        bytes[] memory entries = new bytes[](2);
        entries[0] = abi.encodePacked(bytes2(0), address(policy), abi.encode(address(pr), RUN_CAP, until, MAX_FEE, GAS_BUDGET));
        entries[1] = abi.encodePacked(bytes2(0), ECDSA_SIGNER, vm.addr(clerkPk));
        return abi.encode(entries);
    }

    function _domainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version,,,,) = IK(account).eip712Domain();
        return keccak256(abi.encode(keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)), keccak256(bytes(version)), block.chainid, account));
    }

    function _enableSig(bytes memory validatorData, bytes memory selectorData) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(ENABLE_TYPE_HASH, bytes21(abi.encodePacked(bytes1(0x02), PID, bytes16(0))),
            IK(account).currentNonce(), address(1), keccak256(validatorData), keccak256(""), keccak256(selectorData)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash)));
        return abi.encodePacked(r, s, v);
    }

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

    function _uninstallCall() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IK.uninstallValidation.selector, bytes21(abi.encodePacked(bytes1(0x02), PID, bytes16(0))),
            abi.encode(new bytes[](2)), bytes(""));
    }
}

/// Local simulation helper (deployed only in a script simulation; the refusal checks are never broadcast).
contract Simulator {
    function run(IEP ep, PackedUserOperation memory op, address beneficiary) external returns (bool ok, bytes memory err) {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        try ep.handleOps(ops, payable(beneficiary)) { ok = true; } catch (bytes memory e) { err = e; }
    }
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
