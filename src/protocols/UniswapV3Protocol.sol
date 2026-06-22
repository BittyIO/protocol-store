// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IAMMProtocol} from "../interfaces/IAMMProtocol.sol";
import {IGuard} from "../interfaces/IGuard.sol";
import {IUniswapV3Router, INonfungiblePositionManager} from "../libs/uniswap/v3/Uniswap.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

contract UniswapV3Protocol is IAMMProtocol, Ownable, Initializable {
    using SafeERC20 for IERC20;

    address public constant FEE_RECIPIENT = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;
    uint256 private constant SWAP_FEE_BPS = 20; // 0.2%
    uint256 private constant COLLECT_FEE_BPS = 100; // 1%

    address public immutable router;
    address public immutable positionManager;
    address public immutable bittyGuard;

    constructor(address router_, address positionManager_, address bittyGuard_) {
        router = router_;
        positionManager = positionManager_;
        bittyGuard = bittyGuard_;
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    receive() external payable {}

    function swap(bytes memory data) external payable override onlyOwner {
        (address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOutMinimum, bytes memory path) =
            abi.decode(data, (address, uint256, address, uint256, bytes));

        uint256 swapAmountIn = amountIn;
        bool feeFromOutput;

        if (_isStablecoin(tokenIn)) {
            uint256 fee = amountIn * SWAP_FEE_BPS / 10_000;
            if (fee > 0) {
                if (tokenIn != address(0)) {
                    IERC20(tokenIn).safeTransferFrom(msg.sender, FEE_RECIPIENT, fee);
                } else {
                    Address.sendValue(payable(FEE_RECIPIENT), fee);
                }
                swapAmountIn = amountIn - fee;
            }
        } else {
            feeFromOutput = true;
        }

        IUniswapV3Router.ExactInputParams memory params = IUniswapV3Router.ExactInputParams({
            path: path, recipient: address(this), amountIn: swapAmountIn, amountOutMinimum: amountOutMinimum
        });

        if (tokenIn != address(0)) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), swapAmountIn);
            IERC20(tokenIn).safeApprove(router, swapAmountIn);
        }

        uint256 amountOut =
            IUniswapV3Router(router).exactInput{value: tokenIn == address(0) ? swapAmountIn : msg.value}(params);

        if (tokenIn != address(0)) {
            IERC20(tokenIn).safeApprove(router, 0);
        }

        if (address(this).balance != 0) {
            Address.sendValue(payable(msg.sender), address(this).balance);
        }

        if (tokenOut != address(0)) {
            if (feeFromOutput) {
                uint256 fee = amountOut * SWAP_FEE_BPS / 10_000;
                if (fee > 0) {
                    IERC20(tokenOut).safeTransfer(FEE_RECIPIENT, fee);
                }
                IERC20(tokenOut).safeTransfer(msg.sender, amountOut - fee);
            } else {
                IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
            }
        }
    }

    function addLiquidity(bytes memory data) external override onlyOwner {
        (bool isMint, bytes memory paramsEncoded) = abi.decode(data, (bool, bytes));
        if (isMint) {
            INonfungiblePositionManager.MintParams memory params =
                abi.decode(paramsEncoded, (INonfungiblePositionManager.MintParams));
            params.recipient = address(this);
            if (params.token0 != address(0)) {
                IERC20(params.token0).safeTransferFrom(msg.sender, address(this), params.amount0Desired);
                IERC20(params.token0).safeApprove(positionManager, params.amount0Desired);
            }
            if (params.token1 != address(0)) {
                IERC20(params.token1).safeTransferFrom(msg.sender, address(this), params.amount1Desired);
                IERC20(params.token1).safeApprove(positionManager, params.amount1Desired);
            }
            (,, uint256 amount0Used, uint256 amount1Used) = INonfungiblePositionManager(positionManager).mint(params);
            if (params.token0 != address(0)) {
                IERC20(params.token0).safeApprove(positionManager, 0);
                uint256 leftover0 = params.amount0Desired - amount0Used;
                if (leftover0 > 0) IERC20(params.token0).safeTransfer(msg.sender, leftover0);
            }
            if (params.token1 != address(0)) {
                IERC20(params.token1).safeApprove(positionManager, 0);
                uint256 leftover1 = params.amount1Desired - amount1Used;
                if (leftover1 > 0) IERC20(params.token1).safeTransfer(msg.sender, leftover1);
            }
        } else {
            INonfungiblePositionManager.IncreaseLiquidityParams memory params =
                abi.decode(paramsEncoded, (INonfungiblePositionManager.IncreaseLiquidityParams));
            (,, address token0, address token1,,,,,,,,) =
                INonfungiblePositionManager(positionManager).positions(params.tokenId);
            if (token0 != address(0)) {
                IERC20(token0).safeTransferFrom(msg.sender, address(this), params.amount0Desired);
                IERC20(token0).safeApprove(positionManager, params.amount0Desired);
            }
            if (token1 != address(0)) {
                IERC20(token1).safeTransferFrom(msg.sender, address(this), params.amount1Desired);
                IERC20(token1).safeApprove(positionManager, params.amount1Desired);
            }
            (, uint256 amount0Used, uint256 amount1Used) =
                INonfungiblePositionManager(positionManager).increaseLiquidity(params);
            if (token0 != address(0)) {
                IERC20(token0).safeApprove(positionManager, 0);
                uint256 leftover0 = params.amount0Desired - amount0Used;
                if (leftover0 > 0) IERC20(token0).safeTransfer(msg.sender, leftover0);
            }
            if (token1 != address(0)) {
                IERC20(token1).safeApprove(positionManager, 0);
                uint256 leftover1 = params.amount1Desired - amount1Used;
                if (leftover1 > 0) IERC20(token1).safeTransfer(msg.sender, leftover1);
            }
        }
    }

    function removeLiquidity(bytes memory data) external override onlyOwner {
        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            abi.decode(data, (INonfungiblePositionManager.DecreaseLiquidityParams));

        _claimAMMFees(params.tokenId, type(uint128).max, type(uint128).max);

        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(positionManager).positions(params.tokenId);
        if (liquidity > 0) {
            (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(positionManager)
                .decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: params.tokenId,
                        liquidity: liquidity,
                        amount0Min: params.amount0Min,
                        amount1Min: params.amount1Min,
                        deadline: params.deadline
                    })
                );
            _collectPrincipal(params.tokenId, uint128(amount0), uint128(amount1));
        }
    }

    function decreaseLiquidity(bytes memory data) external override onlyOwner {
        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            abi.decode(data, (INonfungiblePositionManager.DecreaseLiquidityParams));

        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(positionManager).positions(params.tokenId);
        if (params.liquidity == liquidity) {
            _claimAMMFees(params.tokenId, type(uint128).max, type(uint128).max);
        }

        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(positionManager).decreaseLiquidity(params);
        _collectPrincipal(params.tokenId, uint128(amount0), uint128(amount1));
    }

    /**
     * @notice Claim fees from the Uniswap V3 position.
     * @dev Claim fees from the Uniswap V3 position.
     * @param data The data for the claim fees.
     * @dev Only the owner can execute it, the claim fees must go to the owner (vault).
     */
    function claimAMMFees(bytes memory data) external override onlyOwner {
        INonfungiblePositionManager.CollectParams memory params =
            abi.decode(data, (INonfungiblePositionManager.CollectParams));
        _claimAMMFees(params.tokenId, params.amount0Max, params.amount1Max);
    }

    function getLiquidity(bytes memory data) external view override returns (uint256) {
        uint256 tokenId = abi.decode(data, (uint256));
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(positionManager).positions(tokenId);
        return uint256(liquidity);
    }

    function _isStablecoin(address token) internal view returns (bool) {
        return IGuard(bittyGuard).isStableCoinRegistered(token);
    }

    function _collectPrincipal(uint256 tokenId, uint128 amount0Max, uint128 amount1Max) internal {
        (,, address token0, address token1,,,,,,,,) = INonfungiblePositionManager(positionManager).positions(tokenId);

        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(positionManager)
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId, recipient: address(this), amount0Max: amount0Max, amount1Max: amount1Max
                })
            );

        if (amount0 > 0) IERC20(token0).safeTransfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(token1).safeTransfer(msg.sender, amount1);
    }

    function _claimAMMFees(uint256 tokenId, uint128 amount0Max, uint128 amount1Max) internal {
        (,, address token0, address token1,,,,,,, uint128 principalOwed0, uint128 principalOwed1) =
            INonfungiblePositionManager(positionManager).positions(tokenId);

        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(positionManager)
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId, recipient: address(this), amount0Max: amount0Max, amount1Max: amount1Max
                })
            );

        uint256 principalCollected0 = amount0 < principalOwed0 ? amount0 : principalOwed0;
        uint256 principalCollected1 = amount1 < principalOwed1 ? amount1 : principalOwed1;
        uint256 feeAmount0 = amount0 - principalCollected0;
        uint256 feeAmount1 = amount1 - principalCollected1;

        if (principalCollected0 > 0) IERC20(token0).safeTransfer(msg.sender, principalCollected0);
        if (principalCollected1 > 0) IERC20(token1).safeTransfer(msg.sender, principalCollected1);

        _transferClaimedFeesWithCollectFee(token0, token1, feeAmount0, feeAmount1);
    }

    function _transferClaimedFeesWithCollectFee(address token0, address token1, uint256 amount0, uint256 amount1)
        internal
    {
        if (amount0 > 0) {
            uint256 fee0 = amount0 * COLLECT_FEE_BPS / 10_000;
            if (fee0 > 0) {
                IERC20(token0).safeTransfer(FEE_RECIPIENT, fee0);
            }
            IERC20(token0).safeTransfer(msg.sender, amount0 - fee0);
        }
        if (amount1 > 0) {
            uint256 fee1 = amount1 * COLLECT_FEE_BPS / 10_000;
            if (fee1 > 0) {
                IERC20(token1).safeTransfer(FEE_RECIPIENT, fee1);
            }
            IERC20(token1).safeTransfer(msg.sender, amount1 - fee1);
        }
    }
}
