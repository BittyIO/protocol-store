// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployProtocols} from "./DeployProtocols.sol";

contract DeployBaseSepolia is DeployProtocols {
    function deploy() public override {
        _deployAcrossBridge();
    }
}
