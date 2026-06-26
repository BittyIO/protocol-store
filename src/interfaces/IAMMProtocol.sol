// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IProtocol} from "./IProtocol.sol";

/**
 * @title IAMMProtocol
 * @notice Interface for AMM (swap and liquidity) protocols.
 */
interface IAMMProtocol is IProtocol {
    /**
     * @notice Swap tokens on the AMM protocol.
     * @dev Swap tokens on the AMM protocol.
     * @param data The data for the swap.
     * @dev Only the asset manager can execute it.
     */
    /// @notice Exact-input swap: sell exactly `sellAmount`, receive ≥ `buyAmountMin`.
    /// @dev data = abi.encode(sellToken, sellAmount, buyToken, buyAmountMin, path)
    function swap(bytes memory data) external payable;

    /// @notice Exact-output swap: receive exactly `buyAmount`, spend ≤ `sellAmountMax`.
    /// @dev data = abi.encode(sellToken, sellAmountMax, buyToken, buyAmount, reversedPath)
    ///      path must be in reverse order (buyToken → ... → sellToken) per Uniswap V3 exactOutput.
    function swapExactOut(bytes memory data) external;

    /**
     * @notice Add liquidity to the AMM protocol.
     * @dev Add liquidity to the AMM protocol.
     * @param data The data for the add liquidity.
     * @dev Only the asset manager can execute it.
     */
    function addLiquidity(bytes memory data) external;

    /**
     * @notice Remove all liquidity from the AMM protocol and claim accrued fees.
     * @dev Claims accrued fees (with collect fee to FEE_RECIPIENT), then removes the full position liquidity.
     * @param data The data for the remove liquidity.
     * @dev Only the asset manager can execute it.
     */
    function removeLiquidity(bytes memory data) external;

    /**
     * @notice Decrease liquidity from the AMM protocol and collect the decreased tokens.
     * @dev Partial decreases collect principal only. A full-position decrease also claims accrued AMM fees (with collect fee).
     * @param data The data for the decrease liquidity.
     * @dev Only the asset manager can execute it.
     */
    function decreaseLiquidity(bytes memory data) external;

    /**
     * @notice Claim fees from the AMM protocol.
     * @dev Claim fees from the AMM protocol.
     * @param data The data for the claim fees.
     * @dev Only the asset manager can execute it.
     */
    function claimAMMFees(bytes memory data) external;

    /**
     * @notice Get the liquidity of the AMM protocol.
     * @dev Get the liquidity of the AMM protocol.
     * @param data The data for the get liquidity.
     * @dev Only the asset manager can execute it.
     */
    function getLiquidity(bytes memory data) external view returns (uint256);
}
