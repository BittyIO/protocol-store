// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Protocol} from "./IBittyV1Protocol.sol";

/**
 * @title IBittyV1MarketMakerProtocol
 * @notice Concentrated-liquidity position management: add, remove, decrease, claim fees, and read
 *         liquidity. Stateful — the position is an NFT held by the vault and persists between calls,
 *         which is why this side alone carries {positionManager} for the host to approve. Market swaps
 *         live in {IBittyV1MarketTradeProtocol}. Each concentrated-liquidity version (v3, v4) is its own
 *         maker adapter, since their position mechanics do not abstract behind one implementation.
 */
interface IBittyV1MarketMakerProtocol is IBittyV1Protocol {
    /**
     * @notice Add liquidity to the AMM protocol.
     * @param data The data for the add liquidity.
     * @dev Gated by the host; this adapter does not check who is calling.
     */
    function addLiquidity(bytes memory data) external;

    /**
     * @notice Remove all liquidity from the AMM protocol and claim accrued fees.
     * @dev Claims accrued fees (with collect fee to FEE_RECIPIENT), then removes the full position liquidity.
     * @param data The data for the remove liquidity.
     * @dev Gated by the host; this adapter does not check who is calling.
     */
    function removeLiquidity(bytes memory data) external;

    /**
     * @notice Decrease liquidity from the AMM protocol and collect the decreased tokens.
     * @dev Partial decreases collect principal only. A full-position decrease also claims accrued AMM fees (with collect fee).
     * @param data The data for the decrease liquidity.
     * @dev Gated by the host; this adapter does not check who is calling.
     */
    function decreaseLiquidity(bytes memory data) external;

    /**
     * @notice Claim fees from the AMM protocol.
     * @param data The data for the claim fees.
     * @dev Gated by the host; this adapter does not check who is calling.
     */
    function claimAMMFees(bytes memory data) external;

    /**
     * @notice Get the liquidity of the AMM protocol.
     * @param data The data for the get liquidity.
     * @dev Gated by the host; this adapter does not check who is calling.
     */
    function getLiquidity(bytes memory data) external view returns (uint256);

    /**
     * @notice The position-NFT manager (ERC-721) this adapter mints into. The host reads it to approve
     *         the adapter clone to pull the vault's position NFTs before an unwind.
     */
    function positionManager() external view returns (address);
}
