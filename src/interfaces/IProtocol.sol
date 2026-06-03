// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @title IProtocol
 * @notice Interface for all protocols.
 * @dev This interface is used to initialize the protocol.
 */
interface IProtocol {
    /**
     * @notice Initialize the protocol.
     * @param newOwner The address of the new owner.
     * @dev Initialize the protocol.
     */
    function initialize(address newOwner) external;
}
