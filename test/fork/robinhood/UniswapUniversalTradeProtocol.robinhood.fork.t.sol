// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {TestProxy} from "../../helpers/Proxy.sol";
import {UniswapUniversalTradeProtocol} from "protocol-contracts/src/protocols/UniswapUniversalTradeProtocol.sol";
import {UniversalRoute} from "protocol-contracts/src/libs/uniswap/universal/UniversalRouter.sol";
import {robinhood} from "../../../script/addresses.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Path, IUniswapV3Factory, IUniswapV3Pool} from "protocol-contracts/src/libs/uniswap/v3/Uniswap.sol";

/**
 * @dev The guard is not on Robinhood Chain yet, and the trade adapter only asks it one thing - whether
 *      the sold token is a stable coin - so a stand-in that answers that is all the fork needs.
 */
contract StubGuard {
    mapping(address => uint8) public assetCategory;

    function set(address asset, uint8 category) external {
        assetCategory[asset] = category;
    }
}

/**
 * Robinhood Chain: the WETH/USDG pair has liquidity on v3 AND v4, which is the situation the
 * Universal Router path exists for. Same adapter, same guarantees, on the chain that motivated it.
 */
contract UniswapUniversalTradeProtocolRobinhoodForkTest is Test {
    using SafeERC20 for IERC20;

    uint8 constant CMD_V3_SWAP_EXACT_IN = 0x00;
    uint8 constant CMD_V4_SWAP = 0x10;
    uint8 constant ACT_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant ACT_SETTLE_ALL = 0x0c;
    uint8 constant ACT_TAKE_ALL = 0x0f;
    address constant MSG_SENDER = address(1);
    uint8 constant ASSET_STABLE_COIN = 1;

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    // The periphery build behind Robinhood's router carries a per-hop price floor in its swap
    // params (0 = none), ahead of hookData. Mainnet's older router does not - one more reason the
    // route bytes are the quoting service's to build per chain, not the adapter's.
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
        vm.createSelectFork("robinhood");
        StubGuard guard = new StubGuard();
        guard.set(robinhood.USDG, ASSET_STABLE_COIN);
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

    // USDG per 1e18 WETH, off the deepest v3 pool.
    function _wethPriceInUsdg() internal view returns (uint256) {
        address pool = IUniswapV3Factory(robinhood.UNISWAP_V3_FACTORY).getPool(robinhood.WETH, robinhood.USDG, 100);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 q192 = 2 ** 192;
        uint256 p1per0 = Math.mulDiv(Math.mulDiv(uint256(sqrtPriceX96), 1e18, 1), uint256(sqrtPriceX96), q192);
        // token0 is WETH (lower address), so this is already USDG per WETH.
        return p1per0;
    }

    function _v3Path(uint24 fee) internal pure returns (bytes memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = robinhood.WETH;
        tokens[1] = robinhood.USDG;
        uint24[] memory fees = new uint24[](1);
        fees[0] = fee;
        return Path.encodePath(tokens, fees);
    }

    function _v4WethToUsdg(uint24 fee, int24 tickSpacing, address currencyIn, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (bytes memory)
    {
        // WETH (or native ETH) sorts below USDG, so selling it is zeroForOne.
        ExactInputSingleParams memory p = ExactInputSingleParams({
            poolKey: PoolKey({
                currency0: currencyIn, currency1: robinhood.USDG, fee: fee, tickSpacing: tickSpacing, hooks: address(0)
            }),
            zeroForOne: true,
            amountIn: uint128(amountIn),
            amountOutMinimum: uint128(minOut),
            minHopPriceX36: 0,
            hookData: ""
        });
        bytes memory actions = abi.encodePacked(ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(p);
        params[1] = abi.encode(currencyIn, amountIn);
        params[2] = abi.encode(robinhood.USDG, minOut);
        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        return UniversalRoute.encode(commands, inputs, block.timestamp + 60);
    }

    function _sellWeth(uint256 sell, uint256 minOut, bytes memory path) internal returns (uint256 got) {
        deal(robinhood.WETH, address(this), sell);
        IERC20(robinhood.WETH).forceApprove(address(adapter), sell);
        uint256 balBefore = IERC20(robinhood.USDG).balanceOf(address(this));
        adapter.swap(abi.encode(robinhood.WETH, sell, robinhood.USDG, minOut, path), address(this));
        got = IERC20(robinhood.USDG).balanceOf(address(this)) - balBefore;
        assertGe(got, minOut, "at least the minimum");
        assertEq(IERC20(robinhood.WETH).balanceOf(address(adapter)), 0, "nothing stranded on the adapter");
    }

    /**
     * @dev Robinhood runs a newer Universal Router build than mainnet: its v3 swap input carries a
     *      sixth field, a per-hop minimum price list. The adapter never looks inside a route, so this
     *      is the quoting service's concern per chain - and exactly why the route is opaque.
     */
    function test_Robinhood_V3RouteThroughUniversalRouter() public {
        uint256 sell = 0.05 ether;
        uint256 minOut = Math.mulDiv(_wethPriceInUsdg(), sell, 1e18) * 95 / 100;
        bytes memory commands = abi.encodePacked(CMD_V3_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](1);
        uint256[] memory minHopPriceX36 = new uint256[](0);
        inputs[0] = abi.encode(MSG_SENDER, sell, minOut, _v3Path(100), true, minHopPriceX36);
        _sellWeth(sell, minOut, UniversalRoute.encode(commands, inputs, block.timestamp + 60));
    }

    function test_Robinhood_V4RouteWethToUsdg() public {
        // The wrapped-ETH v4 pools are thin at the current tick (the depth is in the native-ETH
        // ones), so this stays small: it is the routing that is under test, not the pool.
        uint256 sell = 0.002 ether;
        uint256 minOut = Math.mulDiv(_wethPriceInUsdg(), sell, 1e18) * 80 / 100;
        _sellWeth(sell, minOut, _v4WethToUsdg(500, 10, robinhood.WETH, sell, minOut));
    }

    function test_Robinhood_V4RouteNativeEthToUsdg() public {
        uint256 sell = 0.05 ether;
        uint256 minOut = Math.mulDiv(_wethPriceInUsdg(), sell, 1e18) * 90 / 100;
        bytes memory route = _v4WethToUsdg(100, 1, address(0), sell, minOut);
        vm.deal(address(this), sell);
        uint256 balBefore = IERC20(robinhood.USDG).balanceOf(address(this));
        adapter.swap{value: sell}(abi.encode(address(0), sell, robinhood.USDG, minOut, route), address(this));
        assertGe(IERC20(robinhood.USDG).balanceOf(address(this)) - balBefore, minOut, "USDG for native ETH");
        assertEq(address(adapter).balance, 0, "no ETH left on the adapter");
    }
}
