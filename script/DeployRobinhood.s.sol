// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployProtocols} from "./DeployProtocols.sol";

/**
 * @title DeployRobinhood
 * @notice Robinhood Chain (Arbitrum Orbit L2, id 4663).
 *
 * @dev Uniswap V3 is the chain's public AMM from day one and the only adapter with a venue here:
 *      there is no Aave (Morpho is the lending venue, and no adapter exists for it yet), no CoW
 *      settlement (the deterministic address holds no code; UniswapX is the intent layer there),
 *      and neither Lido nor Sky. Add the others as adapters and venues appear.
 *
 *      Run:  forge script script/DeployRobinhood.s.sol:DeployRobinhood --rpc-url robinhood --broadcast -vvvv
 */
contract DeployRobinhood is DeployProtocols {
    function deploy() public override {
        _deployUniswapUniversal();
        _deployUniswapV3Maker();
    }
}
