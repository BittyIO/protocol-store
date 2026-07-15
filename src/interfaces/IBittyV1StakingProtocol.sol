// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "./IBittyV1Protocol.sol";

error UnstakeMoreThanStaked();
error InvalidAsset();
error ClaimUnstakedNotSupported();
// Thrown by protocols whose unstake settles asynchronously (e.g. Lido's
// withdrawal queue): they cannot deliver the asset to a recipient in the same
// transaction, so on-behalf unstaking is not supported.
error UnstakeToNotSupported();

/**
 * @title IBittyV1StakingProtocol
 * @notice Interface for staking protocols.
 * @dev This interface is used to stake and unstake the asset.
 */
interface IBittyV1StakingProtocol is IBittyV1Protocol {
    /**
     * @notice Stake the asset to the staking protocol.
     * @dev Stake the asset to the staking protocol.
     * @param asset The address of the asset.
     * @param amount The amount of the asset.
     */
    function stake(address asset, uint256 amount) external payable;

    /**
     * @notice Get the staking balance.
     * @dev Get the staking balance.
     * @param asset The address of the asset.
     * @return The staking balance.
     */
    function getStakedBalance(address asset) external view returns (uint256);

    /**
     * @notice Unstake the asset from the staking protocol, delivered to `recipient`.
     * @dev Pass the vault as `recipient` for a normal unstake, or a receiver to pay it straight out of a
     * staked position in a single step. Delivering to a non-vault recipient is only supported by
     * protocols that settle synchronously; asynchronous ones (Lido) revert with {UnstakeToNotSupported}
     * unless `recipient` is the vault itself.
     * @param asset The address of the asset.
     * @param amount The amount of the asset to unstake.
     * @param recipient The address that receives the unstaked asset.
     * @return delivered The amount of `asset` delivered to `recipient` (0 for asynchronous protocols).
     */
    function unstake(address asset, uint256 amount, address recipient) external returns (uint256 delivered);

    /**
     * @notice Get the unstake request ids.
     * @dev Get the unstake request ids, some staking protocols.
     * Some protocols for ETH staking need to wait a period of time before the unstake request is finalized.
     * Some protocols for StableCoin staking do not need this.
     * @return The unstake request ids.
     */
    function getUnstakeRequestIds() external view returns (uint256[] memory);

    /**
     * @notice Claim the unstaked asset from the staking protocol.
     * @dev Claim the unstaked asset from the staking protocol.
     * Some protocols for ETH staking need to wait a period of time before the unstake request is finalized.
     * Some protocols for StableCoin staking do not need this.
     * @param requestIds The request ids to claim.
     */
    function claimUnstaked(uint256[] memory requestIds) external;
}
