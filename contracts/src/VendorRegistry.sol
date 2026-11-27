// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentIdentity} from "./PayRun.sol";

/// @title VendorRegistry: the payer's own vendor directory, with the ERC-8004 read interface Clerk uses.
/// @notice The Aevum Starter Kit asks challenge builders to "keep the name-to-address mapping in your own contract" while QDay's
/// ERC-8004 registry is in internal testing. This is that contract: the payer's vendor master file on chain.
///   - Read side = ERC-8004 identity: `getAgentWallet(agentId)` (what PayRun / PayRunV2 / PayRunV3 check at staging and at
///     payment) and `tokenURI(agentId)` (a registration file whose "name" stage.py reads). So a PayRun can be pointed at QDay's
///     registry instead, unchanged, the day it opens.
///   - Write side = owner-curated: only the owner (the payer's smart account, or an admin key it designates) registers a vendor,
///     changes its payout wallet or its registration file. Every change is an event, so the vendor master file has an audit trail.
///   - Payee-change semantics are the ones PayRunV2/V3's hold relies on: a wallet change shows up in `getAgentWallet` at once;
///     the PayRun sees it at the next staging or execution, withdraws trust and starts the hold. Changing back (A -> B -> A)
///     is just another change. Setting the wallet to zero suspends the vendor (every PayRun refuses a zero payee).
///   - agentIds start at 1 and are never reused.
contract VendorRegistry is IAgentIdentity {
    uint256 public constant MAX_URI = 4096;

    address public owner;
    uint256 public count;                         // agentIds 1..count exist
    mapping(uint256 => address) internal _wallet;
    mapping(uint256 => string) internal _uri;

    event OwnerChanged(address indexed previous, address indexed next);
    event Registered(uint256 indexed agentId, address indexed wallet, string agentURI);
    event AgentWalletSet(uint256 indexed agentId, address indexed from, address indexed to);
    event AgentURISet(uint256 indexed agentId, string agentURI);

    error NotOwner();
    error UnknownAgent(uint256 agentId);
    error ZeroAddress();
    error BadURI();
    error SameWallet(uint256 agentId, address wallet);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnerChanged(address(0), owner_);
    }

    function setOwner(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit OwnerChanged(owner, next);
        owner = next;
    }

    /// @notice Add a vendor: its registration file (ERC-8004 style, e.g. data:application/json;base64,{"name":...}) and payout wallet.
    function register(string calldata agentURI, address wallet) external onlyOwner returns (uint256 agentId) {
        if (wallet == address(0)) revert ZeroAddress();
        _checkURI(agentURI);
        agentId = ++count;
        _wallet[agentId] = wallet;
        _uri[agentId] = agentURI;
        emit Registered(agentId, wallet, agentURI);
        emit AgentWalletSet(agentId, address(0), wallet);
    }

    /// @notice Change a vendor's payout wallet (zero = suspend). Every PayRun treats it as a payee change (hold).
    function setAgentWallet(uint256 agentId, address wallet) external onlyOwner {
        _known(agentId);
        address from = _wallet[agentId];
        if (from == wallet) revert SameWallet(agentId, wallet);
        _wallet[agentId] = wallet;
        emit AgentWalletSet(agentId, from, wallet);
    }

    function setAgentURI(uint256 agentId, string calldata agentURI) external onlyOwner {
        _known(agentId);
        _checkURI(agentURI);
        _uri[agentId] = agentURI;
        emit AgentURISet(agentId, agentURI);
    }

    /// @notice ERC-8004 read: the vendor's registered payout wallet (zero for an unknown or suspended vendor).
    function getAgentWallet(uint256 agentId) external view returns (address) {
        return _wallet[agentId];
    }

    /// @notice ERC-8004 / ERC-721 style registration file. Reverts for an unknown agentId, like an ERC-721 tokenURI.
    function tokenURI(uint256 agentId) external view returns (string memory) {
        _known(agentId);
        return _uri[agentId];
    }

    function _known(uint256 agentId) internal view {
        if (agentId == 0 || agentId > count) revert UnknownAgent(agentId);
    }

    function _checkURI(string calldata u) internal pure {
        if (bytes(u).length == 0 || bytes(u).length > MAX_URI) revert BadURI();
    }
}
