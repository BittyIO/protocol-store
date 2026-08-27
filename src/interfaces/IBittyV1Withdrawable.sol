// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

interface IBittyV1Withdrawable {
    /**
     * @notice Withdraw the asset from the lending/staking protocol, delivered to `recipient`.
     * @dev Pass the vault as `recipient` for a normal withdrawal, or a receiver to pay it straight out
     * of a supplied position in a single step.
     * @param asset The address of the asset.
     * @param amount The amount of the asset to withdraw.
     * @param recipient The address that receives the withdrawn asset.
     * @return delivered The amount of `asset` delivered to `recipient`.
     */
    function withdraw(address asset, uint256 amount, address recipient) external returns (uint256 delivered);
}
