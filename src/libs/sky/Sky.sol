// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

interface IDssPsm {
    /// @notice Sell USDC for USDS. Pulls `gemAmt` USDC from msg.sender, sends USDS to `usr`.
    /// @param usr Recipient of USDS.
    /// @param gemAmt Amount of USDC (6 decimals).
    /// @return daiOutWad Amount of USDS sent to usr (18 decimals).
    function sellGem(address usr, uint256 gemAmt) external returns (uint256 daiOutWad);

    /// @notice Buy USDC with USDS. Pulls USDS from msg.sender, sends `gemAmt` USDC to `usr`.
    /// @param usr Recipient of USDC.
    /// @param gemAmt Amount of USDC to buy (6 decimals).
    /// @return daiInWad Amount of USDS pulled from msg.sender (18 decimals, includes fee).
    function buyGem(address usr, uint256 gemAmt) external returns (uint256 daiInWad);

    /// @notice Fee (in WAD) charged on buyGem (USDS → USDC). Usually 0.
    function tout() external view returns (uint256);

    /// @notice Fee (in WAD) charged on sellGem (USDC → USDS). Usually 0.
    function tin() external view returns (uint256);
}

interface ISUsds {
    /// @notice Deposit USDS, receive sUSDS shares. ERC-4626.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Withdraw exact `assets` USDS by burning shares.
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Preview shares needed to withdraw `assets` USDS.
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /// @notice Convert shares to the current USDS value.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    function balanceOf(address account) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);
}
