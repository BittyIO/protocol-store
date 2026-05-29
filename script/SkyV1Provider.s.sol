// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {SkyV1Provider} from "provider-contracts/src/providers/SkyV1Provider.sol";

contract SkyV1ProviderScript is DeployScript {
    function deploy() public override {
        SkyV1Provider skyProvider = new SkyV1Provider(
            getAddress("USDC"),
            getAddress("USDS"),
            getAddress("S_USDS"),
            getAddress("SKY_PSM")
        );
        console2.log("SkyV1Provider deployed at", address(skyProvider));
        saveAddress("SKY_V1_PROVIDER", address(skyProvider));
    }
}
