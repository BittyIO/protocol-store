// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {AaveV3Provider} from "provider-contracts/src/providers/AaveV3Provider.sol";

contract AaveV3ProviderScript is DeployScript {
    function deploy() public override {
        AaveV3Provider aaveProvider = new AaveV3Provider(getAddress("AAVE_V3"), getAddress("POOL_DATA_PROVIDER"));
        console2.log("AaveProvider deployed at", address(aaveProvider));
        saveAddress("AAVE_V3_PROVIDER", address(aaveProvider));
    }
}
