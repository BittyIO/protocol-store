// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployProtocols} from "./DeployProtocols.sol";

contract DeployBase is DeployProtocols {
    function deploy() public override {
        _deployAave();
        _deployUniswap();
        _deployCoWSwap();
        _deploySkyEvm();
    }
}
