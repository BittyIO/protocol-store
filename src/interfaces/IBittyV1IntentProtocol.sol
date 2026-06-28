// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "./IBittyV1Protocol.sol";

error OrderNotExpired();

interface IBittyV1IntentProtocol is IBittyV1Protocol {
    event Trade(bytes data, address indexed sender, address indexed protocol);
    event CancelTrade(bytes data, address indexed sender, address indexed protocol);

    function trade(bytes memory data) external returns (bytes32 orderId);

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4);

    function cancelTrade(bytes memory data) external;

    /// @dev Permissionless cleanup of expired orders. Reverts with OrderNotExpired if any order is still live.
    function cleanExpiredOrders(bytes32[] calldata orderDigests) external;
}
