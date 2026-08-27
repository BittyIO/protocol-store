// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    IBittyV1StakingProtocol,
    InvalidAsset,
    ClaimUnstakedNotSupported
} from "../interfaces/IBittyV1StakingProtocol.sol";
import {IPsm3} from "../libs/sky/Psm3.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

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
contract SkyV1EvmProtocol is IBittyV1StakingProtocol, Ownable, Initializable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    IERC20 public immutable sUsds;
    IPsm3 public immutable psm;

    mapping(address => address) public receiptTokenOf;

    function name() external pure override returns (string memory) {
        return "Sky V1";
    }

    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    constructor(address usdc_, address sUsds_, address psm_) Ownable(msg.sender) {
        if (IPsm3(psm_).usdc() != usdc_ || IPsm3(psm_).susds() != sUsds_) revert PsmAssetMismatch();
        usdc = IERC20(usdc_);
        sUsds = IERC20(sUsds_);
        psm = IPsm3(psm_);
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    function deposit(address asset, uint256 amount) external override onlyOwner {
        if (asset != address(usdc)) revert InvalidAsset();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        if (usdc.allowance(address(this), address(psm)) < amount) {
            usdc.forceApprove(address(psm), type(uint256).max);
        }

        uint256 minOut = psm.previewSwapExactIn(address(usdc), address(sUsds), amount);
        psm.swapExactIn(address(usdc), address(sUsds), amount, minOut, msg.sender, 0);

        if (receiptTokenOf[asset] == address(0)) {
            receiptTokenOf[asset] = address(sUsds);
        }
    }

    function getStakedBalance(address asset) external view override returns (uint256) {
        if (asset != address(usdc)) revert InvalidAsset();
        uint256 shares = sUsds.balanceOf(owner());
        if (shares == 0) return 0;
        return psm.previewSwapExactIn(address(sUsds), address(usdc), shares);
    }

    function withdraw(address asset, uint256 amount, address recipient)
        external
        override
        onlyOwner
        returns (uint256 delivered)
    {
        if (asset != address(usdc)) revert InvalidAsset();

        if (amount == type(uint256).max) {
            uint256 shares = sUsds.balanceOf(msg.sender);
            if (shares == 0) return 0;
            IERC20(address(sUsds)).safeTransferFrom(msg.sender, address(this), shares);
            _approvePsm(shares);

            uint256 minOut = psm.previewSwapExactIn(address(sUsds), address(usdc), shares);
            return psm.swapExactIn(address(sUsds), address(usdc), shares, minOut, recipient, 0);
        }

        uint256 sharesNeeded = psm.previewSwapExactOut(address(sUsds), address(usdc), amount);
        IERC20(address(sUsds)).safeTransferFrom(msg.sender, address(this), sharesNeeded);
        _approvePsm(sharesNeeded);

        // maxAmountIn is the preview from this same call, so it can only be met exactly.
        psm.swapExactOut(address(sUsds), address(usdc), amount, sharesNeeded, recipient, 0);
        return amount;
    }

    function _approvePsm(uint256 shares) private {
        if (sUsds.allowance(address(this), address(psm)) < shares) {
            IERC20(address(sUsds)).forceApprove(address(psm), type(uint256).max);
        }
    }

    function getUnstakeRequestIds() external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }

    function claimUnstaked(uint256[] memory) external view override onlyOwner {
        revert ClaimUnstakedNotSupported();
    }
}
