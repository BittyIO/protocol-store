// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {UniswapV3Provider} from "provider-contracts/src/providers/UniswapV3Provider.sol";

contract UniswapV3ProviderScript is DeployScript {
    function deploy() public override {
        UniswapV3Provider uniswapV3Provider = new UniswapV3Provider(
            getAddress("UNISWAP_V3_ROUTER"), getAddress("UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER")
        );
        console2.log("UniswapV3Provider deployed at", address(uniswapV3Provider));
        saveAddress("UNISWAP_V3_PROVIDER", address(uniswapV3Provider));
    }
}
