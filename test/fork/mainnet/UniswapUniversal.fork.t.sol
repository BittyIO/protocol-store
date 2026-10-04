// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {TestProxy} from "../../helpers/Proxy.sol";
import {UniswapUniversalTradeProtocol, InsufficientOutput} from
    "protocol-contracts/src/protocols/UniswapUniversalTradeProtocol.sol";
import {UniversalRoute} from "protocol-contracts/src/libs/uniswap/universal/UniversalRouter.sol";
import {mainnet} from "../../../script/addresses.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {
    Path,
    IUniswapV3Factory,
    IUniswapV3Pool,
    IUniswapV3Router
} from "protocol-contracts/src/libs/uniswap/v3/Uniswap.sol";

interface IPermit2View {
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/**
 * Market swaps through Uniswap's Universal Router, so one order can take v2, v3 and v4 liquidity.
 *
 * The route is opaque to the adapter, so what these pin is the adapter's own guarantees around it:
 * the fee split still applies, output has to land on the adapter and clear the minimum, unspent
 * input goes back to the vault, and no Permit2 allowance outlives the swap.
 */
contract UniswapUniversalForkTest is Test {
    using SafeERC20 for IERC20;

    // Universal Router commands and v4 actions, as the router decodes them.
    uint8 constant CMD_V3_SWAP_EXACT_IN = 0x00;
    uint8 constant CMD_V3_SWAP_EXACT_OUT = 0x01;
    uint8 constant CMD_V2_SWAP_EXACT_IN = 0x08;
    uint8 constant CMD_V4_SWAP = 0x10;
    uint8 constant ACT_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant ACT_SETTLE_ALL = 0x0c;
    uint8 constant ACT_TAKE_ALL = 0x0f;
    // The router's "whoever called me" recipient: output lands on the adapter, as it must.
    address constant MSG_SENDER = address(1);

    address constant FEE_RECIPIENT = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;
    uint256 constant SWAP_FEE_BPS = 20;

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    // Universal Router 2.1 shapes: the v4 single-swap params carry a per-hop price floor (0 = none)
    // ahead of hookData, and v3 inputs end in a per-hop price list (empty = none).
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    UniswapUniversalTradeProtocol adapter;

    function setUp() public {
        vm.createSelectFork("mainnet");
        adapter = UniswapUniversalTradeProtocol(
            payable(
                TestProxy.deploy(
                    address(
                        new UniswapUniversalTradeProtocol(
                            mainnet.UNISWAP_UNIVERSAL_ROUTER, mainnet.PERMIT2, mainnet.BITTY_GUARD
                        )
                    ),
                    address(this)
                )
            )
        );
        vm.deal(address(adapter), 0);
    }

    receive() external payable {}

    // ── route builders ────────────────────────────────────────────────────────

    function _v2ExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        internal
        view
        returns (bytes memory)
    {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        bytes memory commands = abi.encodePacked(CMD_V2_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(to, amountIn, minOut, path, true);
        return UniversalRoute.encode(commands, inputs, block.timestamp + 60);
    }

    function _v3ExactIn(address tokenIn, uint24 fee, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        internal
        view
        returns (bytes memory)
    {
        address[] memory tokens = new address[](2);
        tokens[0] = tokenIn;
        tokens[1] = tokenOut;
        uint24[] memory fees = new uint24[](1);
        fees[0] = fee;
        bytes memory commands = abi.encodePacked(CMD_V3_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](1);
        uint256[] memory noHopFloor = new uint256[](0);
        inputs[0] = abi.encode(to, amountIn, minOut, Path.encodePath(tokens, fees), true, noHopFloor);
        return UniversalRoute.encode(commands, inputs, block.timestamp + 60);
    }

    function _v3ExactOut(address tokenIn, uint24 fee, address tokenOut, uint256 amountOut, uint256 maxIn)
        internal
        view
        returns (bytes memory)
    {
        // exactOut paths run from the token bought back to the token sold.
        address[] memory tokens = new address[](2);
        tokens[0] = tokenOut;
        tokens[1] = tokenIn;
        uint24[] memory fees = new uint24[](1);
        fees[0] = fee;
        bytes memory commands = abi.encodePacked(CMD_V3_SWAP_EXACT_OUT);
        bytes[] memory inputs = new bytes[](1);
        uint256[] memory noHopFloor = new uint256[](0);
        inputs[0] = abi.encode(MSG_SENDER, amountOut, maxIn, Path.encodePath(tokens, fees), true, noHopFloor);
        return UniversalRoute.encode(commands, inputs, block.timestamp + 60);
    }

    function _v4ExactInSingle(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minOut
    ) internal view returns (bytes memory) {
        ExactInputSingleParams memory p = ExactInputSingleParams({
            poolKey: PoolKey({
                currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: address(0)
            }),
            zeroForOne: zeroForOne,
            amountIn: uint128(amountIn),
            amountOutMinimum: uint128(minOut),
            minHopPriceX36: 0,
            hookData: ""
        });
        (address cIn, address cOut) = zeroForOne ? (currency0, currency1) : (currency1, currency0);
        bytes memory actions = abi.encodePacked(ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(p);
        params[1] = abi.encode(cIn, amountIn);
        params[2] = abi.encode(cOut, minOut);
        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        return UniversalRoute.encode(commands, inputs, block.timestamp + 60);
    }

    // tokenOut per 1e18 of tokenIn, off the v3 pool for the pair (v2/v4 prices track it closely).
    function _v3Price(address tokenIn, address tokenOut, uint24 fee) internal view returns (uint256) {
        address token0 = tokenIn < tokenOut ? tokenIn : tokenOut;
        address token1 = tokenIn < tokenOut ? tokenOut : tokenIn;
        address pool =
            IUniswapV3Factory(IUniswapV3Router(mainnet.UNISWAP_V3_ROUTER).factory()).getPool(token0, token1, fee);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 q192 = 2 ** 192;
        uint256 p1per0 = Math.mulDiv(Math.mulDiv(uint256(sqrtPriceX96), 1e18, 1), uint256(sqrtPriceX96), q192);
        if (tokenIn == token0) return p1per0;
        return Math.mulDiv(q192, 1e18, Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1));
    }

    function _swapData(address tokenIn, uint256 amountIn, address tokenOut, uint256 minOut, bytes memory route)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(tokenIn, amountIn, tokenOut, minOut, route);
    }

    // ── v2 liquidity through the Universal Router ─────────────────────────────

    function test_Universal_V2Route_SellsWethForUsdt() public {
        uint256 sell = 1 ether;
        // v2 reserves move the price, so keep the floor loose: this is the routing under test.
        uint256 minOut = Math.mulDiv(_v3Price(mainnet.WETH, mainnet.USDT, 3000), 80, 100);
        bytes memory route = _v2ExactIn(mainnet.WETH, mainnet.USDT, sell, minOut, MSG_SENDER);
        deal(mainnet.WETH, address(this), sell);
        IERC20(mainnet.WETH).forceApprove(address(adapter), sell);
        uint256 feeBefore = IERC20(mainnet.USDT).balanceOf(FEE_RECIPIENT);
        uint256 usdtBefore = IERC20(mainnet.USDT).balanceOf(address(this));

        adapter.swap(_swapData(mainnet.WETH, sell, mainnet.USDT, minOut, route), address(this));

        uint256 got = IERC20(mainnet.USDT).balanceOf(address(this)) - usdtBefore;
        uint256 fee = IERC20(mainnet.USDT).balanceOf(FEE_RECIPIENT) - feeBefore;
        assertGe(got, minOut, "at least the minimum, after the fee");
        assertEq(fee, (got + fee) * SWAP_FEE_BPS / 10_000, "0.2% of the output to the fee recipient");
        assertEq(IERC20(mainnet.WETH).balanceOf(address(adapter)), 0, "nothing stranded on the adapter");
    }

    // ── v3 liquidity through the Universal Router ─────────────────────────────

    function test_Universal_V3Route_SellsWethForUsdt_WithOutputFee() public {
        uint256 sell = 1 ether;
        uint256 minOut = Math.mulDiv(_v3Price(mainnet.WETH, mainnet.USDT, 3000), 95, 100);
        bytes memory route = _v3ExactIn(mainnet.WETH, 3000, mainnet.USDT, sell, minOut, MSG_SENDER);
        deal(mainnet.WETH, address(this), sell);
        IERC20(mainnet.WETH).forceApprove(address(adapter), sell);
        uint256 feeBefore = IERC20(mainnet.USDT).balanceOf(FEE_RECIPIENT);
        // Deltas throughout: the default test address holds stray tokens on a mainnet fork.
        uint256 usdtBefore = IERC20(mainnet.USDT).balanceOf(address(this));

        adapter.swap(_swapData(mainnet.WETH, sell, mainnet.USDT, minOut, route), address(this));

        uint256 got = IERC20(mainnet.USDT).balanceOf(address(this)) - usdtBefore;
        uint256 fee = IERC20(mainnet.USDT).balanceOf(FEE_RECIPIENT) - feeBefore;
        assertGe(got, minOut, "at least the minimum, after the fee");
        assertEq(fee, (got + fee) * SWAP_FEE_BPS / 10_000, "0.2% of the output to the fee recipient");
        assertEq(IERC20(mainnet.WETH).balanceOf(address(adapter)), 0, "nothing stranded on the adapter");
    }

    function test_Universal_V3Route_ExactOut_ChargesFeeOnActualInput() public {
        uint256 want = 0.1 ether;
        uint256 maxIn = Math.mulDiv(_v3Price(mainnet.WETH, mainnet.USDC, 500), want, 1e18) * 110 / 100;
        uint256 routeMax = maxIn * 10_000 / (10_000 + SWAP_FEE_BPS);
        bytes memory route = _v3ExactOut(mainnet.USDC, 500, mainnet.WETH, want, routeMax);
        deal(mainnet.USDC, address(this), maxIn);
        IERC20(mainnet.USDC).forceApprove(address(adapter), maxIn);
        uint256 feeBefore = IERC20(mainnet.USDC).balanceOf(FEE_RECIPIENT);
        uint256 wethBefore = IERC20(mainnet.WETH).balanceOf(address(this));

        adapter.swapExactOut(abi.encode(mainnet.USDC, maxIn, mainnet.WETH, want, route), address(this));

        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)) - wethBefore, want, "exactly what was asked for");
        uint256 fee = IERC20(mainnet.USDC).balanceOf(FEE_RECIPIENT) - feeBefore;
        uint256 left = IERC20(mainnet.USDC).balanceOf(address(this));
        uint256 spent = maxIn - left - fee;
        assertEq(fee, spent * SWAP_FEE_BPS / 10_000, "fee on what the route actually spent");
        assertGt(left, 0, "the unspent maximum came back");
    }

    // ── v4 liquidity through the Universal Router ─────────────────────────────

    function test_Universal_V4Route_SellsUsdcForNativeEth_WithInputFee() public {
        uint256 sell = 1_000e6;
        uint256 fee = sell * SWAP_FEE_BPS / 10_000;
        uint256 minOut = Math.mulDiv(_v3Price(mainnet.USDC, mainnet.WETH, 500), sell - fee, 1e18) * 90 / 100;
        // ETH/USDC 0.05%: currency0 is native ETH, so USDC -> ETH is oneForZero.
        bytes memory route = _v4ExactInSingle(address(0), mainnet.USDC, 500, 10, false, sell - fee, minOut);
        deal(mainnet.USDC, address(this), sell);
        IERC20(mainnet.USDC).forceApprove(address(adapter), sell);
        uint256 ethBefore = address(this).balance;
        uint256 feeBefore = IERC20(mainnet.USDC).balanceOf(FEE_RECIPIENT);

        adapter.swap(_swapData(mainnet.USDC, sell, address(0), minOut, route), address(this));

        assertGe(address(this).balance - ethBefore, minOut, "native ETH swept back to the vault");
        assertEq(IERC20(mainnet.USDC).balanceOf(FEE_RECIPIENT) - feeBefore, fee, "0.2% of the stable-coin input");
        assertEq(address(adapter).balance, 0, "no ETH left on the adapter");
    }

    function test_Universal_V4Route_SellsNativeEthForUsdc() public {
        uint256 sell = 1 ether;
        uint256 minOut = Math.mulDiv(_v3Price(mainnet.WETH, mainnet.USDC, 500), sell, 1e18) * 90 / 100;
        bytes memory route = _v4ExactInSingle(address(0), mainnet.USDC, 500, 10, true, sell, minOut);
        vm.deal(address(this), sell);
        uint256 usdcBefore = IERC20(mainnet.USDC).balanceOf(address(this));

        adapter.swap{value: sell}(_swapData(address(0), sell, mainnet.USDC, minOut, route), address(this));

        assertGe(
            IERC20(mainnet.USDC).balanceOf(address(this)) - usdcBefore, minOut, "USDC delivered, net of the output fee"
        );
        assertEq(address(adapter).balance, 0, "no ETH left on the adapter");
    }

    // ── the adapter's own guarantees around an opaque route ───────────────────

    function test_Universal_RouteThatDeliversElsewhere_IsRefused() public {
        uint256 sell = 1 ether;
        address thief = makeAddr("thief");
        bytes memory route = _v3ExactIn(mainnet.WETH, 3000, mainnet.USDT, sell, 0, thief);
        deal(mainnet.WETH, address(this), sell);
        IERC20(mainnet.WETH).forceApprove(address(adapter), sell);

        uint256 thiefBefore = IERC20(mainnet.USDT).balanceOf(thief);
        vm.expectRevert(InsufficientOutput.selector);
        adapter.swap(_swapData(mainnet.WETH, sell, mainnet.USDT, 1, route), address(this));
        assertEq(IERC20(mainnet.USDT).balanceOf(thief), thiefBefore, "and nothing moved");
    }

    function test_Universal_UnspentInput_ReturnsToTheVault() public {
        uint256 allowed = 1 ether;
        bytes memory route = _v3ExactIn(mainnet.WETH, 3000, mainnet.USDT, allowed / 2, 0, MSG_SENDER);
        deal(mainnet.WETH, address(this), allowed);
        IERC20(mainnet.WETH).forceApprove(address(adapter), allowed);

        adapter.swap(_swapData(mainnet.WETH, allowed, mainnet.USDT, 1, route), address(this));

        // deal() set the balance to exactly `allowed`, so what remains is what the route left.
        assertEq(IERC20(mainnet.WETH).balanceOf(address(this)), allowed / 2, "the half the route did not use");
        assertEq(IERC20(mainnet.WETH).balanceOf(address(adapter)), 0, "nothing stranded on the adapter");
    }

    function test_Universal_NoPermit2AllowanceOutlivesTheSwap() public {
        uint256 sell = 1 ether;
        bytes memory route = _v3ExactIn(mainnet.WETH, 3000, mainnet.USDT, sell, 0, MSG_SENDER);
        deal(mainnet.WETH, address(this), sell);
        IERC20(mainnet.WETH).forceApprove(address(adapter), sell);
        adapter.swap(_swapData(mainnet.WETH, sell, mainnet.USDT, 1, route), address(this));

        (uint160 amount, uint48 expiration,) =
            IPermit2View(mainnet.PERMIT2).allowance(address(adapter), mainnet.WETH, mainnet.UNISWAP_UNIVERSAL_ROUTER);
        assertEq(amount, 0, "allowance cleared");
        // Permit2 records a zero expiry as "now", which is spent by the next block either way.
        assertLe(expiration, block.timestamp, "and expired");
    }

}
