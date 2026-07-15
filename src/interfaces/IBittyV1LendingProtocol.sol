// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "./IBittyV1Protocol.sol";

interface IBittyV1LendingProtocol is IBittyV1Protocol {
    /**
     * @notice Supply the asset to the lending protocol.
     * @dev Supply the asset to the lending protocol.
     * @param asset The address of the asset.
     * @param amount The amount of the asset.
     */
    function supply(address asset, uint256 amount) external payable;

    /**
     * @notice Withdraw the asset from the lending protocol, delivered to `recipient`.
     * @dev Pass the vault as `recipient` for a normal withdrawal, or a receiver to pay it straight out
     * of a supplied position in a single step.
     * @param asset The address of the asset.
     * @param amount The amount of the asset to withdraw.
     * @param recipient The address that receives the withdrawn asset.
     * @return delivered The amount of `asset` delivered to `recipient`.
     */
    function withdraw(address asset, uint256 amount, address recipient) external returns (uint256 delivered);

    /**
     * @notice Get the lending balance of the asset.
     * @dev Get the lending balance of the asset.
     * @param asset The address of the asset.
     * @return The lending balance of the asset.
     */
    function getSuppliedBalance(address asset) external view returns (uint256);
}
