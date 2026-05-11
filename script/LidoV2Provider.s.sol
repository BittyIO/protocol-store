// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {LidoV2Provider} from "provider-contracts/src/providers/LidoV2Provider.sol";

contract LidoV2ProviderScript is DeployScript {
    function deploy() public override {
        LidoV2Provider lidoProvider = new LidoV2Provider(getAddress("STETH"), getAddress("UNSTETH"), getAddress("WETH"));
        console2.log("LidoProvider deployed at", address(lidoProvider));
        saveAddress("LIDO_V2_PROVIDER", address(lidoProvider));
    }
}
