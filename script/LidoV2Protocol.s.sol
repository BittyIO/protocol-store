// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {LidoV2Protocol} from "protocol-contracts/src/protocols/LidoV2Protocol.sol";

contract LidoV2ProtocolScript is DeployScript {
    function deploy() public override {
        LidoV2Protocol lidoProtocol = new LidoV2Protocol(getAddress("STETH"), getAddress("UNSTETH"), getAddress("WETH"));
        console2.log("LidoProtocol deployed at", address(lidoProtocol));
        saveAddress("LIDO_V2_PROTOCOL", address(lidoProtocol));
    }
}
