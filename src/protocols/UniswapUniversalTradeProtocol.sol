// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1ProtocolBase} from "../BittyV1ProtocolBase.sol";
import {IBittyV1MarketTradeProtocol} from "../interfaces/IBittyV1MarketTradeProtocol.sol";
import {IBittyV1Guard, ASSET_STABLE_COIN} from "../interfaces/IBittyV1Guard.sol";
import {IUniversalRouter, IPermit2, UniversalRoute} from "../libs/uniswap/universal/UniversalRouter.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";

error InsufficientOutput();
error NotAUniversalRoute();

/**
 * @title UniswapUniversalTradeProtocol
 * @notice The market-trade (swap) half of the AMM split. Version-agnostic: a route is opaque to the
 *         adapter, so one adapter reaches every pool version the Universal Router can — v2, v3 and v4,
 *         and a route that splits across them. That is the whole point of splitting swaps away from the
 *         per-version market-maker adapters.
 *
 *         The `path` slot of `data` is always a Universal Router route, {UniversalRoute}-tagged:
 *         TAG ‖ abi.encode(commands, inputs, deadline) — v2, v3, v4, or any mix, since the router decodes
 *         the commands. Everything routes through the one Universal Router (there is no separate v3-router
 *         path): a version-specific router would only reach one version, defeating the point. The route
 *         bytes are the quoting service's to build per chain (router builds differ — e.g. a newer router
 *         carries a per-hop price field an older v3 input list does not), which is exactly why the adapter
 *         never looks inside them.
 *
 *         Fee model: 0.2% market-swap fee to FEE_RECIPIENT, taken from the input when the sold token is a
 *         guard-registered stable coin, otherwise from the output. exact-out always takes it on the input
 *         actually spent. Output has to land on this adapter and clear the caller's minimum, or the swap
 *         reverts; unspent input goes back to the vault, and no Permit2 allowance outlives the block.
 */
