// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentIdentity} from "../../src/PayRun.sol";

/// Local-chain stand-in for the ERC-8004 identity registry, used only by e2e/adversarial (the eval).
/// Like the real registry it serves a registration file (tokenURI, inline JSON with a "name") and a wallet per agentId,
/// so agent/stage.py's load_directory reads it unchanged. Anyone can register here, as on the real registry: that is how
/// the eval's attacker gets look-alike identities ("Acme Suppiles Ltd") with its own wallet.
contract EvalRegistry is IAgentIdentity {
    mapping(uint256 => address) public w;
    mapping(uint256 => string) public names;
    function set(uint256 id, address a, string calldata name) external { w[id] = a; names[id] = name; }
    function setWallet(uint256 id, address a) external { w[id] = a; }
    function getAgentWallet(uint256 id) external view returns (address) { return w[id]; }
    function tokenURI(uint256 id) external view returns (string memory) {
        return string.concat('data:application/json,{"name":"', names[id], '"}');
    }
}
