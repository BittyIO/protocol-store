// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {AaveV3Protocol} from "protocol-contracts/src/protocols/AaveV3Protocol.sol";

contract AaveV3ProtocolScript is DeployScript {
    function deploy() public override {
        AaveV3Protocol aaveProtocol = new AaveV3Protocol(getAddress("AAVE_V3"), getAddress("POOL_DATA_PROVIDER"));
        console2.log("AaveProtocol deployed at", address(aaveProtocol));
        saveAddress("AAVE_V3_PROTOCOL", address(aaveProtocol));
    }
}
