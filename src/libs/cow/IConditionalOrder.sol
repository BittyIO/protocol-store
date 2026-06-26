// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {GPv2Order} from "./GPv2Order.sol";

interface IConditionalOrder {
    error OrderExpired();
    error OrderMismatch();

    function getTradeableOrder(
        address owner,
        address sender,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput
    ) external view returns (GPv2Order.Data memory);

    function verify(
        address owner,
        address sender,
        bytes32 _hash,
        bytes32 domainSeparator,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        GPv2Order.Data calldata order
    ) external view;
}
