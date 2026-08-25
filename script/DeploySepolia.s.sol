// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployProtocols} from "./DeployProtocols.sol";

/**
 * @notice Every adapter Sepolia supports, in one run.
 * @dev No Sky: there is no testnet USDS/sUSDS/PSM deployment to point an adapter at, which is why
 *      the chain TOML carries none of those keys.
 */
contract DeploySepolia is DeployProtocols {
    function deploy() public override {
        _deployAave();
        _deployUniswap();
        _deployCoWSwap();
        _deployLido();
    }
}
