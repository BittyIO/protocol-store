// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IProtocol} from "./IProtocol.sol";

interface ILendingProtocol is IProtocol {
    /**
     * @notice Supply the asset to the lending protocol.
     * @dev Supply the asset to the lending protocol.
     * @param asset The address of the asset.
     * @param amount The amount of the asset.
     */
    function supply(address asset, uint256 amount) external payable;

    /**
     * @notice Withdraw the asset from the lending protocol.
     * @dev Withdraw the asset from the lending protocol.
     * @param asset The address of the asset.
     * @param amount The amount of the asset.
     */
    function withdraw(address asset, uint256 amount) external;

    /**
     * @notice Get the lending balance of the asset.
     * @dev Get the lending balance of the asset.
     * @param asset The address of the asset.
     * @return The lending balance of the asset.
     */
    function getSuppliedBalance(address asset) external view returns (uint256);
}
