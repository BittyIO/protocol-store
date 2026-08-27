// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

interface IBittyV1Depositable {
    /**
     * @notice Deposit the asset to the lending/staking protocol.
     * @dev Deposit the asset to the lending/staking protocol.
     * @param asset The address of the asset to deposit.
     * @param amount The amount of the asset to deposit.
     * @dev Not payable. Assets reach an adapter as ERC-20 transfers - native ETH is wrapped by the
     *      vault before it gets here - so no adapter has ever read msg.value and the vault has never
     *      attached any. Accepting value would only create a way for ETH to strand in an adapter with
     *      no path back out.
     */
    function deposit(address asset, uint256 amount) external;
}
