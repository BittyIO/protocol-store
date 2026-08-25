// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployProtocols} from "./DeployProtocols.sol";

/// @notice Every adapter, in one run. Mainnet is the only chain that supports all five.
contract DeployMainnet is DeployProtocols {
    function deploy() public override {
        _deployAave();
        _deployUniswap();
        _deployCoWSwap();
        _deployLido();
        _deploySky();
    }
}
