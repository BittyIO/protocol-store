// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {UniswapV3Protocol} from "protocol-contracts/src/protocols/UniswapV3Protocol.sol";

contract UniswapV3ProtocolScript is DeployScript {
    function deploy() public override {
        UniswapV3Protocol uniswapV3Protocol = new UniswapV3Protocol(
            getAddress("UNISWAP_V3_ROUTER"), getAddress("UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER")
        );
        console2.log("UniswapV3Protocol deployed at", address(uniswapV3Protocol));
        saveAddress("UNISWAP_V3_PROTOCOL", address(uniswapV3Protocol));
    }
}
