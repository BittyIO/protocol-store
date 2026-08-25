// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";

/**
 * @title IBittyV1Protocol
 * @notice Interface for all protocols.
 * @dev Extends ERC-165 so a protocol declares its own CATEGORY — lending, staking, AMM or intent —
 *      rather than the vault and the guard each keeping a set per category and having to agree. A
 *      caller asks the protocol what it is; the guard remains the gate on whether it may be used at
 *      all, so a protocol lying about its category can only misrepresent something already curated.
 */
interface IBittyV1Protocol is IERC165 {
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
