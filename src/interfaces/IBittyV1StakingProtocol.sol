// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "./IBittyV1Protocol.sol";
import {IBittyV1Withdrawable} from "./IBittyV1Withdrawable.sol";

error UnstakeMoreThanStaked();
error InvalidAsset();
error ClaimUnstakedNotSupported();
error UnstakeToNotSupported();

/**
 * @title IBittyV1StakingProtocol
 * @notice Interface for staking protocols.
 * @dev This interface is used to stake and unstake the asset.
 */
interface IBittyV1StakingProtocol is IBittyV1Protocol, IBittyV1Withdrawable {
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
