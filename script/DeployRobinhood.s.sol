// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployProtocols} from "./DeployProtocols.sol";

/**
 * @title DeployRobinhood
 * @notice Robinhood Chain (Arbitrum Orbit L2, id 4663).
 *
 * @dev Uniswap is the chain's public AMM, and the only venue here. There is no intent protocol: CoW
 *      has no settlement on this chain (the deterministic address holds no code), and UniswapX was
 *      withdrawn — its orders fill at the signed price, so they need an oracle floor, and the tokens it
 *      was meant for are the ones with no Chainlink feed here. There is no Aave either (Morpho is the
 *      lending venue, and no adapter exists for it yet), nor Lido or Sky. Add the others as adapters
 *      and venues appear.
 *
 *      Run:  forge script script/DeployRobinhood.s.sol:DeployRobinhood --rpc-url robinhood --broadcast -vvvv
 */
contract DeployRobinhood is DeployProtocols {
    function deploy() public override {
        _deployUniswapUniversal();
    }
}
