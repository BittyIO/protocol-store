// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {UniswapUniversalTradeProtocol} from "./UniswapUniversalTradeProtocol.sol";

/**
 * @title PancakeSwapUniversalTradeProtocol
 * @notice Market trades through PancakeSwap's Infinity Universal Router: v2, v3, StableSwap and Infinity
 *         (CL and Bin) pools, and routes that split across them.
 *
 * @dev The router is a fork of Uniswap's: the same `execute(commands, inputs, deadline)` entry point, the
 *      same Permit2 pull (PancakeSwap runs its own Permit2 deployment) and the same command numbering for
 *      v2 and v3. The trade adapter never looks inside a route, so its code serves this router unchanged —
 *      fee model, minimum-output check, refunds and Permit2 hygiene included. Routes are the quoting
 *      service's to build for PancakeSwap's pools.
 *
 *      What differs is the LINEAGE. A vault keeps one clone per lineage, so a PancakeSwap adapter sharing
 *      Uniswap's would be the same clone as a Uniswap one, and an upgrade could move a vault between
 *      venues. Its version follows the shared trade code.
 */
contract PancakeSwapUniversalTradeProtocol is UniswapUniversalTradeProtocol {
    constructor(address universalRouter_, address permit2_, address bittyGuard_)
        UniswapUniversalTradeProtocol(universalRouter_, permit2_, bittyGuard_)
    {}

    function protocolLineage() external pure override returns (bytes32) {
        return keccak256("bitty.adapter.pancakeswap.universal");
    }
}
