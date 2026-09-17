// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1ProtocolBase} from "../BittyV1ProtocolBase.sol";
import {IBittyV1AMMProtocol} from "../interfaces/IBittyV1AMMProtocol.sol";
import {IBittyV1Guard, ASSET_STABLE_COIN} from "../interfaces/IBittyV1Guard.sol";
import {INonfungiblePositionManager, IUniswapV3Router} from "../libs/uniswap/v3/Uniswap.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";

contract UniswapV3Protocol is IBittyV1AMMProtocol, BittyV1ProtocolBase {
    using SafeERC20 for IERC20;

    address public constant FEE_RECIPIENT = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;
    uint256 private constant COLLECT_FEE_BPS = 100; // 1%
    uint256 private constant SWAP_FEE_BPS = 20; // 0.2% market-swap fee

    address public immutable router;
    address public immutable positionManager;
    // The Bitty guard, read only to tell whether the sold token is a stable coin (fee-split side).
    address public immutable bittyGuard;

    constructor(address router_, address positionManager_, address bittyGuard_) {
        router = router_;
        positionManager = positionManager_;
        bittyGuard = bittyGuard_;
    }

    function protocolLineage() external pure override returns (bytes32) {
        return keccak256("bitty.adapter.uniswap.v3");
    }

    function protocolVersion() external pure override returns (uint256) {
        return 1_000_001; // 1.0.1 — market swap (swap / swapExactOut) restored
    }

    receive() external payable {}

    /**
     * @notice Exact-input swap (market sell): sell exactly `sellAmount`, receive ≥ `buyAmountMin`,
     *         delivered to `recipient`. Pass the vault as `recipient` for a normal swap. The 0.2% fee
     *         goes to FEE_RECIPIENT (from the input when the sold token is a stable coin, otherwise
     *         from the output) and any unspent native ETH is refunded to the caller.
     * @dev data = abi.encode(sellToken, sellAmount, buyToken, buyAmountMin, path)
     */
    function swap(bytes memory data, address recipient) external payable override onlyOwner {
        _swap(data, recipient);
    }

    function _swap(bytes memory data, address recipient) private {
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
            if (IERC20(tokenIn).allowance(address(this), router) < swapAmountIn) {
                IERC20(tokenIn).forceApprove(router, type(uint256).max);
            }
        }

        uint256 amountOut =
            IUniswapV3Router(router).exactInput{value: tokenIn == address(0) ? swapAmountIn : msg.value}(params);

        if (address(this).balance != 0) {
            Address.sendValue(payable(msg.sender), address(this).balance);
        }

        if (tokenOut != address(0)) {
            if (feeFromOutput) {
                uint256 fee = amountOut * SWAP_FEE_BPS / 10_000;
                if (fee > 0) {
                    IERC20(tokenOut).safeTransfer(FEE_RECIPIENT, fee);
                }
                IERC20(tokenOut).safeTransfer(recipient, amountOut - fee);
            } else {
                IERC20(tokenOut).safeTransfer(recipient, amountOut);
            }
        }
    }

    /**
     * @notice Exact-output swap (market buy): receive exactly `buyAmount`, spend ≤ `sellAmountMax`,
     *         delivered to `recipient`. The 0.2% fee goes to FEE_RECIPIENT and any unspent input is
     *         refunded to the caller.
     * @dev data = abi.encode(sellToken, sellAmountMax, buyToken, buyAmount, reversedPath). The path
     *      must be reversed (buyToken → … → sellToken) per Uniswap V3 exactOutput.
     */
    function swapExactOut(bytes memory data, address recipient) external override onlyOwner {
        _swapExactOut(data, recipient);
    }

    function _swapExactOut(bytes memory data, address recipient) private {
        (address tokenIn, uint256 amountInMaximum, address tokenOut, uint256 amountOut, bytes memory path) =
            abi.decode(data, (address, uint256, address, uint256, bytes));

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountInMaximum);

        uint256 swapAmountInMaximum = amountInMaximum * 10_000 / (10_000 + SWAP_FEE_BPS);
        if (IERC20(tokenIn).allowance(address(this), router) < swapAmountInMaximum) {
            IERC20(tokenIn).forceApprove(router, type(uint256).max);
        }

        IUniswapV3Router.ExactOutputParams memory params = IUniswapV3Router.ExactOutputParams({
            path: path, recipient: address(this), amountOut: amountOut, amountInMaximum: swapAmountInMaximum
        });

        uint256 amountIn = IUniswapV3Router(router).exactOutput(params);

        uint256 fee = amountIn * SWAP_FEE_BPS / 10_000;
        if (fee > 0) IERC20(tokenIn).safeTransfer(FEE_RECIPIENT, fee);

        uint256 leftover = amountInMaximum - amountIn - fee;
        if (leftover > 0) IERC20(tokenIn).safeTransfer(msg.sender, leftover);

        IERC20(tokenOut).safeTransfer(recipient, amountOut);
    }

    // Whether `token` is a guard-registered stable coin (drives the market-swap fee split).
    function _isStablecoin(address token) internal view returns (bool) {
        return (IBittyV1Guard(bittyGuard).assetCategory(token) & ASSET_STABLE_COIN) != 0;
    }

    function addLiquidity(bytes memory data) external override onlyOwner {
        (bool isMint, bytes memory paramsEncoded) = abi.decode(data, (bool, bytes));
        if (isMint) {
            INonfungiblePositionManager.MintParams memory params =
                abi.decode(paramsEncoded, (INonfungiblePositionManager.MintParams));
            params.recipient = address(this);
            if (params.token0 != address(0)) {
                IERC20(params.token0).safeTransferFrom(msg.sender, address(this), params.amount0Desired);
                if (IERC20(params.token0).allowance(address(this), positionManager) < params.amount0Desired) {
                    IERC20(params.token0).forceApprove(positionManager, type(uint256).max);
                }
            }
            if (params.token1 != address(0)) {
                IERC20(params.token1).safeTransferFrom(msg.sender, address(this), params.amount1Desired);
                if (IERC20(params.token1).allowance(address(this), positionManager) < params.amount1Desired) {
                    IERC20(params.token1).forceApprove(positionManager, type(uint256).max);
                }
            }
            (uint256 tokenId,, uint256 amount0Used, uint256 amount1Used) =
                INonfungiblePositionManager(positionManager).mint(params);
            if (params.token0 != address(0)) {
                uint256 leftover0 = params.amount0Desired - amount0Used;
                if (leftover0 > 0) IERC20(params.token0).safeTransfer(msg.sender, leftover0);
            }
            if (params.token1 != address(0)) {
                uint256 leftover1 = params.amount1Desired - amount1Used;
                if (leftover1 > 0) IERC20(params.token1).safeTransfer(msg.sender, leftover1);
            }
            IERC721(positionManager).transferFrom(address(this), msg.sender, tokenId);
        } else {
            INonfungiblePositionManager.IncreaseLiquidityParams memory params =
                abi.decode(paramsEncoded, (INonfungiblePositionManager.IncreaseLiquidityParams));
            (,, address token0, address token1,,,,,,,,) =
                INonfungiblePositionManager(positionManager).positions(params.tokenId);
            if (token0 != address(0)) {
                IERC20(token0).safeTransferFrom(msg.sender, address(this), params.amount0Desired);
                if (IERC20(token0).allowance(address(this), positionManager) < params.amount0Desired) {
                    IERC20(token0).forceApprove(positionManager, type(uint256).max);
                }
            }
            if (token1 != address(0)) {
                IERC20(token1).safeTransferFrom(msg.sender, address(this), params.amount1Desired);
                if (IERC20(token1).allowance(address(this), positionManager) < params.amount1Desired) {
                    IERC20(token1).forceApprove(positionManager, type(uint256).max);
                }
            }
            (, uint256 amount0Used, uint256 amount1Used) =
                INonfungiblePositionManager(positionManager).increaseLiquidity(params);
            if (token0 != address(0)) {
                uint256 leftover0 = params.amount0Desired - amount0Used;
                if (leftover0 > 0) IERC20(token0).safeTransfer(msg.sender, leftover0);
            }
            if (token1 != address(0)) {
                uint256 leftover1 = params.amount1Desired - amount1Used;
                if (leftover1 > 0) IERC20(token1).safeTransfer(msg.sender, leftover1);
            }
        }
    }

    function removeLiquidity(bytes memory data) external override onlyOwner {
        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            abi.decode(data, (INonfungiblePositionManager.DecreaseLiquidityParams));

        IERC721(positionManager).transferFrom(msg.sender, address(this), params.tokenId);

        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(positionManager).positions(params.tokenId);

        uint256 principal0;
        uint256 principal1;
        if (liquidity > 0) {
            (principal0, principal1) = INonfungiblePositionManager(positionManager)
                .decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: params.tokenId,
                        liquidity: liquidity,
                        amount0Min: params.amount0Min,
                        amount1Min: params.amount1Min,
                        deadline: params.deadline
                    })
                );
        }
        _collectAndDistribute(params.tokenId, principal0, principal1, type(uint128).max, type(uint128).max);

        IERC721(positionManager).transferFrom(address(this), msg.sender, params.tokenId);
    }

    function decreaseLiquidity(bytes memory data) external override onlyOwner {
        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            abi.decode(data, (INonfungiblePositionManager.DecreaseLiquidityParams));

        IERC721(positionManager).transferFrom(msg.sender, address(this), params.tokenId);

        (uint256 principal0, uint256 principal1) =
            INonfungiblePositionManager(positionManager).decreaseLiquidity(params);
        _collectAndDistribute(params.tokenId, principal0, principal1, type(uint128).max, type(uint128).max);

        IERC721(positionManager).transferFrom(address(this), msg.sender, params.tokenId);
    }

    function claimAMMFees(bytes memory data) external override onlyOwner {
        INonfungiblePositionManager.CollectParams memory params =
            abi.decode(data, (INonfungiblePositionManager.CollectParams));

        IERC721(positionManager).transferFrom(msg.sender, address(this), params.tokenId);
        _collectAndDistribute(params.tokenId, 0, 0, params.amount0Max, params.amount1Max);
        IERC721(positionManager).transferFrom(address(this), msg.sender, params.tokenId);
    }

    function getLiquidity(bytes memory data) external view override returns (uint256) {
        uint256 tokenId = abi.decode(data, (uint256));
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(positionManager).positions(tokenId);
        return uint256(liquidity);
    }

    function _collectAndDistribute(
        uint256 tokenId,
        uint256 principal0,
        uint256 principal1,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal {
        (,, address token0, address token1,,,,,,,,) = INonfungiblePositionManager(positionManager).positions(tokenId);

        (uint256 collected0, uint256 collected1) = INonfungiblePositionManager(positionManager)
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId, recipient: address(this), amount0Max: amount0Max, amount1Max: amount1Max
                })
            );

        uint256 principalCollected0 = collected0 < principal0 ? collected0 : principal0;
        uint256 principalCollected1 = collected1 < principal1 ? collected1 : principal1;
        uint256 feeAmount0 = collected0 - principalCollected0;
        uint256 feeAmount1 = collected1 - principalCollected1;

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
