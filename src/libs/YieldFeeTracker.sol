// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title YieldFeeTracker
/// @notice Tracks cumulative deposits and withdrawals per asset. When a withdrawal exceeds
///         remaining principal, 10% of the earnings portion is sent to FEE_RECIPIENT.
abstract contract YieldFeeTracker {
    using SafeERC20 for IERC20;

    address public constant FEE_RECIPIENT = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;
    uint256 private constant EARNING_FEE_BPS = 1000; // 10%

    struct AssetLedger {
        uint256 totalDeposited;
        uint256 totalWithdrawn;
    }

    mapping(address => AssetLedger) public assetLedger;

    function _recordDeposit(address asset, uint256 amount) internal {
        assetLedger[asset].totalDeposited += amount;
    }

    /// @dev Applies the earnings fee on `grossAmount` already held by this contract, then delivers the net to `recipient`.
    /// @return netDelivered Amount sent to `recipient` after fee.
    function _deliverWithEarningFee(address asset, IERC20 token, uint256 grossAmount, address recipient)
        internal
        returns (uint256 netDelivered)
    {
        AssetLedger storage ledger = assetLedger[asset];

        uint256 remainingPrincipal =
            ledger.totalDeposited > ledger.totalWithdrawn ? ledger.totalDeposited - ledger.totalWithdrawn : 0;

        uint256 earningPortion = grossAmount > remainingPrincipal ? grossAmount - remainingPrincipal : 0;
        uint256 fee = earningPortion * EARNING_FEE_BPS / 10_000;

        ledger.totalWithdrawn += grossAmount;

        if (fee > 0) {
            token.safeTransfer(FEE_RECIPIENT, fee);
        }

        netDelivered = grossAmount - fee;
        if (netDelivered > 0) {
            token.safeTransfer(recipient, netDelivered);
        }
    }
}