contract UniswapUniversalTradeProtocol is IBittyV1MarketTradeProtocol, BittyV1ProtocolBase {
    using SafeERC20 for IERC20;

    address public constant FEE_RECIPIENT = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;
    uint256 private constant SWAP_FEE_BPS = 20; // 0.2% market-swap fee

    address public immutable universalRouter; // the one router that reaches v2, v3 and v4
    address public immutable permit2; // canonical Permit2, how the Universal Router pulls funds
    address public immutable bittyGuard; // read only to tell whether the sold token is a stable coin

    constructor(address universalRouter_, address permit2_, address bittyGuard_) {
        universalRouter = universalRouter_;
        permit2 = permit2_;
        bittyGuard = bittyGuard_;
    }

    function protocolLineage() external pure override returns (bytes32) {
        return keccak256("bitty.adapter.uniswap.universal");
    }

    function protocolVersion() external pure override returns (uint256) {
        return 1_000_000; // 1.0.0
    }

    receive() external payable {}

    function swap(bytes memory data, address recipient) external payable override onlyOwner {
        (address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOutMinimum, bytes memory route) =
            abi.decode(data, (address, uint256, address, uint256, bytes));

        uint256 swapAmountIn = amountIn;
        bool feeFromOutput;
        if (_isStablecoin(tokenIn)) {
            uint256 fee = amountIn * SWAP_FEE_BPS / 10_000;
            if (fee > 0) {
                _payFrom(tokenIn, FEE_RECIPIENT, fee);
                swapAmountIn = amountIn - fee;
            }
        } else {
            feeFromOutput = true;
        }

        _pullIn(tokenIn, swapAmountIn);

        uint256 outBefore = _balanceOf(tokenOut);
        _routeExactIn(tokenIn, swapAmountIn, route);
        uint256 amountOut = _balanceOf(tokenOut) - outBefore;

        uint256 payout = amountOut;
        if (feeFromOutput) {
            uint256 fee = amountOut * SWAP_FEE_BPS / 10_000;
            if (fee > 0) _pay(tokenOut, FEE_RECIPIENT, fee);
            payout = amountOut - fee;
        }
        if (payout < amountOutMinimum) revert InsufficientOutput();

        _pay(tokenOut, recipient, payout);
        _refundIn(tokenIn);
        _refundNative();
    }

    function swapExactOut(bytes memory data, address recipient) external override onlyOwner {
        (address tokenIn, uint256 amountInMaximum, address tokenOut, uint256 amountOut, bytes memory route) =
            abi.decode(data, (address, uint256, address, uint256, bytes));

        // Reserve fee headroom: the route may spend up to this, and the rest covers our fee.
        uint256 swapAmountInMaximum = amountInMaximum * 10_000 / (10_000 + SWAP_FEE_BPS);

        _pullIn(tokenIn, amountInMaximum);

        uint256 inBefore = _balanceOf(tokenIn);
        uint256 outBefore = _balanceOf(tokenOut);
        _routeExactOut(tokenIn, swapAmountInMaximum, route);
        uint256 amountInSpent = inBefore - _balanceOf(tokenIn);
        uint256 received = _balanceOf(tokenOut) - outBefore;

        uint256 fee = amountInSpent * SWAP_FEE_BPS / 10_000;
        if (fee > 0) _pay(tokenIn, FEE_RECIPIENT, fee);

        if (received < amountOut) revert InsufficientOutput();
        _pay(tokenOut, recipient, received);
        _refundIn(tokenIn);
        _refundNative();
    }
    

    // Run an exact-in swap of `amountIn` of `tokenIn` through `route`, output landing on this adapter.
    function _routeExactIn(address tokenIn, uint256 amountIn, bytes memory route) private {
        if (!UniversalRoute.isUniversal(route)) revert NotAUniversalRoute();
        (bytes memory commands, bytes[] memory inputs, uint256 deadline) = UniversalRoute.decode(route);
        uint256 value;
        if (tokenIn == address(0)) {
            value = amountIn;
        } else {
            _permit2Grant(tokenIn, amountIn);
        }
        IUniversalRouter(universalRouter).execute{value: value}(commands, inputs, deadline);
    }

    // Run an exact-out swap (the bought token and amount are inside `route`), spending at most `maxIn`.
    function _routeExactOut(address tokenIn, uint256 maxIn, bytes memory route) private {
        if (!UniversalRoute.isUniversal(route)) revert NotAUniversalRoute();
        (bytes memory commands, bytes[] memory inputs, uint256 deadline) = UniversalRoute.decode(route);
        _permit2Grant(tokenIn, maxIn);
        IUniversalRouter(universalRouter).execute(commands, inputs, deadline);
    }
    
    function _isStablecoin(address token) internal view returns (bool) {
        return (IBittyV1Guard(bittyGuard).assetCategory(token) & ASSET_STABLE_COIN) != 0;
    }
    
    function _pullIn(address token, uint256 amount) private {
        if (token != address(0)) IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function _permit2Grant(address token, uint256 amount) private {
        if (IERC20(token).allowance(address(this), permit2) < amount) {
            IERC20(token).forceApprove(permit2, type(uint256).max);
        }
        IPermit2(permit2).approve(token, universalRouter, uint160(amount), 0);
    }

    function _balanceOf(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _pay(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        if (token == address(0)) {
            Address.sendValue(payable(to), amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
    
    function _payFrom(address token, address to, uint256 amount) private {
        if (token == address(0)) {
            Address.sendValue(payable(to), amount);
        } else {
            IERC20(token).safeTransferFrom(msg.sender, to, amount);
        }
    }

    function _refundIn(address token) private {
        if (token == address(0)) return; // native handled by _refundNative
        uint256 left = IERC20(token).balanceOf(address(this));
        if (left > 0) IERC20(token).safeTransfer(msg.sender, left);
    }

    function _refundNative() private {
        if (address(this).balance != 0) Address.sendValue(payable(msg.sender), address(this).balance);
    }
}
