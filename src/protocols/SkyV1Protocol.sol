// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    IBittyV1StakingProtocol,
    InvalidAsset,
    ClaimUnstakedNotSupported
} from "../interfaces/IBittyV1StakingProtocol.sol";
import {IDssPsm, ISUsds} from "../libs/sky/Sky.sol";
import {YieldFeeTracker} from "../libs/YieldFeeTracker.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

contract SkyV1Protocol is IBittyV1StakingProtocol, YieldFeeTracker, Ownable, Initializable {
    using SafeERC20 for IERC20;

    // USDC is 6 decimals, USDS is 18 decimals → multiply by 1e12 to convert
    uint256 private constant GEM_CONVERSION_FACTOR = 1e12;
    uint256 private constant WAD = 1e18;

    IERC20 public immutable usdc;
    IERC20 public immutable usds;
    ISUsds public immutable sUsds;
    IDssPsm public immutable psm;

    mapping(address => address) public receiptTokenOf;

    function name() external pure override returns (string memory) {
        return "Sky V1";
    }

    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    constructor(address usdc_, address usds_, address sUsds_, address psm_) Ownable(msg.sender) {
        usdc = IERC20(usdc_);
        usds = IERC20(usds_);
        sUsds = ISUsds(sUsds_);
        psm = IDssPsm(psm_);
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    /**
     * @notice Stake USDC: converts USDC → USDS via PSM, then deposits USDS into sUSDS.
     * @dev Converts USDC → USDS via PSM, then deposits USDS into sUSDS.
     * @param asset Must be the USDC address.
     * @param amount Amount of USDC (6 decimals) to stake.
     */
    function stake(address asset, uint256 amount) external payable override onlyOwner {
        if (asset != address(usdc)) revert InvalidAsset();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        if (usdc.allowance(address(this), address(psm)) < amount) {
            usdc.forceApprove(address(psm), type(uint256).max);
        }
        uint256 usdsReceived = psm.sellGem(address(this), amount);

        if (usds.allowance(address(this), address(sUsds)) < usdsReceived) {
            usds.forceApprove(address(sUsds), type(uint256).max);
        }
        sUsds.deposit(usdsReceived, address(this));
        _recordDeposit(asset, amount);

        if (receiptTokenOf[asset] == address(0)) {
            receiptTokenOf[asset] = address(sUsds);
        }
        uint256 shares = sUsds.balanceOf(address(this));
        if (shares > 0) {
            IERC20(address(sUsds)).safeTransfer(msg.sender, shares);
        }
    }

    /**
     * @notice Returns current staked balance in USDC terms (6 decimals).
     * @dev Returns current staked balance in USDC terms (6 decimals).
     * @param asset Must be the USDC address.
     * @return The staked balance in USDC terms (6 decimals).
     */
    function getStakedBalance(address asset) external view override returns (uint256) {
        if (asset != address(usdc)) revert InvalidAsset();
        uint256 shares = sUsds.balanceOf(owner());
        if (shares == 0) return 0;
        uint256 usdsValue = sUsds.convertToAssets(shares);
        return usdsValue / GEM_CONVERSION_FACTOR;
    }

    /**
     * @notice Unstake the staked asset and deliver the redeemed USDC to `recipient`.
     * @dev Redeems sUSDS → USDS, converts USDS → USDC via PSM. The sUSDS shares are always pulled
     * from `owner()` (the vault, via msg.sender); only the resulting USDC is routed to `recipient`.
     * Any USDS dust from rounding is returned to the vault. Sky settles synchronously, so the USDC is
     * delivered to `recipient` in the same transaction. Pass the vault as `recipient` for a normal
     * unstake, or a receiver to pay it straight out of the staked position.
     * @param asset Must be the USDC address.
     * @param amount Amount of USDC (6 decimals) to unstake.
     * @param recipient The address that receives the redeemed USDC.
     * @return delivered The amount of USDC delivered to `recipient`.
     */
    function unstake(address asset, uint256 amount, address recipient)
        external
        override
        onlyOwner
        returns (uint256 delivered)
    {
        if (asset != address(usdc)) revert InvalidAsset();

        uint256 tout = psm.tout();
        uint256 usdcBefore;
        uint256 gross;

        if (amount == type(uint256).max) {
            uint256 shares = sUsds.balanceOf(msg.sender);
            IERC20(address(sUsds)).safeTransferFrom(msg.sender, address(this), shares);
            uint256 usdsAvailable = sUsds.convertToAssets(shares);
            sUsds.withdraw(usdsAvailable, address(this), address(this));

            amount = usdsAvailable * WAD / (GEM_CONVERSION_FACTOR * (WAD + tout));

            if (usds.allowance(address(this), address(psm)) < usdsAvailable) {
                usds.forceApprove(address(psm), type(uint256).max);
            }
            usdcBefore = usdc.balanceOf(address(this));
            psm.buyGem(address(this), amount);
            gross = usdc.balanceOf(address(this)) - usdcBefore;

            uint256 dust = usds.balanceOf(address(this));
            if (dust > 0) usds.safeTransfer(msg.sender, dust);
            return _deliverWithEarningFee(asset, usdc, gross, recipient);
        }

        uint256 usdsNeeded = amount * GEM_CONVERSION_FACTOR;
        if (tout > 0) {
            usdsNeeded = usdsNeeded + (usdsNeeded * tout) / WAD;
        }

        uint256 sharesNeeded = sUsds.previewWithdraw(usdsNeeded);
        IERC20(address(sUsds)).safeTransferFrom(msg.sender, address(this), sharesNeeded);

        sUsds.withdraw(usdsNeeded, address(this), address(this));

        if (usds.allowance(address(this), address(psm)) < usdsNeeded) {
            usds.forceApprove(address(psm), type(uint256).max);
        }
        usdcBefore = usdc.balanceOf(address(this));
        psm.buyGem(address(this), amount);
        gross = usdc.balanceOf(address(this)) - usdcBefore;
        return _deliverWithEarningFee(asset, usdc, gross, recipient);
    }

    /**
     * @notice Sky Protocol (sUSDS) supports immediate withdrawal — no queued requests.
     * @dev Sky Protocol (sUSDS) supports immediate withdrawal — no queued requests.
     * @return The unstake request ids.
     */
    function getUnstakeRequestIds() external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }

    /**
     * @notice No-op: Sky Protocol does not use a withdrawal queue.
     * @dev No-op: Sky Protocol does not use a withdrawal queue.
     */
    function claimUnstaked(uint256[] memory) external view override onlyOwner {
        revert ClaimUnstakedNotSupported();
    }
}
