// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {GPv2Order} from "../../libs/cow/GPv2Order.sol";
import {IConditionalOrder} from "../../libs/cow/IConditionalOrder.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title SingleOrderHandlerV1
 * @notice Composable CoW handler for single limit orders (KIND_SELL or KIND_BUY).
 *         The full GPv2Order is stored as staticInput and returned verbatim each poll.
 *         Deploy once; any CoWSwapV1Protocol clone references this handler address.
 */
contract SingleOrderHandlerV1 is IConditionalOrder {
    function getTradeableOrder(address, address, bytes32, bytes calldata staticInput, bytes calldata)
        external
        view
        override
        returns (GPv2Order.Data memory order)
    {
        order = abi.decode(staticInput, (GPv2Order.Data));
        if (order.validTo < block.timestamp) revert OrderExpired();
    }

    function verify(
        address,
        address,
        bytes32 _hash,
        bytes32 domainSeparator,
        bytes32,
        bytes calldata staticInput,
        bytes calldata,
        GPv2Order.Data calldata
    ) external view override {
        GPv2Order.Data memory order = abi.decode(staticInput, (GPv2Order.Data));
        if (order.validTo < block.timestamp) revert OrderExpired();
        if (GPv2Order.hash(order, domainSeparator) != _hash) revert OrderMismatch();
    }
}
