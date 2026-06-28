// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @title IBittyV1Protocol
 * @notice Interface for all protocols.
 * @dev This interface is used to initialize the protocol.
 */
interface IBittyV1Protocol {
    /**
     * @notice Initialize the protocol.
     * @param newOwner The address of the new owner.
     * @dev Initialize the protocol.
     */
    function initialize(address newOwner) external;
}
