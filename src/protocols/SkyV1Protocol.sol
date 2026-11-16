// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1ProtocolBase} from "../BittyV1ProtocolBase.sol";
import {BittyV1YieldFee} from "../BittyV1YieldFee.sol";
import {IBittyV1Protocol, InvalidAsset} from "../interfaces/IBittyV1Protocol.sol";
import {IBittyV1Yield, ClaimNotSupported} from "../interfaces/IBittyV1Yield.sol";
import {IDssPsm, ISUsds} from "../libs/sky/Sky.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Puts the vault's USDC into sUSDS through Sky's PSM: the vault holds the sUSDS, this clone
 *         moves it. From 1.1.0 it takes Bitty's yield fee (see {BittyV1YieldFee}) in USDC.
 */
contract SkyV1Protocol is IBittyV1Yield, BittyV1ProtocolBase, BittyV1YieldFee {
    using SafeERC20 for IERC20;

    // USDC is 6 decimals, USDS is 18 decimals → multiply by 1e12 to convert
    uint256 private constant GEM_CONVERSION_FACTOR = 1e12;
    uint256 private constant WAD = 1e18;

    IERC20 public immutable usdc;
    IERC20 public immutable usds;
    ISUsds public immutable sUsds;
    IDssPsm public immutable psm;

    mapping(address => address) public receiptTokenOf;

    constructor(address usdc_, address usds_, address sUsds_, address psm_) {
        usdc = IERC20(usdc_);
        usds = IERC20(usds_);
        sUsds = ISUsds(sUsds_);
        psm = IDssPsm(psm_);
    }

    function protocolLineage() external pure override returns (bytes32) {
        return keccak256("bitty.adapter.sky.v1");
    }

    function protocolVersion() external pure override returns (uint256) {
        return 1_001_000; // 1.1.0: the yield fee
    }

    function deposit(address asset, uint256 amount) external override onlyOwner {
        if (asset != address(usdc)) revert InvalidAsset();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        (uint256 gross,) = _openBooks(asset);

        if (usdc.allowance(address(this), address(psm)) < amount) {
            usdc.forceApprove(address(psm), type(uint256).max);
        }
        uint256 usdsReceived = psm.sellGem(address(this), amount);

        if (usds.allowance(address(this), address(sUsds)) < usdsReceived) {
            usds.forceApprove(address(sUsds), type(uint256).max);
        }

        sUsds.deposit(usdsReceived, msg.sender);

        if (receiptTokenOf[asset] == address(0)) {
            receiptTokenOf[asset] = address(sUsds);
        }
        _closeDeposit(asset, gross);
    }

    /**
     * @dev 100 USDC.
     */
    function _minFee(address) internal pure override returns (uint256) {
        return 100e6;
    }

    /**
     * The vault's sUSDS in USDC, as the PSM would pay it out.
     */
    function _gross(address) internal view override returns (uint256) {
        uint256 shares = sUsds.balanceOf(owner());
        if (shares == 0) return 0;
        uint256 usdsValue = sUsds.convertToAssets(shares);
        return usdsValue * WAD / (GEM_CONVERSION_FACTOR * (WAD + psm.tout()));
    }

    /**
     * What the vault can take out, in USDC: its sUSDS less the yield fee it owes.
     */
    function getBalance(address asset) external view override returns (uint256) {
        if (asset != address(usdc)) revert InvalidAsset();
        return _net(asset);
    }

    /**
     * @dev With a fee owed, the PSM pays the clone `amount` plus the fee and the clone splits it; with
     *      none, it pays `recipient` directly, as before the fee.
     */
    function withdraw(address asset, uint256 amount, address recipient)
        external
        override
        onlyOwner
        returns (uint256 delivered)
    {
        if (asset != address(usdc)) revert InvalidAsset();
        (uint256 gross, uint256 owed) = _openBooks(asset);
        uint256 due = _feeDue(asset, amount, owed);
        address payee = due == 0 ? recipient : address(this);
        uint256 out;

        uint256 tout = psm.tout();

        if (amount == type(uint256).max) {
            uint256 shares = sUsds.balanceOf(msg.sender);
            IERC20(address(sUsds)).safeTransferFrom(msg.sender, address(this), shares);
            uint256 usdsAvailable = sUsds.convertToAssets(shares);
            sUsds.withdraw(usdsAvailable, address(this), address(this));

            out = usdsAvailable * WAD / (GEM_CONVERSION_FACTOR * (WAD + tout));

            if (usds.allowance(address(this), address(psm)) < usdsAvailable) {
                usds.forceApprove(address(psm), type(uint256).max);
            }

            psm.buyGem(payee, out);

            uint256 dust = usds.balanceOf(address(this));
            if (dust > 0) usds.safeTransfer(msg.sender, dust);
        } else {
            out = amount + due;
            uint256 usdsNeeded = out * GEM_CONVERSION_FACTOR;
            if (tout > 0) {
                usdsNeeded = usdsNeeded + (usdsNeeded * tout) / WAD;
            }

            uint256 sharesNeeded = sUsds.previewWithdraw(usdsNeeded);
            IERC20(address(sUsds)).safeTransferFrom(msg.sender, address(this), sharesNeeded);

            sUsds.withdraw(usdsNeeded, address(this), address(this));

            if (usds.allowance(address(this), address(psm)) < usdsNeeded) {
                usds.forceApprove(address(psm), type(uint256).max);
            }
            psm.buyGem(payee, out);
        }

        delivered = out;
        if (due != 0) {
            uint256 fee = due < out ? due : out;
            _payYieldFee(address(usdc), fee);
            delivered = out - fee;
            usdc.safeTransfer(recipient, delivered);
        }
        _closeWithdrawal(asset, gross, due != owed);
    }

    function getPendingWithdrawalIds() external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }

    function claimWithdrawals(uint256[] memory) external view override onlyOwner {
        revert ClaimNotSupported();
    }
}
