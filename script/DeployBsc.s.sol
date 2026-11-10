// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployProtocols} from "./DeployProtocols.sol";

/**
 * @title DeployBsc
 * @notice BNB Smart Chain (id 56).
 *
 * @dev Aave V3 (the "Aave V3 BNB Market"), PancakeSwap through its Infinity Universal Router, and CoW
 *      Swap (settlement at its deterministic address; api.cow.fi serves BNB Chain). No Lido and no Sky:
 *      neither runs on BNB Chain.
 *
 *      PancakeSwap, not Uniswap, is the market-trade venue: it holds most of BSC's DEX liquidity, and
 *      Uniswap's BSC pools are too thin for the stable-coin pairs vaults sell into. CoW solvers still
 *      reach Uniswap's pools where they are the better fill.
 *
 *      Run:  forge script script/DeployBsc.s.sol:DeployBsc --rpc-url bsc --broadcast --verify -vvvv
 */
contract DeployBsc is DeployProtocols {
    function deploy() public override {
        _deployAave();
        _deployPancakeSwapUniversal();
        _deployCoWSwap();
    }
}
