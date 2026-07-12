// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {UniswapXV1Protocol} from "protocol-contracts/src/protocols/uniswapx/UniswapXV1Protocol.sol";

contract UniswapXV1ProtocolScript is DeployScript {
    function deploy() public override {
        UniswapXV1Protocol uniswapXProtocol =
            new UniswapXV1Protocol(getAddress("PERMIT2"), getAddress("UNISWAPX_REACTOR"));
        console2.log("UniswapXV1Protocol deployed at", address(uniswapXProtocol));
        saveAddress("UNISWAP_X_V1_PROTOCOL", address(uniswapXProtocol));
    }
}
