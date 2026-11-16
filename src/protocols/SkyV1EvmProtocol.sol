// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1ProtocolBase} from "../BittyV1ProtocolBase.sol";
import {BittyV1YieldFee} from "../BittyV1YieldFee.sol";
import {IBittyV1Protocol, InvalidAsset} from "../interfaces/IBittyV1Protocol.sol";
import {IBittyV1Yield, ClaimNotSupported} from "../interfaces/IBittyV1Yield.sol";
import {IPsm3} from "../libs/sky/Psm3.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

error PsmAssetMismatch();

/**
 * @title SkyV1EvmProtocol
 * @notice Sky (sUSDS) yield on Base, where the protocol is a single PSM3 module rather than
 *         mainnet's PSM + ERC-4626 vault pair.
 *
 * @dev A separate contract from {SkyV1Protocol} rather than a branch inside it, because the two
 *      chains share no call: mainnet does sellGem/buyGem plus sUSDS deposit/withdraw, Base does one
 *      swapExactIn/swapExactOut. Base's sUSDS is a plain ERC-20 whose asset(), convertToAssets() and
 *      previewWithdraw() all revert, so the mainnet path could not be made to work here at all.
 *
 *      The shape is simpler in every direction: no USDS leg (PSM3 converts USDC to sUSDS in one
 *      hop), no share maths, and a position's USDC value comes from the module itself rather than
 *      from a vault's exchange rate. USDS is therefore not a constructor argument.
 *
 *      As with {SkyV1Protocol}, the receipt token (sUSDS) is held by the VAULT, not by this adapter:
 *      the adapter is a stateless router and holds nothing between calls.
 */
/// @dev From 1.1.0 it takes Bitty's yield fee (see {BittyV1YieldFee}) in USDC.
contract SkyV1EvmProtocol is IBittyV1Yield, BittyV1ProtocolBase, BittyV1YieldFee {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    IERC20 public immutable sUsds;
    IPsm3 public immutable psm;

    mapping(address => address) public receiptTokenOf;

    constructor(address usdc_, address sUsds_, address psm_) {
        if (IPsm3(psm_).usdc() != usdc_ || IPsm3(psm_).susds() != sUsds_) revert PsmAssetMismatch();
        usdc = IERC20(usdc_);
        sUsds = IERC20(sUsds_);
        psm = IPsm3(psm_);
    }

    function protocolLineage() external pure override returns (bytes32) {
        return keccak256("bitty.adapter.sky.v1.evm");
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

        uint256 minOut = psm.previewSwapExactIn(address(usdc), address(sUsds), amount);
        psm.swapExactIn(address(usdc), address(sUsds), amount, minOut, msg.sender, 0);

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
        return psm.previewSwapExactIn(address(sUsds), address(usdc), shares);
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

        if (amount == type(uint256).max) {
            uint256 shares = sUsds.balanceOf(msg.sender);
            if (shares == 0) return 0;
            IERC20(address(sUsds)).safeTransferFrom(msg.sender, address(this), shares);
            _approvePsm(shares);

            uint256 minOut = psm.previewSwapExactIn(address(sUsds), address(usdc), shares);
            out = psm.swapExactIn(address(sUsds), address(usdc), shares, minOut, payee, 0);
        } else {
            out = amount + due;
            uint256 sharesNeeded = psm.previewSwapExactOut(address(sUsds), address(usdc), out);
            IERC20(address(sUsds)).safeTransferFrom(msg.sender, address(this), sharesNeeded);
            _approvePsm(sharesNeeded);

            // maxAmountIn is the preview from this same call, so it can only be met exactly.
            psm.swapExactOut(address(sUsds), address(usdc), out, sharesNeeded, payee, 0);
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

    function _approvePsm(uint256 shares) private {
        if (sUsds.allowance(address(this), address(psm)) < shares) {
            IERC20(address(sUsds)).forceApprove(address(psm), type(uint256).max);
        }
    }

    function getPendingWithdrawalIds() external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }

    function claimWithdrawals(uint256[] memory) external view override onlyOwner {
        revert ClaimNotSupported();
    }
}
