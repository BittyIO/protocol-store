// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployProtocols} from "./DeployProtocols.sol";

/**
 * @title DeployRobinhood
 * @notice Robinhood Chain (Arbitrum Orbit L2, id 4663).
 *
 * @dev Uniswap is the chain's public AMM from day one, and UniswapX (V3 Dutch reactor) its intent
 *      layer. There is no Aave (Morpho is the lending venue, and no adapter exists for it yet), no CoW
 *      settlement (the deterministic address holds no code), and neither Lido nor Sky. Add the others
 *      as adapters and venues appear.
 *
 *      Run:  forge script script/DeployRobinhood.s.sol:DeployRobinhood --rpc-url robinhood --broadcast -vvvv
 */
contract DeployRobinhood is DeployProtocols {
    function deploy() public override {
        _deployUniswapUniversal();
        _deployUniswapX();
    }
}
