// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BittyV1ProtocolBase} from "../../src/BittyV1ProtocolBase.sol";

/**
 * @dev Adapters are reached through an ERC-1967 proxy in production and their implementations
 *      disable initializers, so tests must stand one up the same way rather than initializing an
 *      implementation directly.
 */
library TestProxy {
    function deploy(address implementation, address owner) internal returns (address) {
        return address(new ERC1967Proxy(implementation, abi.encodeCall(BittyV1ProtocolBase.initialize, (owner))));
    }
}
