// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @title IBittyV1Protocol
 * @notice Interface for all protocols.
 * @dev A protocol does NOT declare its own category. The guard records one — a uint8, 1 = lending,
 *      2 = staking, 3 = AMM, 4 = intent — supplied by whoever registers it, and consumers read it
 *      back from {IBittyV1Guard-protocolCategory}. Curation and classification are therefore the
 *      same act, by the same party, which is why an adapter is never asked to describe itself: a
 *      self-declared category would be one more thing to verify without being the one that counts.
 */
interface IBittyV1Protocol {
    /**
     * @notice Initialize the protocol.
     * @param newOwner The address of the new owner.
     * @dev Initialize the protocol.
     */
    function initialize(address newOwner) external;

    /**
     * @notice The name of the protocol.
     * @return The name of the protocol.
     */
    function name() external view returns (string memory);

    /**
     * @notice The version of the protocol.
     * @return The version of the protocol.
     */
    function version() external view returns (string memory);
}
