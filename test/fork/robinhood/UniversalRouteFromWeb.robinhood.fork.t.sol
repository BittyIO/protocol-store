// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {TestProxy} from "../../helpers/Proxy.sol";
import {UniswapUniversalTradeProtocol} from "protocol-contracts/src/protocols/UniswapUniversalTradeProtocol.sol";
import {robinhood} from "../../../script/addresses.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract StubGuardForRoutes {
    mapping(address => uint8) public assetCategory;

    function set(address asset, uint8 category) external {
        assetCategory[asset] = category;
    }
}

/**
 * @dev Executes routes produced by the web's router (src/lib/uniswap-universal.ts) against a live
 *      fork, so the TypeScript encoding is checked by the real Universal Router rather than by eye.
 *      Skipped unless the route bytes are supplied:
 *
 *        ROUTE_SELL=0x... ROUTE_SELL_AMOUNT=50000000000000000 ROUTE_SELL_MIN=... \
 *        ROUTE_BUY=0x...  ROUTE_BUY_AMOUNT=100000000 ROUTE_BUY_MIN=... forge test --mc UniversalRouteFromWeb
 */
contract UniversalRouteFromWebRobinhoodForkTest is Test {
    using SafeERC20 for IERC20;

    UniswapUniversalTradeProtocol adapter;

    function setUp() public {
        vm.createSelectFork("robinhood");
        StubGuardForRoutes guard = new StubGuardForRoutes();
        guard.set(robinhood.USDG, 1);
        adapter = UniswapUniversalTradeProtocol(
            payable(
                TestProxy.deploy(
                    address(
                        new UniswapUniversalTradeProtocol(
                            robinhood.UNISWAP_UNIVERSAL_ROUTER, robinhood.PERMIT2, address(guard)
                        )
                    ),
                    address(this)
                )
            )
        );
    }

    receive() external payable {}

    function _swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minOut, bytes memory route)
        internal
        returns (uint256 got)
    {
        deal(tokenIn, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(adapter), amountIn);
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        adapter.swap(abi.encode(tokenIn, amountIn, tokenOut, minOut, route), address(this));
        got = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        assertGe(got, minOut, "at least the minimum");
        assertEq(inBefore - IERC20(tokenIn).balanceOf(address(this)), amountIn, "the whole input went in");
        assertEq(IERC20(tokenIn).balanceOf(address(adapter)), 0, "no input stranded on the adapter");
        assertEq(IERC20(tokenOut).balanceOf(address(adapter)), 0, "no output stranded on the adapter");
        assertEq(address(adapter).balance, 0, "no ETH stranded on the adapter");
        assertEq(IERC20(robinhood.WETH).balanceOf(robinhood.UNISWAP_UNIVERSAL_ROUTER), 0, "no WETH left in the router");
        assertEq(robinhood.UNISWAP_UNIVERSAL_ROUTER.balance, 0, "no ETH left in the router");
    }

    function test_WebRoute_SellWethForUsdg() public {
        bytes memory route = vm.envOr("ROUTE_SELL", bytes(""));
        if (route.length == 0) return;
        uint256 got = _swap(
            robinhood.WETH,
            vm.envUint("ROUTE_SELL_AMOUNT"),
            robinhood.USDG,
            vm.envUint("ROUTE_SELL_MIN"),
            route
        );
        emit log_named_uint("USDG received", got);
    }

    function test_WebRoute_BuyWethWithUsdg() public {
        bytes memory route = vm.envOr("ROUTE_BUY", bytes(""));
        if (route.length == 0) return;
        uint256 got = _swap(
            robinhood.USDG,
            vm.envUint("ROUTE_BUY_AMOUNT"),
            robinhood.WETH,
            vm.envUint("ROUTE_BUY_MIN"),
            route
        );
        emit log_named_uint("WETH received", got);
    }
}
