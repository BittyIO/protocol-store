// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {SingleOrderHandlerV1} from "protocol-contracts/src/protocols/cowswap/SingleOrderHandlerV1.sol";
import {CoWSwapV1Protocol} from "protocol-contracts/src/protocols/cowswap/CoWSwapV1Protocol.sol";

contract CoWSwapV1ProtocolScript is DeployScript {
    function deploy() public override {
        SingleOrderHandlerV1 handler = new SingleOrderHandlerV1();
        console2.log("SingleOrderHandlerV1 deployed at", address(handler));
        saveAddress("SINGLE_ORDER_HANDLER_V1", address(handler));

        CoWSwapV1Protocol cowProtocol = new CoWSwapV1Protocol(
            getAddress("COW_SETTLEMENT"),
            getAddress("COW_VAULT_RELAYER"),
            getAddress("COMPOSABLE_COW"),
            getAddress("TWAP_HANDLER"),
            address(handler)
        );
        console2.log("CoWSwapV1Protocol deployed at", address(cowProtocol));
        saveAddress("COW_SWAP_V1_PROTOCOL", address(cowProtocol));
    }
}
