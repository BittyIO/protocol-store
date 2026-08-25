// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @notice Sky's PSM3, the form Sky takes on Base and the other L2s.
 * @dev Not a variant of mainnet's DssLitePsm — a different contract with a different job. Mainnet
 *      splits the position into two steps (sellGem converts USDC to USDS, then sUSDS is an ERC-4626
 *      vault you deposit into); PSM3 is one three-asset module that converts directly between USDC,
 *      USDS and sUSDS at the sUSDS exchange rate.
 *
 *      Base's sUSDS is only an ERC-20 — asset(), convertToAssets(), previewWithdraw() and
 *      totalAssets() all revert on it — so there is no vault to deposit into and this module is the
 *      only way in or out. That, not the PSM difference alone, is why {SkyV1Protocol} cannot serve
 *      Base and {SkyV1BaseProtocol} exists.
 *
 *      Despite the name these are conversions, not trades: measured on Base, a USDC → sUSDS → USDC
 *      round trip returns the input to within one unit of the smallest denomination at 100, 10 000
 *      and 1 000 000 USDC — no fee, and no slippage that scales with size. The minAmountOut /
 *      maxAmountIn arguments are still passed honestly (previewed in the same call), because the
 *      module's own accounting is what guarantees that, not this contract.
 */
interface IPsm3 {
    /// @notice The three assets this module converts between. Read in the constructor to prove the
    ///         module handed to the adapter is the one the adapter was configured for.
    function usdc() external view returns (address);
    function usds() external view returns (address);
    function susds() external view returns (address);

    /// @notice Convert an exact `amountIn` of `assetIn` into `assetOut`, delivered to `receiver`.
    /// @return amountOut Amount of `assetOut` sent to `receiver`.
    function swapExactIn(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        uint256 referralCode
    ) external returns (uint256 amountOut);

    /// @notice Convert `assetIn` into an exact `amountOut` of `assetOut`, delivered to `receiver`.
    /// @return amountIn Amount of `assetIn` pulled from the caller.
    function swapExactOut(
        address assetIn,
        address assetOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address receiver,
        uint256 referralCode
    ) external returns (uint256 amountIn);

    /// @notice What {swapExactIn} would return for these arguments, at current state.
    function previewSwapExactIn(address assetIn, address assetOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut);

    /// @notice What {swapExactOut} would pull for these arguments, at current state.
    function previewSwapExactOut(address assetIn, address assetOut, uint256 amountOut)
        external
        view
        returns (uint256 amountIn);
}
