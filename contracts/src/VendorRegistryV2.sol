// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentIdentity} from "./PayRun.sol";

/// @title VendorRegistryV2: VendorRegistry with a public timelock and a second party on every change that can redirect money.
/// @notice Same read side as VendorRegistry (ERC-8004 `getAgentWallet` + `tokenURI`), so PayRunV3 points at it unchanged.
/// What changes is the write side. In VendorRegistry the owner changes a vendor's payout wallet in one transaction; a stolen
/// owner key could therefore redirect a vendor at once (PayRunV3's payee-change hold and owner confirmation still stop the
/// payment, but the registry itself had no brake). Here:
///   - Any change that can point money at a new address is two-step: the owner PROPOSES it (a new vendor's wallet, a wallet
///     change, a new owner), it is public on chain at once (event + `pendingWallet`/`pendingOwner`), and it can only be
///     APPLIED after `delay` (fixed at deploy, 1 hour .. 7 days; Clerk deploys 48 hours). Anyone may apply it after that.
///   - A second key, the VERIFIER (e.g. the AP lead or an outside controller, never the owner), can CANCEL any pending
///     change during the delay. The owner can cancel its own proposals too. The verifier can only cancel or suspend: it can
///     never add a vendor, set a wallet or take ownership.
///   - Suspending a vendor (wallet -> zero) is the safe direction, so it is immediate, for the owner or the verifier, and it
///     also cancels that vendor's pending change. Reinstating it is a proposal like any other.
///   - The verifier role moves only by the verifier's own call (`setVerifier`), so a stolen owner key can't remove the check.
///   - A new vendor is registered with no wallet (it reads as zero, which every PayRun refuses) and a pending wallet.
/// After a change applies, PayRunV3 still treats it as a payee change: hold (up to 3 days) or the owner's confirmation.
/// `setAgentURI` (the vendor's name file) stays immediate and logged: it moves no money, and every name change shows up to
/// stage.py's look-alike check and on the approval page.
contract VendorRegistryV2 is IAgentIdentity {
    uint256 public constant MAX_URI = 4096;
    uint64 public constant MIN_DELAY = 1 hours;
    uint64 public constant MAX_DELAY = 7 days;

    struct Pending {
        address wallet;   // proposed payout wallet (non-zero)
        uint64 eta;       // earliest apply time; 0 = no pending change
    }

    uint64 public immutable delay;
    address public owner;
    address public verifier;
    uint256 public count;                          // agentIds 1..count exist
    mapping(uint256 => address) internal _wallet;
    mapping(uint256 => string) internal _uri;
    mapping(uint256 => Pending) public pendingWallet;
    address public pendingOwner;
    uint64 public pendingOwnerEta;

    event OwnerChanged(address indexed previous, address indexed next);
    event VerifierChanged(address indexed previous, address indexed next);
    event Registered(uint256 indexed agentId, string agentURI);
    event AgentWalletProposed(uint256 indexed agentId, address indexed from, address indexed to, uint64 eta);
    event AgentWalletProposalCancelled(uint256 indexed agentId, address indexed wallet, address indexed by);
    event AgentWalletSet(uint256 indexed agentId, address indexed from, address indexed to);
    event AgentURISet(uint256 indexed agentId, string agentURI);
    event OwnerProposed(address indexed next, uint64 eta);
    event OwnerProposalCancelled(address indexed next, address indexed by);

    error NotOwner();
    error NotOwnerOrVerifier();
    error NotVerifier();
    error UnknownAgent(uint256 agentId);
    error ZeroAddress();
    error BadURI();
    error BadDelay();
    error BadVerifier();
    error SameWallet(uint256 agentId, address wallet);
    error NothingPending();
    error TooEarly(uint64 eta);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOwnerOrVerifier() {
        if (msg.sender != owner && msg.sender != verifier) revert NotOwnerOrVerifier();
        _;
    }

    constructor(address owner_, address verifier_, uint64 delay_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (verifier_ == address(0) || verifier_ == owner_) revert BadVerifier();
        if (delay_ < MIN_DELAY || delay_ > MAX_DELAY) revert BadDelay();
        owner = owner_;
        verifier = verifier_;
        delay = delay_;
        emit OwnerChanged(address(0), owner_);
        emit VerifierChanged(address(0), verifier_);
    }

    // ---------------------------------------------------------------- vendors

    /// @notice Add a vendor with its registration file; its payout wallet is proposed and applies after `delay`.
    function register(string calldata agentURI, address wallet) external onlyOwner returns (uint256 agentId) {
        if (wallet == address(0)) revert ZeroAddress();
        _checkURI(agentURI);
        agentId = ++count;
        _uri[agentId] = agentURI;
        emit Registered(agentId, agentURI);
        _propose(agentId, wallet);
    }

    /// @notice Propose a new payout wallet for a vendor (replaces an earlier pending proposal and restarts the delay).
    function proposeAgentWallet(uint256 agentId, address wallet) external onlyOwner {
        _known(agentId);
        if (wallet == address(0)) revert ZeroAddress();           // suspending is `suspend`, immediate
        if (wallet == _wallet[agentId]) revert SameWallet(agentId, wallet);
        _propose(agentId, wallet);
    }

    /// @notice Apply a pending wallet once its delay has passed. Anyone may call it.
    function applyAgentWallet(uint256 agentId) external {
        Pending memory p = pendingWallet[agentId];
        if (p.eta == 0) revert NothingPending();
        if (block.timestamp < p.eta) revert TooEarly(p.eta);
        delete pendingWallet[agentId];
        address from = _wallet[agentId];
        _wallet[agentId] = p.wallet;
        emit AgentWalletSet(agentId, from, p.wallet);
    }

    /// @notice Cancel a vendor's pending wallet change (owner or verifier).
    function cancelAgentWallet(uint256 agentId) external onlyOwnerOrVerifier {
        Pending memory p = pendingWallet[agentId];
        if (p.eta == 0) revert NothingPending();
        delete pendingWallet[agentId];
        emit AgentWalletProposalCancelled(agentId, p.wallet, msg.sender);
    }

    /// @notice Suspend a vendor now (wallet -> zero; every PayRun refuses a zero payee) and cancel any pending change.
    function suspend(uint256 agentId) external onlyOwnerOrVerifier {
        _known(agentId);
        Pending memory p = pendingWallet[agentId];
        if (p.eta != 0) {
            delete pendingWallet[agentId];
            emit AgentWalletProposalCancelled(agentId, p.wallet, msg.sender);
        }
        address from = _wallet[agentId];
        if (from != address(0)) {
            _wallet[agentId] = address(0);
            emit AgentWalletSet(agentId, from, address(0));
        }
    }

    function setAgentURI(uint256 agentId, string calldata agentURI) external onlyOwner {
        _known(agentId);
        _checkURI(agentURI);
        _uri[agentId] = agentURI;
        emit AgentURISet(agentId, agentURI);
    }

    // ---------------------------------------------------------------- roles

    function proposeOwner(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        if (next == verifier) revert BadVerifier();
        uint64 eta = uint64(block.timestamp) + delay;
        pendingOwner = next;
        pendingOwnerEta = eta;
        emit OwnerProposed(next, eta);
    }

    /// @notice The proposed owner accepts after the delay (so a typo'd address can never take over).
    function acceptOwner() external {
        address next = pendingOwner;
        if (next == address(0)) revert NothingPending();
        if (msg.sender != next) revert NotOwner();
        if (block.timestamp < pendingOwnerEta) revert TooEarly(pendingOwnerEta);
        if (next == verifier) revert BadVerifier();
        pendingOwner = address(0);
        pendingOwnerEta = 0;
        emit OwnerChanged(owner, next);
        owner = next;
    }

    function cancelOwner() external onlyOwnerOrVerifier {
        address next = pendingOwner;
        if (next == address(0)) revert NothingPending();
        pendingOwner = address(0);
        pendingOwnerEta = 0;
        emit OwnerProposalCancelled(next, msg.sender);
    }

    /// @notice Only the verifier hands its role on; the owner can't remove the second party.
    function setVerifier(address next) external {
        if (msg.sender != verifier) revert NotVerifier();
        if (next == address(0) || next == owner || next == pendingOwner) revert BadVerifier();
        emit VerifierChanged(verifier, next);
        verifier = next;
    }

    // ---------------------------------------------------------------- reads

    /// @notice ERC-8004 read: the vendor's registered payout wallet (zero for an unknown, suspended or not-yet-active vendor).
    function getAgentWallet(uint256 agentId) external view returns (address) {
        return _wallet[agentId];
    }

    /// @notice ERC-8004 / ERC-721 style registration file. Reverts for an unknown agentId, like an ERC-721 tokenURI.
    function tokenURI(uint256 agentId) external view returns (string memory) {
        _known(agentId);
        return _uri[agentId];
    }

    // ---------------------------------------------------------------- internals

    function _propose(uint256 agentId, address wallet) internal {
        uint64 eta = uint64(block.timestamp) + delay;
        pendingWallet[agentId] = Pending({wallet: wallet, eta: eta});
        emit AgentWalletProposed(agentId, _wallet[agentId], wallet, eta);
    }

    function _known(uint256 agentId) internal view {
        if (agentId == 0 || agentId > count) revert UnknownAgent(agentId);
    }

    function _checkURI(string calldata u) internal pure {
        if (bytes(u).length == 0 || bytes(u).length > MAX_URI) revert BadURI();
    }
}
