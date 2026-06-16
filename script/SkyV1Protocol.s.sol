// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {SkyV1Protocol} from "protocol-contracts/src/protocols/SkyV1Protocol.sol";

contract SkyV1ProtocolScript is DeployScript {
    function deploy() public override {
        SkyV1Protocol skyProtocol =
            new SkyV1Protocol(getAddress("USDC"), getAddress("USDS"), getAddress("S_USDS"), getAddress("SKY_PSM"));
        console2.log("SkyV1Protocol deployed at", address(skyProtocol));
        saveAddress("SKY_V1_PROTOCOL", address(skyProtocol));
    }
}
